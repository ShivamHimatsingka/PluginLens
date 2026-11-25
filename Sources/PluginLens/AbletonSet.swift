import Foundation

/// A device found in an Ableton Live set (`.als`, a gzip-compressed XML document).
struct AbletonDevice: Hashable, Sendable {
    enum Kind: String, Sendable { case builtIn, audioUnit, vst, vst3, maxForLive }
    var kind: Kind
    /// Plugin name as stored by Live; for built-ins the XML element name (e.g. "Compressor2").
    var name: String
    /// Leaf field values from the plugin descriptor (`Name`, `Manufacturer`, `UniqueId`, `Fields.0` ...), shallowest occurrence wins.
    var fields: [String: String] = [:]
    /// Decoded plugin state buffers (`Buffer`, `ProcessorState`); not part of equality or hashing.
    var states: [Data] = []
    var count = 1

    static func == (l: AbletonDevice, r: AbletonDevice) -> Bool { l.key == r.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    /// AU codes if the descriptor declares them as 4-character codes or integers.
    var auCodes: (type: String, subtype: String, manufacturer: String)? {
        func code(_ names: [String]) -> String? {
            for (k, v) in fields where names.contains(where: { k.localizedCaseInsensitiveContains($0) }) {
                if v.utf8.count == 4 { return v }
                if let n = Int(v) { return SavedVersionExtractor.fourCC(n) }
            }
            return nil
        }
        // "ComponentSubType" contains "Type": look for the most specific names first.
        guard let sub = code(["ComponentSubType", "SubType"]), let man = code(["ComponentManufacturer"]),
              let type = fields.first(where: { $0.key.caseInsensitiveCompare("ComponentType") == .orderedSame }).flatMap({ kv -> String? in
                  kv.value.utf8.count == 4 ? kv.value : Int(kv.value).map(SavedVersionExtractor.fourCC) }) else { return nil }
        return (type, sub, man)
    }

    /// VST3 class ID candidates (lower-case hex, dashed like Live's plugin database) from `Fields.0...3`, in both byte orders.
    var vst3ClassIDs: [String] {
        let ints = (0..<4).compactMap { fields["Fields.\($0)"].flatMap { Int($0) } }
        guard ints.count == 4 else { return [] }
        func hex(_ f: (UInt32) -> [UInt8]) -> String {
            let b = ints.flatMap { f(UInt32(truncatingIfNeeded: $0)) }.map { String(format: "%02x", $0) }.joined()
            let s = Array(b)
            return [s[0..<8], s[8..<12], s[12..<16], s[16..<20], s[20..<32]].map { String($0) }.joined(separator: "-")
        }
        return [hex { [UInt8($0 >> 24 & 255), UInt8($0 >> 16 & 255), UInt8($0 >> 8 & 255), UInt8($0 & 255)] },
                hex { [UInt8($0 & 255), UInt8($0 >> 8 & 255), UInt8($0 >> 16 & 255), UInt8($0 >> 24 & 255)] }]
    }

    var key: String {
        switch kind {
        case .builtIn: return "builtin:\(name)"
        case .audioUnit: return "au:\(auCodes.map { "\($0.type)/\($0.subtype)/\($0.manufacturer)" } ?? name)"
        case .vst3: return "vst3:\(vst3ClassIDs.first ?? name)"
        case .vst: return "vst:\(fields["UniqueId"] ?? name)"
        case .maxForLive: return "m4l:\(name)"
        }
    }
}

struct AbletonSet: Sendable {
    var creator: String?          // "Ableton Live 12.1d1"
    var majorVersion: String?     // schema, "5" for Live 10-12
    var devices: [AbletonDevice]

    /// Version number in `Creator`, e.g. "12.1" from "Ableton Live 12.1d1".
    var liveVersion: String? {
        guard let c = creator, let r = c.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(c[r])
    }
}

enum AbletonSetParser {
    static let maxDecompressed = 1_500_000_000

