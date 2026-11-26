import Foundation

// MARK: - DAWproject (.dawproject)

/// DAWproject is an open exchange format (github.com/bitwig/dawproject) that Bitwig Studio, Studio One, Cubase and others can export.
/// A `.dawproject` is a ZIP archive whose `project.xml` follows the published `Project.xsd`. Devices are the children of `<Devices>`:
/// `Vst2Plugin`, `Vst3Plugin`, `ClapPlugin`, `AuPlugin` (each a `plugin`, with `deviceName`, `deviceVendor`, `deviceID` and `pluginVersion`),
/// and built-in devices (`BuiltinDevice`, `Equalizer`, `Compressor`, `NoiseGate`, `Limiter`, generic `Device`).
/// `pluginVersion` is the plugin version the exporting DAW recorded, so it is used directly as the saved version.
/// `deviceID` is the VST3 class ID in canonical UUID form (8-4-4-4-12), the VST2 unique ID in decimal, or the CLAP plugin ID as is. A plugin's `<State path="...">` points to its saved state inside the
/// archive (`.vstpreset` for VST3, `.clap-preset` for CLAP, FXB/FXP for VST2), which is scanned for the plugin's own version as well. Applications that write DAWproject include
/// Bitwig Studio, PreSonus Studio One (6.5 and later), Cubase and Nuendo (14 and later), Cubasis, VST Live and n-Track.
enum DawprojectParser {
    static func parse(_ file: Data) throws -> HostDocument {
        // Some tools write the bare project.xml instead of the zip container.
        let bare = file.prefix(64).starts(with: Data("<?xml".utf8)) || file.prefix(64).starts(with: Data("<Project".utf8))
        let zip: ZipArchive? = bare ? nil : try ZipArchive(file)
        if let zip, !zip.has("project.xml") { throw ProjectError.unsupportedFormat("the archive has no project.xml (not a DAWproject)") }
        let xml = try zip?.read("project.xml") ?? file
        let d = Delegate()
        let parser = XMLParser(data: xml); parser.delegate = d
        guard parser.parse() || !d.plugins.isEmpty else { throw ProjectError.corrupt("project.xml could not be read: \(parser.parserError?.localizedDescription ?? "unknown error")") }
        guard d.sawProject else { throw ProjectError.unsupportedFormat("project.xml is not a DAWproject document") }
        let app = [d.appName, d.appVersion].compactMap { $0 }.joined(separator: " ")
        var plugins = d.plugins
        for (index, path) in d.statePaths where index < plugins.count {
            if let state = try? zip?.read(path), state.count <= 16 * 1024 * 1024 { plugins[index].states = [state] }
        }
        var doc = HostDocument(host: .dawproject, savedWith: app.isEmpty ? nil : app, savedVersion: HostDocument.dotted(in: d.appVersion),
                               plugins: HostDocument.merged(plugins))
        doc.hostLabel = d.appName
        return doc
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var plugins: [FoundPlugin] = []
        var appName: String?, appVersion: String?
        var sawProject = false
        /// Index in `plugins` -> path of its state file in the archive.
        var statePaths: [Int: String] = [:]
        private var inDevices = 0
        private var lastPlugin: Int?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "Project": sawProject = true
            case "Application": appName = a["name"]; appVersion = a["version"]
            case "Devices": inDevices += 1
            case "Vst2Plugin", "Vst3Plugin", "ClapPlugin", "AuPlugin":
                guard inDevices > 0, let n = a["deviceName"] else { return }
                var p = FoundPlugin(format: name == "Vst3Plugin" ? .vst3 : name == "Vst2Plugin" ? .vst : name == "ClapPlugin" ? .clap : .au, name: n, vendor: a["deviceVendor"])
                if name == "Vst3Plugin", let id = a["deviceID"] {
                    let hex = id.replacingOccurrences(of: "-", with: "").uppercased()
                    if hex.count == 32, hex.allSatisfy(\.isHexDigit) { p.classID = hex }
                }
                if name == "AuPlugin" { p.auFullName = [a["deviceVendor"], n].compactMap { $0 }.joined(separator: ": ") }
                if let v = a["pluginVersion"], !v.isEmpty {
                    p.knownSaved = [SavedVersion(version: v, source: "DAWproject pluginVersion", confidence: .convention)]
                }
                plugins.append(p)
                lastPlugin = plugins.count - 1
            case "State":
                if inDevices > 0, let path = a["path"], let i = lastPlugin { statePaths[i] = path }
            default:
                // Any other device element (BuiltinDevice, Equalizer, Compressor, ...) is one of the exporting application's own devices.
                guard inDevices > 0, let n = a["deviceName"] else { return }
                plugins.append(FoundPlugin(format: .dawBuiltIn, name: n, vendor: a["deviceVendor"], isHostBuiltIn: true))
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Devices" { inDevices -= 1 }
            if ["Vst2Plugin", "Vst3Plugin", "ClapPlugin", "AuPlugin"].contains(name) { lastPlugin = nil }
        }
    }
}

