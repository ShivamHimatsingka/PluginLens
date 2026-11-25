import Foundation

// MARK: - Cubase and Nuendo (.cpr, .npr)

/// Cubase and Nuendo projects are RIFF-style files (`RIFF` size `NUND` `ROOT`...) holding a tree of named, length-prefixed values. Two things are read:
/// - the saving application: an `AppVersion` object with the product name ("Cubase", "Nuendo") and a "Version x.y.z" string;
/// - every plugin instance: a `Plugin UID` object (a `GUID` string, the VST3 class ID) followed by a `Plugin Name` value.
///   Strings are stored as a key (u32 length, text, NUL), a 2-byte type (`00 08`), a big-endian u32 length that includes the terminating NUL and a UTF-8 byte-order mark, then the text.
enum CubaseParser {
    /// Objects every channel carries; they are part of the mixer, not plugins the user chose.
    private static let structural: Set<String> = ["Standard Panner", "Input Filter", "Output Filter", "Audio Input Count", "Audio Output Count"]
    /// Plugins that ship with Cubase and Nuendo.
    private static let steinberg: Set<String> = ["EQ", "Mystic", "Prologue", "Spector", "Retrologue", "Padshop", "MultiScope", "MixConvert V6", "Groove Agent SE", "HALion Sonic SE",
        "StudioEQ", "Frequency", "Squasher", "REVerence", "RoomWorks", "Quadrafuzz v2", "Vintage Compressor", "Tube Compressor", "Brickwall Limiter", "Maximizer",
        "DeEsser", "Gate", "Expander", "Compressor", "Limiter", "Distortion", "Chopper", "AutoPan", "Phaser", "Flanger", "Chorus", "StereoEnhancer", "Metalizer", "Octaver",
        "Pitch Correct", "VocalChain", "SuperVision", "Imager", "MonoToStereo", "Mix6To2", "DualFilter", "Tranceformer", "Grungelizer", "Bitcrusher", "Rotary", "Tuner"]

    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 64 else { throw ProjectError.corrupt("the project is only \(data.count) bytes long") }
        guard data.prefix(4) == Data("RIFF".utf8), data[(data.startIndex + 8)..<(data.startIndex + 12)] == Data("NUND".utf8) else {
            throw ProjectError.unsupportedFormat("the file is not a Cubase/Nuendo project (no RIFF NUND header)")
        }
        let b = [UInt8](data)
        // Saving application.
        var app: String?, version: String?
        let head = String(decoding: b.prefix(2048).map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x20 }, as: UTF8.self)
        if let r = head.range(of: #"(Cubase|Nuendo)\s+\S*\s*Version (\d+(\.\d+)+)"#, options: .regularExpression) {
            let t = String(head[r]); app = t.hasPrefix("Nuendo") ? "Nuendo" : "Cubase"
            version = t.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(t[$0]) }
        } else if let r = head.range(of: #"Version (\d+(\.\d+)+)"#, options: .regularExpression) {
            version = head[r].range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(head[r][$0]) }
            app = head.contains("Nuendo") ? "Nuendo" : "Cubase"
        }

        var found: [FoundPlugin] = []
        var from = 0
        let key = Array("Plugin Name\0".utf8)
        while let at = find(key, in: b, from: from) {
            from = at + key.count
            guard let name = stringValue(b, at: from), !name.isEmpty, name.count <= 120 else { continue }
            if structural.contains(name) { continue }
            let guid = nearestGUID(b, before: at)
            var p = FoundPlugin(format: .vst3, name: name, vendor: nil)
            if steinberg.contains(name) { p.vendor = "Steinberg"; p.isHostBuiltIn = true; p.format = .dawBuiltIn }
            if let guid { p.auFullName = nil; p.fileName = nil; p.classID = guid }
            found.append(p)
        }
        var doc = HostDocument(host: app == "Nuendo" ? .nuendo : .cubase, savedWith: [app, version].compactMap { $0 }.joined(separator: " "),
                               savedVersion: version, plugins: HostDocument.merged(found))
        if version == nil { doc.warnings.append("The project does not say which version saved it.") }
        return doc
    }

    /// A string value after a key (and its NUL): type `00 08`, u32 length (text + NUL + optional BOM), text.
    static func stringValue(_ b: [UInt8], at i: Int) -> String? {
        guard i + 6 <= b.count, b[i] == 0, b[i + 1] == 8 else { return nil }
        let len = Int(b[i + 2]) << 24 | Int(b[i + 3]) << 16 | Int(b[i + 4]) << 8 | Int(b[i + 5])
        guard len > 0, len <= 4096, i + 6 + len <= b.count else { return nil }
        return String(decoding: b[(i + 6)..<(i + 6 + len)].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The closest `GUID` string (32 hex digits, the VST3 class ID) before `index`, within a short distance.
    static func nearestGUID(_ b: [UInt8], before index: Int) -> String? {
        let key = Array("GUID\0".utf8)
        let lo = max(0, index - 400)
        var best: String?
        var from = lo
        while let at = find(key, in: b, from: from), at < index {
            if let g = stringValue(b, at: at + key.count), g.count == 32, g.allSatisfy(\.isHexDigit) { best = g.uppercased() }
            from = at + key.count
        }
        return best
    }

    static func find(_ needle: [UInt8], in b: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, b.count >= needle.count, from <= b.count - needle.count else { return nil }
        let first = needle[0]
        var i = from
        let last = b.count - needle.count
        while i <= last {
            if b[i] == first {
                var k = 1
                while k < needle.count, b[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Bitwig Studio (.bwproject)

/// A Bitwig project starts with `BtWg` and a hex-text header, followed by a stream of typed fields: `00 00 <id hi> <id lo> <type>`; for type 8 (string) a big-endian u32 length and the text.
/// A VST3 device is identified by field 0x0CE4 (the 32-digit class ID), 0x0C5E (the plugin version that saved it) and 0x0199 (the device name).
/// The file ends with a ZIP archive that holds each VST3 plugin's saved state as `plugin-states/<uuid>.vstpreset`; a `.vstpreset`'s header carries the class ID.
/// The saving application's version is the `application_version_name` entry of the `meta` object.
enum BitwigParser {
    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 64 else { throw ProjectError.corrupt("the project is only \(data.count) bytes long") }
        guard data.prefix(4) == Data("BtWg".utf8) else { throw ProjectError.unsupportedFormat("the file does not start with BtWg") }
        let b = [UInt8](data)

        var version: String?
        if let at = CubaseParser.find(Array("application_version_name".utf8), in: b, from: 0) {
            let window = String(decoding: b[at..<min(b.count, at + 64)].map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x20 }, as: UTF8.self)
            version = window.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(window[$0]) }
        }

        // Plugin states in the trailing ZIP, keyed by class ID.
        var states: [String: [Data]] = [:]
        if let zip = try? ZipArchive(data) {
            for e in zip.entries where e.name.hasSuffix(".vstpreset") {
                guard let d = try? zip.read(e.name), d.count >= 48, d.prefix(4) == Data("VST3".utf8) else { continue }
                let cid = String(decoding: d[(d.startIndex + 8)..<(d.startIndex + 40)], as: UTF8.self).uppercased()
                states[cid, default: []].append(d)
            }
        }

        var found: [FoundPlugin] = []
        let marker: [UInt8] = [0, 0, 0x0C, 0xE4, 8, 0, 0, 0, 0x20]
        var from = 0
        while let at = CubaseParser.find(marker, in: b, from: from) {
            from = at + marker.count
            guard at + marker.count + 32 <= b.count else { break }
            let cid = String(decoding: b[(at + marker.count)..<(at + marker.count + 32)], as: UTF8.self).uppercased()
            guard cid.allSatisfy(\.isHexDigit) else { continue }
            let tail = at + marker.count + 32
            var name: String?, ver: String?
            var i = tail
            let limit = min(b.count - 9, tail + 160)
            while i < limit {
                if b[i] == 0, b[i + 1] == 0, b[i + 4] == 8, b[i + 5] == 0, b[i + 6] == 0 {
                    let id = Int(b[i + 2]) << 8 | Int(b[i + 3])
                    let len = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    if (id == 0x0C5E || id == 0x0199), len > 0, len < 200, i + 9 + len <= b.count {
                        let s = String(decoding: b[(i + 9)..<(i + 9 + len)].prefix { $0 != 0 }, as: UTF8.self)
                        if id == 0x0C5E { ver = s } else if name == nil { name = s }
                        i += 9 + len; continue
                    }
                }
                i += 1
            }
            guard let name, !name.isEmpty else { continue }
            var p = FoundPlugin(format: .vst3, name: name, vendor: nil)
            p.classID = cid
            p.states = states[cid] ?? []
            if let ver, SavedVersionExtractor.isDottedVersion(ver) { p.knownSaved = [SavedVersion(version: ver, source: "Bitwig device record", confidence: .convention)] }
            found.append(p)
        }
        return HostDocument(host: .bitwig, savedWith: version.map { "Bitwig Studio \($0)" }, savedVersion: version, plugins: HostDocument.merged(found))
    }
}