    static func parse(_ file: Data) throws -> AbletonSet {
        guard file.count >= 18 else { throw ProjectError.corrupt("the set is only \(file.count) bytes long") }
        let xml: Data
        if file[file.startIndex] == 0x1F, file[file.startIndex + 1] == 0x8B {
            xml = try gunzip(file)
        } else if file.prefix(5) == Data("<?xml".utf8) {
            xml = file
        } else {
            throw ProjectError.unsupportedFormat("not a gzip-compressed Live set (header \(file.prefix(4).map { String(format: "%02x", $0) }.joined()))")
        }
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.devices.isEmpty else {
            throw ProjectError.corrupt("the set's XML could not be read: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }
        guard delegate.sawRoot else { throw ProjectError.unsupportedFormat("the document is not an Ableton Live set") }
        var order: [String] = [], merged: [String: AbletonDevice] = [:]
        for d in delegate.devices {
            if var m = merged[d.key] { m.count += 1; m.states += d.states; merged[d.key] = m }
            else { order.append(d.key); merged[d.key] = d }
        }
        return AbletonSet(creator: delegate.creator, majorVersion: delegate.majorVersion, devices: order.compactMap { merged[$0] })
    }

    /// Minimal gzip reader: header (RFC 1952), raw deflate body, ignores the CRC/length trailer.
    static func gunzip(_ d: Data) throws -> Data {
        let b = [UInt8](d.prefix(4096))
        guard b.count >= 18, b[2] == 8 else { throw ProjectError.corrupt("not a deflate-compressed gzip stream") }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= b.count else { throw ProjectError.corrupt("bad gzip header") }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        for bit in [UInt8(8), 16] where flags & bit != 0 {
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 }
        guard i < d.count - 8 else { throw ProjectError.corrupt("truncated gzip stream") }
        let body = d.subdata(in: (d.startIndex + i)..<(d.endIndex - 8))
        guard let out = try? (body as NSData).decompressed(using: .zlib) as Data else {
            // A truncated download still has a usable prefix, but NSData can't return partial output.
            throw ProjectError.corrupt("the compressed data is damaged or truncated")
        }
        guard out.count <= maxDecompressed else { throw ProjectError.unsupportedFormat("the set expands to an unreasonable size") }
        return out
    }

    // MARK: SAX delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var devices: [AbletonDevice] = []
        var creator: String?, majorVersion: String?
        var sawRoot = false

        private var path: [String] = []
        private static let groups: Set<String> = ["AudioEffectGroupDevice", "InstrumentGroupDevice", "MidiEffectGroupDevice", "DrumGroupDevice"]
        private static let stateElements: Set<String> = ["Buffer", "ProcessorState", "ControllerState"]
        private static let infoElements: [String: AbletonDevice.Kind] = ["AuPluginInfo": .audioUnit, "VstPluginInfo": .vst, "Vst3PluginInfo": .vst3]

        // Current plugin device being captured.
        private var current: AbletonDevice?
        private var currentDepth = 0
        private var depths: [String: Int] = [:]
        private var text = ""
        private var capturingState = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if path.isEmpty, name == "Ableton" { sawRoot = true; creator = a["Creator"]; majorVersion = a["MajorVersion"] }
            let parent = path.last
            path.append(name)

            if current == nil, parent == "Devices" {
                switch name {
                case "PluginDevice", "AuPluginDevice":
                    current = AbletonDevice(kind: name == "AuPluginDevice" ? .audioUnit : .vst, name: ""); currentDepth = path.count; depths = [:]
                case _ where name.hasPrefix("MxDevice"):
                    current = AbletonDevice(kind: .maxForLive, name: ""); currentDepth = path.count; depths = [:]
                case _ where Self.groups.contains(name): break
                default: devices.append(AbletonDevice(kind: .builtIn, name: name))
                }
                return
            }
            guard current != nil else { return }
            if let kind = Self.infoElements[name] { current?.kind = kind }
            if Self.stateElements.contains(name) { capturingState = true; text = ""; return }
            if let v = a["Value"] {
                let depth = path.count - currentDepth
                let leaf = name
                if depths[leaf] == nil || depth < depths[leaf]! { depths[leaf] = depth; current?.fields[leaf] = v }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) {
            if capturingState, text.utf8.count < 96 * 1024 * 1024 { text += s }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            guard current != nil else { return }
            if Self.stateElements.contains(name), capturingState {
                capturingState = false
                if let d = Self.decode(text) { current?.states.append(d) }
                text = ""
            }
            if path.count == currentDepth, var dev = current {
                dev.name = dev.fields["Name"] ?? dev.fields["PlugName"] ?? dev.fields["UserName"] ?? dev.name
                if dev.name.isEmpty { dev.name = dev.kind == .maxForLive ? "Max for Live device" : "Unnamed plugin" }
                devices.append(dev)
                current = nil
            }
        }

        /// Plugin state is stored as hex text (whitespace separated); fall back to base64.
        static func decode(_ s: String) -> Data? {
            let t = s.filter { !$0.isWhitespace }
            guard !t.isEmpty else { return nil }
            if t.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }), t.utf8.count % 2 == 0 {
                var out = Data(capacity: t.utf8.count / 2)
                var hi: UInt8?
                for c in t.utf8 {
                    let v = c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10
                    if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
                }
                return out
            }
            return Data(base64Encoded: t)
        }
    }
}