// MARK: - Studio One songs (.song)

/// A Studio One song is a ZIP archive of XML files (checked against a real Studio One 7.2 song, format version 8). The XML uses prefixes it never declares
/// (`x:id`) and C++ scope names (`ProcessGraph::SlotNode`), which are removed before parsing. Every plugin slot, in `Devices/audiomixer.xml` (insert effects)
/// and `Devices/audiosynthfolder.xml` (instruments), carries a `classInfo` element: `classID`, `name`, `category` (AudioEffect / AudioSynth) and `subCategory`
/// (`VST2`, `VST3`, or an Audio Unit marker). Studio One's own devices have no VST/AU sub-category, so they are told apart by structure, not by a list of names.
/// A VST2 `classID` packs "VST" + the plugin's four-character ID + its name; a VST3 `classID` is the class ID itself.
/// Older songs that have no `classInfo` fall back to `AudioDevice` / `AudioEffectClipItem` elements as documented by a community tool (not checked against a real file).
enum StudioOneSongParser {
    static func parse(_ file: Data) throws -> HostDocument {
        let zip = try ZipArchive(file)
        guard zip.has("Song/song.xml") || zip.has("metainfo.xml") else { throw ProjectError.unsupportedFormat("the archive has no Song/song.xml (not a Studio One song)") }
        var found: [FoundPlugin] = [], legacy: [FoundPlugin] = []
        var seenAny = false
        for path in zip.entries.map(\.name) where path.hasSuffix(".xml") && (path.hasPrefix("Devices/") || path.hasPrefix("Song/")) {
            guard let raw = try? zip.read(path) else { continue }
            let d = Delegate()
            let parser = XMLParser(data: clean(raw)); parser.delegate = d
            _ = parser.parse()
            if d.sawElement { seenAny = true }
            found += d.plugins; legacy += d.legacy
        }
        guard seenAny || !found.isEmpty else { throw ProjectError.corrupt("the song's XML could not be read") }
        var version: String?
        if let meta = try? zip.read("metainfo.xml"), let text = String(data: meta, encoding: .utf8), let r = text.range(of: #"Studio One[^<"]*?(\d+(\.\d+)+)"#, options: .regularExpression) {
            version = HostDocument.dotted(in: String(text[r]))
        }
        let plugins = found.isEmpty ? legacy : found
        var doc = HostDocument(host: .studioOne, savedWith: version.map { "Studio One \($0)" }, savedVersion: version, plugins: HostDocument.merged(plugins))
        if found.isEmpty, !legacy.isEmpty { doc.warnings.append("This song uses an older layout that has not been checked against a real file; exporting a DAWproject file is more reliable.") }
        return doc
    }

    /// Removes undeclared namespace prefixes and C++ scope operators so the XML parses.
    static func clean(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.replacingOccurrences(of: "::", with: "").replacingOccurrences(of: "\u{FEFF}", with: "")
        let rules: [(String, String)] = [(#"(</?)(?:[A-Za-z_][\w.\-]*:)+([A-Za-z_][\w.\-]*)"#, "$1$2"), (#"(\s)(?:[A-Za-z_][\w.\-]*:)+([A-Za-z_][\w.\-]*)(\s*=)"#, "$1$2$3")]
        for (pattern, template) in rules {
            if let re = try? NSRegularExpression(pattern: pattern) { text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template) }
        }
        return Data(text.utf8)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var plugins: [FoundPlugin] = []
        var legacy: [FoundPlugin] = []
        var sawElement = false
        private var attributeID: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            sawElement = true
            switch name {
            case "Attributes" where a["id"] == "classInfo" && a["category"] != nil:
                if let n = a["name"], !n.isEmpty { plugins.append(Self.plugin(name: n, classID: a["classID"], category: a["category"] ?? "", sub: a["subCategory"] ?? "")) }
            case "AudioDevice": if let n = a["deviceName"], !n.isEmpty { legacy.append(Self.legacyPlugin(n, classID: a["classID"])) }
            case "AudioEffectClipItem": if let n = a["name"], !n.isEmpty { legacy.append(Self.legacyPlugin(n, classID: a["classID"])) }
            default: break
            }
        }

        static func hex(_ classID: String?) -> String? {
            guard let c = classID else { return nil }
            let h = c.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "").uppercased()
            return h.count == 32 && h.allSatisfy(\.isHexDigit) ? h : nil
        }

        static func plugin(name: String, classID: String?, category: String, sub: String) -> FoundPlugin {
            let s = sub.lowercased()
            let id = hex(classID)
            if s.contains("vst3") {
                var p = FoundPlugin(format: .vst3, name: name); p.classID = id; return p
            }
            if s.contains("vst") {
                var p = FoundPlugin(format: .vst, name: name)
                if let id, let w = CubaseParser.vst2Wrapper(id) { p.ids = w.id }
                return p
            }
            if s.contains("audiounit") || s == "au" || s.contains("component") {
                var p = FoundPlugin(format: .au, name: name); p.formatGuess = true; return p
            }
            return FoundPlugin(format: .dawBuiltIn, name: name, vendor: "PreSonus", isHostBuiltIn: true)
        }

