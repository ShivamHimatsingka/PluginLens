import Foundation

// MARK: - Cubase and Nuendo (.cpr, .npr)

/// Cubase and Nuendo projects are RIFF-style files (`RIFF` or `RIF2`, a size, `NUND`, `ROOT`...) holding a tree of named values. Strings are a one-byte length followed by the text
/// (older versions omit the terminating NUL). Two things are read, using the layout that is the same from Cubase SX 3 to Cubase 14:
/// - the saving application: after `PAppVersion\0`, nine bytes on (thirteen for `RIF2`), the tokens application ("Cubase", "Nuendo"), "Version x.y.z", release date and architecture (absent before Cubase 4.5);
/// - every plugin instance: after `Plugin UID\0`, 22 bytes on, the plugin's 32-digit class ID (GUID), then the key `Plugin Name` and its value. When an instrument track has been renamed, `Plugin Name`
///   holds the track title and the plugin's own name follows under the key `Original Plugin Name`.
/// VST2 plugins appear with a wrapper class ID of the form "VST" + the four-character VST2 ID + nine characters of the name (Sylenth1 is `VST` `syl1` `sylenth1`).
enum CubaseParser {
    /// Objects every channel carries; they are part of the mixer, not plugins the user chose.
    private static let structural: Set<String> = ["Standard Panner", "Input Filter", "Output Filter"]
    /// Plugins that ship with Cubase and Nuendo (as seen in real projects and Steinberg's documentation).
    private static let steinberg: Set<String> = ["EQ", "Mystic", "Prologue", "Spector", "Retrologue", "Padshop", "MultiScope", "MixConvert V6", "Groove Agent SE", "HALion Sonic SE",
        "StudioEQ", "Frequency", "Squasher", "REVerence", "RoomWorks", "Quadrafuzz v2", "Vintage Compressor", "Tube Compressor", "Brickwall Limiter", "Maximizer",
        "DeEsser", "Gate", "Expander", "Compressor", "Limiter", "Distortion", "Chopper", "AutoPan", "Phaser", "Flanger", "Chorus", "StereoEnhancer", "Metalizer", "Octaver",
        "Pitch Correct", "VocalChain", "SuperVision", "Imager", "MonoToStereo", "Mix6To2", "DualFilter", "Tranceformer", "Grungelizer", "Bitcrusher", "Rotary", "Tuner",
        "TrackComp", "UV22HR", "Lin Dither", "ArtsAcousticReverb"]

    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 64 else { throw ProjectError.corrupt("the project is only \(data.count) bytes long") }
        let b = [UInt8](data)
        let isRIF2 = Array(b[0..<4]) == Array("RIF2".utf8)
        guard Array(b[0..<4]) == Array("RIFF".utf8) || isRIF2 else { throw ProjectError.unsupportedFormat("the file is not a Cubase/Nuendo project (no RIFF header)") }
        guard Array(b[8..<12]) == Array("NUND".utf8) || isRIF2 else { throw ProjectError.unsupportedFormat("the RIFF file is not a Cubase/Nuendo project (form type is not NUND)") }

        var warnings: [String] = []
        var app: String?, version: String?, date: String?, arch: String?
        var found: [FoundPlugin] = []
        var i = 0
        let appKey = Array("PAppVersion\0".utf8), uidKey = Array("Plugin UID\0".utf8)

        if let at = find(appKey, in: b, from: 0) {
            var j = at + appKey.count + 9 + (isRIF2 ? 4 : 0)
            if let (a, n) = token(b, j) {
                app = a; j += n + 3
                if let (v, n2) = token(b, j) {
                    version = v.hasPrefix("Version ") ? String(v.dropFirst(8)) : v; j += n2 + 3
                    if let (d, n3) = token(b, j) { date = d; j += n3 + 7; arch = token(b, j)?.0 }
                }
            }
        }
        guard app != nil else { throw ProjectError.corrupt("the project has no readable application header") }
        if version == nil { warnings.append("The project does not say which version saved it.") }

