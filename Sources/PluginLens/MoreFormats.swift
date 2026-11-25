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
        let zip = try ZipArchive(file)
        guard zip.has("project.xml") else { throw ProjectError.unsupportedFormat("the archive has no project.xml (not a DAWproject)") }
        let xml = try zip.read("project.xml")
        let d = Delegate()
        let parser = XMLParser(data: xml); parser.delegate = d
        guard parser.parse() || !d.plugins.isEmpty else { throw ProjectError.corrupt("project.xml could not be read: \(parser.parserError?.localizedDescription ?? "unknown error")") }
        guard d.sawProject else { throw ProjectError.unsupportedFormat("project.xml is not a DAWproject document") }
        let app = [d.appName, d.appVersion].compactMap { $0 }.joined(separator: " ")
        var plugins = d.plugins
        for (index, path) in d.statePaths where index < plugins.count {
            if let state = try? zip.read(path), state.count <= 16 * 1024 * 1024 { plugins[index].states = [state] }
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
        private static let builtIns: Set<String> = ["BuiltinDevice", "Equalizer", "Compressor", "NoiseGate", "Limiter", "Device"]

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
                guard inDevices > 0, Self.builtIns.contains(name), let n = a["deviceName"] else { return }
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

/// A Studio One song is a ZIP archive. The files that name plugins are `Song/song.xml`, `Song/mediapool.xml` and `Devices/audiomixer.xml`; they are XML that uses prefixes it never declares
/// (`x:id`) and C++ scope names (`ProcessGraph::SlotNode`), which are removed before parsing. Plugins are:
/// - `AudioDevice` elements (song.xml, mediapool.xml) with a `deviceName` attribute: "Vendor/Plugin Name" for third-party plugins, a bare name for Studio One's own;
/// - `AudioEffectClipItem` elements (mediapool.xml) with `name` and `classID`;
/// - `Attributes` elements (audiomixer.xml) with a `pname` attribute (not "default").
/// This follows the structure published by the community "Studio One Tools" project; no real song was available to check it against, so the plugin format is not known (VST3, AU and VST2 are tried).
enum StudioOneSongParser {
    static func parse(_ file: Data) throws -> HostDocument {
        let zip = try ZipArchive(file)
        guard zip.has("Song/song.xml") else { throw ProjectError.unsupportedFormat("the archive has no Song/song.xml (not a Studio One song)") }
        var found: [FoundPlugin] = []
        var seenAny = false
        for (path, kind) in [("Song/song.xml", 0), ("Song/mediapool.xml", 1), ("Devices/audiomixer.xml", 2)] {
            guard zip.has(path), let raw = try? zip.read(path) else { continue }
            let d = Delegate(kind: kind)
            let parser = XMLParser(data: clean(raw)); parser.delegate = d
            _ = parser.parse()
            if d.sawElement { seenAny = true }
            found += d.plugins
        }
        guard seenAny || !found.isEmpty else { throw ProjectError.corrupt("the song's XML could not be read") }
        var version: String?
        if let meta = try? zip.read("metainfo.xml"), let text = String(data: meta, encoding: .utf8), let r = text.range(of: #"Studio One[^<"]*?(\d+(\.\d+)+)"#, options: .regularExpression) {
            version = HostDocument.dotted(in: String(text[r]))
        }
        var doc = HostDocument(host: .studioOne, savedWith: version.map { "Studio One \($0)" }, savedVersion: version, plugins: HostDocument.merged(found))
        doc.warnings.append("Studio One songs are read from their documented structure and have not been checked against a real song. Exporting a DAWproject file is more reliable.")
        return doc
    }

    /// Removes undeclared namespace prefixes and C++ scope operators so the XML parses.
    static func clean(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.replacingOccurrences(of: "::", with: "")
        let rules: [(String, String)] = [(#"(</?)(?:[A-Za-z_][\w.\-]*:)+([A-Za-z_][\w.\-]*)"#, "$1$2"), (#"(\s)(?:[A-Za-z_][\w.\-]*:)+([A-Za-z_][\w.\-]*)(\s*=)"#, "$1$2$3")]
        for (pattern, template) in rules {
            if let re = try? NSRegularExpression(pattern: pattern) { text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template) }
        }
        return Data(text.utf8)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let kind: Int
        var plugins: [FoundPlugin] = []
        var sawElement = false
        init(kind: Int) { self.kind = kind }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            sawElement = true
            switch (name, kind) {
            case ("AudioDevice", _): if let n = a["deviceName"], !n.isEmpty { add(n, classID: a["classID"]) }
            case ("AudioEffectClipItem", _): if let n = a["name"], !n.isEmpty { add(n, classID: a["classID"]) }
            case ("Attributes", 2): if let n = a["pname"], !n.isEmpty, n.lowercased() != "default" { add(n, classID: nil) }
            default: break
            }
        }

        private func add(_ deviceName: String, classID: String?) {
            let parts = deviceName.split(separator: "/", maxSplits: 1).map(String.init)
            var p: FoundPlugin
            if parts.count == 2 {
                p = FoundPlugin(format: .vst3, name: parts[1], vendor: parts[0]); p.formatGuess = true
            } else {
                p = FoundPlugin(format: .dawBuiltIn, name: deviceName, vendor: "PreSonus", isHostBuiltIn: true)
            }
            if let c = classID {
                let hex = c.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "").uppercased()
                if hex.count == 32, hex.allSatisfy(\.isHexDigit) { p.classID = hex }
            }
            plugins.append(p)
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