        static func legacyPlugin(_ deviceName: String, classID: String?) -> FoundPlugin {
            let parts = deviceName.split(separator: "/", maxSplits: 1).map(String.init)
            var p: FoundPlugin
            if parts.count == 2 { p = FoundPlugin(format: .vst3, name: parts[1], vendor: parts[0]); p.formatGuess = true }
            else { p = FoundPlugin(format: .dawBuiltIn, name: deviceName, vendor: "PreSonus", isHostBuiltIn: true) }
            p.classID = hex(classID)
            return p
        }
    }
}

// MARK: - LMMS (.mmp / .mmpz)

/// LMMS projects are XML (`<lmms-project creatorversion="1.2.0">`). `.mmpz` is the same XML compressed with Qt's `qCompress`:
/// a 4-byte big-endian length followed by a zlib stream. Instruments are `<instrument name="...">` (built-in, or `vestige` for a VST with a `plugin` path)
/// and effects are `<effect name="...">`; LADSPA effects name their plugin in a `<key>` element.
enum LMMSParser {
    static func parse(_ file: Data) throws -> HostDocument {
        guard file.count >= 16 else { throw ProjectError.corrupt("the project is only \(file.count) bytes long") }
        var xml = file
        if file.prefix(5) != Data("<?xml".utf8), file.prefix(5) != Data("<lmms".utf8) {
            guard file.count > 6, file[file.startIndex + 4] == 0x78 else { throw ProjectError.unsupportedFormat("not an LMMS project") }
            let body = file.subdata(in: (file.startIndex + 6)..<file.endIndex)       // skip the 4-byte size and the 2-byte zlib header
            guard let out = (try? (body as NSData).decompressed(using: .zlib) as Data) ?? (try? (body.dropLast(4) as NSData).decompressed(using: .zlib) as Data) else {
                throw ProjectError.corrupt("the compressed project is damaged")
            }
            xml = out
        }
        let d = Delegate()
        let parser = XMLParser(data: xml); parser.delegate = d
        guard parser.parse() || !d.plugins.isEmpty else { throw ProjectError.corrupt("the project's XML could not be read: \(parser.parserError?.localizedDescription ?? "unknown error")") }
        guard d.sawProject else { throw ProjectError.unsupportedFormat("the document is not an LMMS project") }
        return HostDocument(host: .lmms, savedWith: d.version.map { "LMMS \($0)" }, savedVersion: HostDocument.dotted(in: d.version), plugins: HostDocument.merged(d.plugins))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var plugins: [FoundPlugin] = []
        var version: String?
        var sawProject = false
        private var effectIndex: Int?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "lmms-project": sawProject = true; version = a["creatorversion"]
            case "instrument":
                guard let n = a["name"], !n.isEmpty else { return }
                plugins.append(n == "vestige" ? FoundPlugin(format: .vst, name: "VST instrument") : FoundPlugin(format: .dawBuiltIn, name: n, vendor: "LMMS", isHostBuiltIn: true))
            case "vestige":
                // <vestige plugin="/path/Synth.vst" ...>: replace the placeholder added for the instrument element.
                if let path = a["plugin"], let i = plugins.lastIndex(where: { $0.format == .vst && $0.name == "VST instrument" }) {
                    let file = path.replacingOccurrences(of: "\\", with: "/")
                    plugins[i].fileName = (file as NSString).lastPathComponent
                    plugins[i].name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
                }
            case "effect":
                guard let n = a["name"] else { return }
                if n == "ladspaeffect" || n == "vsteffect" { plugins.append(FoundPlugin(format: n == "vsteffect" ? .vst : .ladspa, name: n == "vsteffect" ? "VST effect" : "LADSPA effect")); effectIndex = plugins.count - 1 }
                else { plugins.append(FoundPlugin(format: .dawBuiltIn, name: n, vendor: "LMMS", isHostBuiltIn: true)); effectIndex = nil }
            case "attribute":
                // LADSPA: <key><attribute name="file" value="caps"/><attribute name="plugin" value="Plate"/></key>
                guard let i = effectIndex, let n = a["name"], let v = a["value"], plugins[i].format == .ladspa else { return }
                if n == "plugin" { plugins[i].name = v } else if n == "file" { plugins[i].fileName = v }
            case "vst":
                if let path = a["plugin"], let i = effectIndex, plugins[i].format == .vst {
                    let file = path.replacingOccurrences(of: "\\", with: "/")
                    plugins[i].fileName = (file as NSString).lastPathComponent
                    plugins[i].name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
                }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "effect" { effectIndex = nil } }
    }
}