        while let at = find(uidKey, in: b, from: i) {
            i = at + uidKey.count
            var j = i + 22
            guard let (guid, n1) = token(b, j), guid.count == 32, guid.allSatisfy(\.isHexDigit) else { warnings.append("A plugin entry was cut off or unreadable."); continue }
            j += n1 + 3
            guard let (key, n2) = token(b, j), key == "Plugin Name" else { warnings.append("A plugin entry has no name."); continue }
            j += n2 + 5
            guard var (name, n3) = token(b, j) else { warnings.append("A plugin entry has no name."); continue }
            j += n3 + 3
            // A renamed instrument track: the real plugin name follows.
            if let (k2, n4) = token(b, j), k2 == "Original Plugin Name", let (orig, _) = token(b, j + n4 + 5), !orig.isEmpty { name = orig }
            if name.isEmpty || structural.contains(name) { continue }
            var p = FoundPlugin(format: .vst3, name: name, vendor: nil)
            p.classID = guid.uppercased()
            if steinberg.contains(name) { p.vendor = "Steinberg"; p.isHostBuiltIn = true; p.format = .dawBuiltIn }
            else if let vst2 = vst2Wrapper(guid) { p.format = .vst; p.auFullName = nil; p.fileName = nil; p.vendor = vst2.id.isEmpty ? nil : nil }
            found.append(p)
        }
        let savedWith = [app, version].compactMap { $0 }.joined(separator: " ")
        var doc = HostDocument(host: (app ?? "").hasPrefix("Nuendo") ? .nuendo : .cubase, savedWith: savedWith, savedVersion: version.flatMap { HostDocument.dotted(in: $0) },
                               plugins: HostDocument.merged(found))
        doc.warnings = warnings
        _ = (date, arch)
        return doc
    }

    /// The VST2 four-character ID and name prefix packed into a wrapper class ID ("VST" + id + name), if this is one.
    static func vst2Wrapper(_ guid: String) -> (id: String, name: String)? {
        let g = guid.uppercased()
        guard g.hasPrefix("565354"), g.count == 32 else { return nil }
        let bytes = stride(from: 0, to: 32, by: 2).compactMap { UInt8(g[g.index(g.startIndex, offsetBy: $0)..<g.index(g.startIndex, offsetBy: $0 + 2)], radix: 16) }
        guard bytes.count == 16, bytes[3...].allSatisfy({ $0 == 0 || ($0 >= 0x20 && $0 < 0x7F) }) else { return nil }
        return (String(decoding: bytes[3..<7], as: UTF8.self), String(decoding: bytes[7...].prefix { $0 != 0 }, as: UTF8.self))
    }

    /// A token: one length byte, then that many bytes (up to the first NUL).
    static func token(_ b: [UInt8], _ i: Int) -> (String, Int)? {
        guard i >= 0, i < b.count else { return nil }
        let len = Int(b[i])
        guard i + 1 + len <= b.count else { return nil }
        let raw = b[(i + 1)..<(i + 1 + len)]
        return (String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self), len + 1)
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
/// Plugins are found three ways, all seen in real projects:
/// - **VST3 device records**: field 0x0CE4 (the 32-digit class ID), 0x0C5E (the plugin version that saved it, e.g. `2.0.5.0`) and 0x0199 (the device name, empty in projects saved on Windows,
///   where the plugin's file path sits just before the record instead);
/// - **plugin file paths**: strings ending in `.vst3`, `.dll` (VST2, under a VST folder), `.component` or `.clap`, whose file name identifies the plugin;
/// - **Bitwig's own devices**: strings ending in `.bwdevice` (`...\library\devices\EQ-2.bwdevice`).
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

        // The text of the file, with everything that isn't printable ASCII turned into NUL, for path searching.
        let text = String(decoding: b.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0 }, as: UTF8.self)
        let paths = pluginPaths(in: text)

        var order: [String] = [], byStem: [String: FoundPlugin] = [:]
        func add(_ p: FoundPlugin, stem: String) {
            let k = InstalledPluginIndex.normalize(stem) + ":" + p.format.rawValue
            if var e = byStem[k] {
                if e.classID == nil { e.classID = p.classID }
                if e.knownSaved.isEmpty { e.knownSaved = p.knownSaved }
                e.states += p.states; e.count += 1; byStem[k] = e
            } else { order.append(k); byStem[k] = p }
        }

        // VST3 device records.
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
            // Windows projects leave the name empty; the plugin's file path sits shortly before the record.
            if name == nil || name!.isEmpty {
                let lo = max(0, at - 700)
                let before = String(decoding: b[lo..<at].map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0 }, as: UTF8.self)
                name = pluginPaths(in: before).last.map { stem($0.path) }
            }
            guard let name, !name.isEmpty else { continue }
            var p = FoundPlugin(format: .vst3, name: name, vendor: nil)
            p.classID = cid; p.states = states[cid] ?? []
            if let ver, SavedVersionExtractor.isDottedVersion(ver) { p.knownSaved = [SavedVersion(version: ver, source: "Bitwig device record", confidence: .convention)] }
            add(p, stem: name)
        }

        // Plugin files and Bitwig's own devices referenced by path.
        for ref in paths {
            let st = stem(ref.path)
            var p = FoundPlugin(format: ref.format, name: st, vendor: nil, fileName: (ref.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
            if ref.format == .dawBuiltIn { p.vendor = "Bitwig"; p.isHostBuiltIn = true; p.fileName = nil }
            add(p, stem: st)
        }
        return HostDocument(host: .bitwig, savedWith: version.map { "Bitwig Studio \($0)" }, savedVersion: version, plugins: order.compactMap { byStem[$0] })
    }

    private static func stem(_ path: String) -> String {
        let file = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        return (file as NSString).deletingPathExtension
    }

    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?:[A-Za-z]:\\|/)[^\x00"<>|]{2,300}?\.(vst3|dll|component|vst|clap|bwdevice)\b"#, options: [.caseInsensitive])

    /// Absolute paths to plugin files and Bitwig devices. A `.dll` only counts under a VST folder (otherwise it is some other library).
    static func pluginPaths(in text: String) -> [(path: String, format: PluginFormat)] {
        let ns = text as NSString
        var out: [(String, PluginFormat)] = []
        var seen = Set<String>()
        for m in pathRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range)
            let ext = ns.substring(with: m.range(at: 1)).lowercased()
            guard seen.insert(path.lowercased()).inserted else { continue }
            let lower = path.lowercased()
            switch ext {
            case "vst3": out.append((path, .vst3))
            case "component": out.append((path, .au))
            case "clap": out.append((path, .clap))
            case "vst": out.append((path, .vst))
            case "dll": if lower.contains("vst") { out.append((path, .vst)) }
            case "bwdevice": out.append((path, .dawBuiltIn))
            default: break
            }
        }
        return out
    }
}
