import Foundation

/// A plugin version found inside a project: the version of the plugin that was running when the project was saved.
struct SavedVersion: Hashable, Sendable {
    /// Best first. Lower raw value = more trustworthy.
    enum Confidence: Int, Sendable, Comparable {
        /// The AU state's own `version` field, which AU plugins set to their component version (major<<16 | minor<<8 | bugfix).
        case exact = 0
        /// A version written by the plugin under a convention seen in real projects (`pluginVersion="…"` and similar).
        case convention
        /// A `…version…: x.y.z` field found by a generic search of the plugin state. Not verified against a known convention.
        case heuristic
        /// Only the product generation, taken from the plugin's name ("Ozone 12" -> 12).
        case generation

        static func < (l: Confidence, r: Confidence) -> Bool { l.rawValue < r.rawValue }
        var label: String {
            switch self {
            case .exact: return "AU state version"
            case .convention: return "plugin state"
            case .heuristic: return "plugin state (unverified field)"
            case .generation: return "plugin name"
            }
        }
    }

    var version: String
    /// Where it was read from, e.g. `pluginVersion attribute`.
    var source: String
    var confidence: Confidence = .convention
    /// For `.exact`: the raw component-version integer.
    var componentValue: Int? = nil
}

/// Logic stores each plugin's AU state as an embedded XML plist (`type`, `subtype`, `manufacturer`, `version`, plus the plugin's
/// own state blobs). There is no universal version field, so this looks, in order of trust, at:
///
/// 1. the plist's own `version` (AU plugins that fill it in set it to their component version, so it can be compared exactly);
/// 2. version strings written into the plugin's state under conventions seen in real projects;
/// 3. a generic search for `…version…: x.y.z` fields (including inside zlib-compressed state), labelled unverified.
///
/// A separate fallback (product generation from the plugin's name) lives in `PluginResolver`.
enum SavedVersionExtractor {
    private struct Pattern { let needle: String; let source: String; let terminators: Set<UInt8>; let boundary: Bool }
    private static let patterns: [Pattern] = [
        Pattern(needle: "pluginVersion=\"", source: "pluginVersion attribute", terminators: [0x22], boundary: false),
        Pattern(needle: "\"productVersion\":\"", source: "productVersion field", terminators: [0x22], boundary: false),
        Pattern(needle: "PlugVersion ", source: "PlugVersion line", terminators: [0x0A, 0x0D, 0x20], boundary: false),
        Pattern(needle: "PluginVersion=\"", source: "PluginVersion attribute", terminators: [0x22], boundary: true),
        Pattern(needle: "Version=\"", source: "Version attribute", terminators: [0x22], boundary: true),
        Pattern(needle: "Pianoteq ", source: "Pianoteq state banner", terminators: [0x2F], boundary: false),
    ]
    /// iPlug2-based plugins (Neural Amp Modeler and derivatives) start their state with this marker, then a
    /// little-endian u32 length and the plugin version string.
    private static let iPlugMarker = Data("###NeuralAmpModeler###".utf8)
    private static let maxScan = 8 * 1024 * 1024
    private static let maxInflated = 64 * 1024 * 1024

