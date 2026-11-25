import Foundation

// MARK: - DAWproject (.dawproject)

/// DAWproject is an open exchange format (github.com/bitwig/dawproject) that Bitwig Studio, Studio One, Cubase and others can export.
/// A `.dawproject` is a ZIP archive whose `project.xml` follows the published `Project.xsd`. Devices are the children of `<Devices>`:
/// `Vst2Plugin`, `Vst3Plugin`, `ClapPlugin`, `AuPlugin` (each a `plugin`, with `deviceName`, `deviceVendor`, `deviceID` and `pluginVersion`),
/// and built-in devices (`BuiltinDevice`, `Equalizer`, `Compressor`, `NoiseGate`, `Limiter`, generic `Device`).
/// `pluginVersion` is the plugin version the exporting DAW recorded, so it is used directly as the saved version.
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
        var doc = HostDocument(host: .dawproject, savedWith: app.isEmpty ? nil : app, savedVersion: HostDocument.dotted(in: d.appVersion),
                               plugins: HostDocument.merged(d.plugins))
        doc.hostLabel = d.appName
        return doc
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var plugins: [FoundPlugin] = []
        var appName: String?, appVersion: String?
        var sawProject = false
        private var inDevices = 0
        private static let builtIns: Set<String> = ["BuiltinDevice", "Equalizer", "Compressor", "NoiseGate", "Limiter", "Device"]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "Project": sawProject = true
            case "Application": appName = a["name"]; appVersion = a["version"]
            case "Devices": inDevices += 1
            case "Vst2Plugin", "Vst3Plugin", "ClapPlugin", "AuPlugin":
                guard inDevices > 0, let n = a["deviceName"] else { return }
                var p = FoundPlugin(format: name == "Vst3Plugin" ? .vst3 : name == "Vst2Plugin" ? .vst : name == "ClapPlugin" ? .clap : .au, name: n, vendor: a["deviceVendor"])
                if name == "AuPlugin" { p.auFullName = [a["deviceVendor"], n].compactMap { $0 }.joined(separator: ": ") }
                if let v = a["pluginVersion"], !v.isEmpty {
                    p.knownSaved = [SavedVersion(version: v, source: "DAWproject pluginVersion", confidence: .convention)]
                }
                plugins.append(p)
            default:
                guard inDevices > 0, Self.builtIns.contains(name), let n = a["deviceName"] else { return }
                plugins.append(FoundPlugin(format: .dawBuiltIn, name: n, vendor: a["deviceVendor"], isHostBuiltIn: true))
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "Devices" { inDevices -= 1 } }
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