    /// Key names that look like versions but describe a file/state/preset format or a dependency, not the plugin.
    private static let genericKeyExclusions = ["chunk", "schema", "format", "param", "preset", "state", "file", "api", "xml", "sdk", "min",
        "max", "protocol", "compat", "data", "midi", "json", "doc", "project", "session", "host", "engine", "framework", "juce", "lib",
        "content", "skin", "gui", "license", "os", "driver", "firmware", "bank", "program", "wrapper", "vst", "aax"]
    private static let genericRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z_])([A-Za-z_]{0,24}[Vv]ersion[A-Za-z_]{0,12})\s*["']?\s*[:=]\s*["']?\s*(\d+\.\d+\.\d+(?:\.\d+)?)"#)

    // MARK: Whole file

    /// Every embedded plugin-state plist in the file, keyed by the same key as `RawPluginRecord.key`.
    /// Only the most trustworthy tier found for each plugin is kept.
    static func extract(from data: Data) -> [String: [SavedVersion]] {
        var all: [String: [SavedVersion]] = [:]
        let start = Data("<?xml".utf8), end = Data("</plist>".utf8)
        var cursor = data.startIndex
        while let s = data.range(of: start, in: cursor..<data.endIndex) {
            guard let e = data.range(of: end, in: s.lowerBound..<data.endIndex) else { break }
            cursor = e.upperBound
            guard let plist = (try? PropertyListSerialization.propertyList(from: data.subdata(in: s.lowerBound..<e.upperBound), format: nil)) as? [String: Any],
                  let t = plist["type"] as? Int, let sub = plist["subtype"] as? Int, let man = plist["manufacturer"] as? Int
            else { continue }
            let key = "au:\(fourCC(t))/\(fourCC(sub))/\(fourCC(man))"
            for v in candidates(in: plist) where !(all[key]?.contains(v) ?? false) { all[key, default: []].append(v) }
        }
        return all.mapValues { list in
            let best = list.map(\.confidence).min()
            return list.filter { $0.confidence == best }
        }
    }

    /// Candidates from one state plist, best tier only.
    static func candidates(in plist: [String: Any]) -> [SavedVersion] {
        var found: [SavedVersion] = []
        if let v = plist["version"] as? Int, v > 0, v <= 0x00FF_FFFF {
            found.append(SavedVersion(version: decodeComponentVersion(v), source: "AU state version field",
                                      confidence: .exact, componentValue: v))
        }
        var convention: SavedVersion?, generic: SavedVersion?
        for value in plist.values {
            let blob: Data
            if let d = value as? Data { blob = d } else if let str = value as? String { blob = Data(str.utf8) } else { continue }
            for variant in [blob] + (inflate(blob).map { [$0] } ?? []) {
                if convention == nil { convention = find(in: variant) }
                if convention == nil, generic == nil { generic = findGeneric(in: variant) }
            }
            if convention != nil { break }
        }
        if let convention { found.append(convention) } else if let generic { found.append(generic) }
        return found
    }

    /// Versions found in one opaque state blob that is not wrapped in a Logic plist (e.g. an Ableton `ProcessorState`).
    static func scan(_ blob: Data) -> SavedVersion? {
        let variants = [blob] + (inflate(blob).map { [$0] } ?? [])
        for v in variants { if let c = find(in: v) { return c } }
        for v in variants { if let g = findGeneric(in: v) { return g } }
        return nil
    }

    /// Versions from an AU state buffer: the embedded plist if there is one (AU state version field, conventions, generic), else a plain scan.
    static func statePlistCandidates(_ blob: Data) -> (codes: (type: String, subtype: String, manufacturer: String)?, versions: [SavedVersion]) {
        let all = extract(from: blob)
        if let (key, versions) = all.first {
            let parts = key.dropFirst(3).split(separator: "/").map(String.init)
            return (parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil, versions)
        }
        return (nil, scan(blob).map { [$0] } ?? [])
    }

    // MARK: Conventions

    static func find(in blob: Data) -> SavedVersion? {
        let hay = blob.count > maxScan ? blob.prefix(maxScan) : blob
        if let m = hay.range(of: iPlugMarker, in: hay.startIndex..<min(hay.endIndex, hay.startIndex + 64)) {
            let lenStart = m.upperBound
            if hay.distance(from: lenStart, to: hay.endIndex) >= 4 {
                let len = (0..<4).reduce(0) { $0 | Int(hay[hay.index(lenStart, offsetBy: $1)]) << (8 * $1) }
                let vStart = hay.index(lenStart, offsetBy: 4)
                if len > 0, len <= 24, hay.distance(from: vStart, to: hay.endIndex) >= len,
                   let v = String(data: hay.subdata(in: vStart..<hay.index(vStart, offsetBy: len)), encoding: .utf8),
                   isDottedVersion(v) { return SavedVersion(version: v, source: "plugin state header") }
            }
        }
        for p in patterns {
            var from = hay.startIndex
            let needle = Data(p.needle.utf8)
            while let r = hay.range(of: needle, in: from..<hay.endIndex) {
                from = r.upperBound
                if p.boundary, r.lowerBound > hay.startIndex {
                    let prev = hay[hay.index(before: r.lowerBound)]
                    if (0x41...0x5A).contains(prev) || (0x61...0x7A).contains(prev) { continue }
                }
                var bytes: [UInt8] = []
                var i = r.upperBound
                while i < hay.endIndex, bytes.count < 24, !p.terminators.contains(hay[i]) { bytes.append(hay[i]); i = hay.index(after: i) }
                if let v = String(bytes: bytes, encoding: .utf8), isDottedVersion(v) { return SavedVersion(version: v, source: p.source) }
            }
        }
        return nil
    }

    // MARK: Generic search

    /// Looks for `…version…: x.y.z` (three or more parts) whose key doesn't describe a format, schema or dependency,
    /// and for the highest `ChunkVersion="x.y.z"` (Antares writes one state chunk per plugin version it is compatible with).
    /// Only windows around the word "ersion" are examined, so large binary states stay cheap.
    static func findGeneric(in blob: Data) -> SavedVersion? {
        let hay = blob.count > maxScan ? blob.prefix(maxScan) : blob
        let needle = Data("ersion".utf8)
        var from = hay.startIndex, hits = 0
        var chunkMax: String?
        while hits < 4000, let r = hay.range(of: needle, in: from..<hay.endIndex) {
            from = r.upperBound; hits += 1
            let lo = max(hay.startIndex, hay.index(r.lowerBound, offsetBy: -26, limitedBy: hay.startIndex) ?? hay.startIndex)
            let hi = hay.index(r.upperBound, offsetBy: 40, limitedBy: hay.endIndex) ?? hay.endIndex
            let window = String(decoding: hay[lo..<hi].map { $0 >= 0x20 && $0 < 0x7F && $0 != 0x5C ? $0 : 0x20 }, as: UTF8.self)
            let ns = window as NSString
            guard let m = genericRegex.firstMatch(in: window, range: NSRange(location: 0, length: ns.length)) else { continue }
            if m.range(at: 1).location == 0, lo > hay.startIndex { continue }   // key was cut by the window
            let keyText = ns.substring(with: m.range(at: 1)), value = ns.substring(with: m.range(at: 2))
            guard isDottedVersion(value) else { continue }
            if keyText.lowercased().hasSuffix("chunkversion") {
                if chunkMax == nil || compare(chunkMax!, value) == .orderedAscending { chunkMax = value }
                continue
            }
            if genericKeyExclusions.contains(where: keyText.lowercased().contains) { continue }
            return SavedVersion(version: value, source: "\(keyText) field", confidence: .heuristic)
        }
        if let chunkMax { return SavedVersion(version: chunkMax, source: "highest ChunkVersion in the state", confidence: .heuristic) }
        return nil
    }

    /// Inflates a zlib stream that starts within the first 32 bytes (iZotope and others compress their state this way).
    static func inflate(_ blob: Data) -> Data? {
        let head = blob.prefix(34)
        guard head.count >= 3 else { return nil }
        let bytes = [UInt8](head)
        for i in 0..<(bytes.count - 1) where bytes[i] == 0x78 && [0x01, 0x5E, 0x9C, 0xDA].contains(bytes[i + 1]) {
            if (Int(bytes[i]) * 256 + Int(bytes[i + 1])) % 31 != 0 { continue }
            let body = blob.subdata(in: (blob.startIndex + i + 2)..<blob.endIndex)
            if let out = try? (body as NSData).decompressed(using: .zlib) as Data, out.count <= maxInflated, !out.isEmpty { return out }
            // Trailing bytes after the stream (checksums, padding) make strict decoding fail; retry without the last 4.
            if body.count > 8, let out = try? (body.dropLast(4) as NSData).decompressed(using: .zlib) as Data, !out.isEmpty, out.count <= maxInflated { return out }
        }
        return nil
    }

    // MARK: Helpers

    /// "2.0.5", "1.3", "10.0.0.1": digits separated by dots, at least one dot. Bare integers are too ambiguous.
    static func isDottedVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    static func fourCC(_ n: Int) -> String {
        let u = UInt32(truncatingIfNeeded: n)
        return String(decoding: [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)], as: UTF8.self)
    }

    /// AU component version: major<<16 | minor<<8 | bugfix.
    static func decodeComponentVersion(_ v: Int) -> String { "\((v >> 16) & 0xFFFF).\((v >> 8) & 0xFF).\(v & 0xFF)" }

    /// The product generation in a plugin name: the first standalone 1-2 digit number after a word ("Ozone 12", "RX 11 De-re", "Pro-Q 4").
    /// Four-digit model numbers ("1176") and alphanumeric codes ("610-A") are ignored.
    static func generation(inName name: String) -> String? {
        guard let r = name.range(of: #"(?<=[A-Za-z)\-]) (\d{1,2})(?= |$)"#, options: .regularExpression) else { return nil }
        return name[r].trimmingCharacters(in: .whitespaces)
    }

    /// Compares dotted versions numerically. nil if either side isn't dotted-numeric.
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        func nums(_ s: String) -> [Int]? {
            let head = s.split(separator: " ").first.map(String.init) ?? s
            let p = head.split(separator: ".").map { Int($0) }
            return p.contains(where: { $0 == nil }) || p.isEmpty ? nil : p.compactMap { $0 }
        }
        guard var x = nums(a), var y = nums(b) else { return nil }
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        for (l, r) in zip(x, y) where l != r { return l < r ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}
