import Foundation
import AppKit

struct SearchDirectories: Sendable {
    var audioUnits: [URL]
    var vst: [URL]
    var vst3: [URL]
    /// Folders of apps whose `Contents/PlugIns/*.appex` may be Audio Unit v3 extensions.
    var applications: [URL] = []
    /// Folder holding Ableton Live's `Live-plugins-N.db`, if any.
    var liveDatabase: URL? = nil
    var clap: [URL] = []
    var aax: [URL] = []

    static var standard: SearchDirectories {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func dirs(_ sub: String) -> [URL] {
            [home.appendingPathComponent("Library/Audio/Plug-ins/\(sub)"),
             URL(fileURLWithPath: "/Library/Audio/Plug-ins/\(sub)")]
        }
        return SearchDirectories(
            audioUnits: dirs("Components") + [URL(fileURLWithPath: "/System/Library/Components")],
            vst: dirs("VST"),
            vst3: dirs("VST3"),
            applications: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
            liveDatabase: LiveDatabase.standardDirectory,
            clap: dirs("CLAP"),
            aax: [URL(fileURLWithPath: "/Library/Application Support/Avid/Audio/Plug-Ins"), home.appendingPathComponent("Library/Application Support/Avid/Audio/Plug-Ins")])
    }
}

/// One AudioComponent declared by an installed bundle's Info.plist.
struct InstalledComponent: Hashable, Sendable {
    var type: String
    var subtype: String
    var manufacturer: String
    /// Full declared name, usually "Manufacturer: Plugin".
    var fullName: String
    var manufacturerName: String
    var pluginName: String
    var version: String?
    var bundleURL: URL
    /// `AudioComponents` > `version`: major<<16 | minor<<8 | bugfix.
    var componentVersion: Int? = nil

    var key: String { "\(type)/\(subtype)/\(manufacturer)" }
}

/// A snapshot of what is installed. Built once per scan, then read-only.
struct InstalledPluginIndex: Sendable {
    private(set) var components: [InstalledComponent] = []
    private var byKey: [String: [InstalledComponent]] = [:]
    private var vstNames: [String: [PluginFormat: String]] = [:]
    var logicVersion: String?
    var abletonVersion: String?
    /// Names of Logic's own plugins, read from the installed Logic app (empty if Logic isn't installed).
    private(set) var logicPluginNames: [String] = []
    /// Live's device element names mapped to the names Live shows ("Eq8" -> "EQ Eight"), read from the installed Live app.
    private(set) var abletonDeviceNames: [String: String] = [:]
    /// Installed version of other host apps (REAPER, Waveform, Ardour, GarageBand, MainStage), by `Host`.
    private(set) var hostVersions: [Host: String] = [:]
    private(set) var liveDatabase = LiveDatabase()

    init(directories: SearchDirectories = .standard, logicVersion: String? = InstalledPluginIndex.detectLogicVersion(),
         abletonVersion: String? = InstalledPluginIndex.detectAbletonVersion(),
         logicPluginNames: [String]? = nil, abletonDeviceNames: [String: String]? = nil) {
        self.logicPluginNames = logicPluginNames ?? Self.detectLogicPluginNames()
        self.abletonDeviceNames = abletonDeviceNames ?? Self.detectAbletonDeviceNames()
        self.logicVersion = logicVersion
        self.abletonVersion = abletonVersion
        for h in Host.allCases where h != .logic && h != .ableton { if let v = Self.detectAppVersion(h) { hostVersions[h] = v } }
        self.liveDatabase = LiveDatabase(directory: directories.liveDatabase)
        for dir in directories.audioUnits {
            for bundle in Self.bundles(in: dir, ext: "component") {
                components.append(contentsOf: Self.components(in: bundle))
            }
        }
        for dir in directories.applications {
            for appex in Self.appExtensions(in: dir) { components.append(contentsOf: Self.components(in: appex)) }
        }
        for c in components { byKey[c.key, default: []].append(c) }
        for (dirs, format, ext) in [(directories.vst, PluginFormat.vst, "vst"), (directories.vst3, .vst3, "vst3"), (directories.clap, .clap, "clap"), (directories.aax, .aax, "aaxplugin")] {
            for dir in dirs {
                for bundle in Self.bundles(in: dir, ext: ext) {
                    let name = bundle.deletingPathExtension().lastPathComponent
                    vstNames[Self.normalize(name), default: [:]][format] = Self.bundleVersion(bundle) ?? "?"
                }
            }
        }
    }

    func exact(type: String, subtype: String, manufacturer: String) -> [InstalledComponent] {
        byKey["\(type)/\(subtype)/\(manufacturer)"] ?? []
    }

    /// Components from the same manufacturer code whose plugin name starts with `prefix` (case-insensitive).
    func byNamePrefix(_ prefix: String, manufacturer: String) -> [InstalledComponent] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        return components.filter { $0.manufacturer == manufacturer && $0.pluginName.lowercased().hasPrefix(p) }
    }

    /// VST/VST3 builds with the same bundle name, with the version read from each bundle's Info.plist ("?" if absent).
    /// A VST/VST3 bundle whose file name matches `name` (case/punctuation-insensitive), with its Info.plist version.
    func bundle(format: PluginFormat, named name: String) -> (name: String, version: String)? {
        guard let v = vstNames[Self.normalize(name)]?[format] else { return nil }
        return (name, v == "?" ? "" : v)
    }

    /// The only bundle of this format whose file name contains `name` ("Pro-Q 4" in "FabFilter Pro-Q 4"); nil if none or several.
    func bundle(format: PluginFormat, nameContaining name: String) -> (name: String, version: String)? {
        let want = Self.normalize(name)
        guard want.count >= 4 else { return nil }
        let hits = vstNames.filter { $0.key.contains(want) && $0.value[format] != nil }
        guard hits.count == 1, let h = hits.first, let v = h.value[format] else { return nil }
        return (h.key, v == "?" ? "" : v)
    }

    func otherFormats(forPluginNamed name: String) -> [(format: PluginFormat, version: String)] {
        let found = vstNames[Self.normalize(name)] ?? [:]
        return [PluginFormat.vst, .vst3, .clap, .aax].compactMap { f in found[f].map { (f, $0) } }
    }

    static func bundleVersion(_ bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return [plist["CFBundleShortVersionString"], plist["CFBundleVersion"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    // MARK: Helpers

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Installed version of a host app: by bundle identifier, then by app name prefix in /Applications.
    static func detectAppVersion(_ host: Host) -> String? {
        var urls = host.bundleIdentifiers.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        if urls.isEmpty, let apps = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil) {
            urls = apps.filter { app in app.pathExtension == "app" && host.appNamePrefixes.contains { app.lastPathComponent.hasPrefix($0) } }
        }
        for url in urls {
            if let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
               let r = v.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) { return String(v[r]) }
        }
        return nil
    }

    // MARK: Names of a host's own plugins, read from the installed host app (never hard-coded)

    static func appURL(bundleIDs: [String], namePrefix: String) -> URL? {
        for id in bundleIDs { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u } }
        let apps = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        return apps.first { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix(namePrefix) }
    }

    /// Logic keeps one folder per plugin under `Library.bundle/Plug-In Settings`; the folder names are the plugins' full names.
    static func detectLogicPluginNames() -> [String] {
        guard let app = appURL(bundleIDs: ["com.apple.logic10", "com.apple.mobilelogic"], namePrefix: "Logic Pro") else { return [] }
        let dir = app.appendingPathComponent("Contents/Resources/Library.bundle/Plug-In Settings")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.lastPathComponent).sorted()
    }

    /// Logic stores built-in plugin names truncated and abbreviated ("Space D", "St-Delay", "SmpleDly"). Matches them to the full names found in the installed
    /// Logic: exact, then a unique prefix, then the shortest name containing the stored letters in order (same first letter). Anything else stays as stored.
    func logicDisplayName(forStored stored: String) -> String {
        let want = Self.normalize(stored)
        guard !want.isEmpty, !logicPluginNames.isEmpty else { return stored }
        let table = logicPluginNames.map { ($0, Self.normalize($0)) }
        if let exact = table.first(where: { $0.1 == want }) { return exact.0 }
        let prefix = table.filter { $0.1.hasPrefix(want) }
        func isSubsequence(_ small: String, of big: String) -> Bool {
            var it = big.makeIterator()
            for c in small { var found = false; while let n = it.next() { if n == c { found = true; break } }; if !found { return false } }
            return true
        }
        let abbreviations = table.filter { $0.1.first == want.first && isSubsequence(want, of: $0.1) }
        // A prefix match is trusted only if no other plugin could be what the abbreviation stands for ("Spread" could be "Spreader" or "Stereo Spread").
        if !prefix.isEmpty {
            if Set(prefix.map(\.0)) == Set(abbreviations.map(\.0)) || abbreviations.isEmpty, let best = prefix.min(by: { $0.1.count < $1.1.count }), prefix.filter({ $0.1.count == best.1.count }).count == 1 { return best.0 }
            return stored
        }
        if let best = abbreviations.min(by: { $0.1.count < $1.1.count }), abbreviations.filter({ $0.1.count == best.1.count }).count == 1 { return best.0 }
        return stored
    }

    /// Live's library has one folder per device, named as the device is shown ("Core Library/Devices/Audio Effects/EQ Eight/"), and every preset inside starts with the
    /// device's element name as it appears in project files ("Eq8"). Reading one preset per folder gives the mapping, so it follows whatever Live version is installed.
    static func detectAbletonDeviceNames() -> [String: String] {
        guard let app = appURL(bundleIDs: ["com.ableton.live"], namePrefix: "Ableton Live") else { return [:] }
        let library = app.appendingPathComponent("Contents/App-Resources/Core Library")
        let fm = FileManager.default
        var map: [String: String] = [:]
        func rootElement(of url: URL) -> String? {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let xml = try? AbletonSetParser.gunzip(data) else { return nil }
            let head = String(decoding: xml.prefix(1024), as: UTF8.self)
            guard let r = head.range(of: #"<Ableton[^>]*>\s*<(\w+)"#, options: .regularExpression), let e = head[r].range(of: #"<(\w+)$"#, options: .regularExpression) else { return nil }
            return String(head[r][e].dropFirst())
        }
        for category in ["Audio Effects", "Instruments", "MIDI Effects"] {
            let dir = library.appendingPathComponent("Devices/\(category)")
            for device in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                guard (try? device.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, device.lastPathComponent != "Legacy", !device.lastPathComponent.hasPrefix("Ableton") else { continue }
                guard let en = fm.enumerator(at: device, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in en where url.pathExtension == "adv" {
                    if let el = rootElement(of: url) { map[el] = map[el] ?? device.lastPathComponent; break }
                }
            }
        }
        // Devices whose default preset is named after the device but that have no folder of presets.
        if let en = fm.enumerator(at: library.appendingPathComponent("Defaults"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension == "adv" {
                if let el = rootElement(of: url), map[el] == nil, url.deletingLastPathComponent().lastPathComponent != "Dropping Samples" { map[el] = url.deletingPathExtension().lastPathComponent }
            }
        }
        return map
    }

    /// The name Live shows for a device element; a readable form of the element name when Live isn't installed.
    func abletonDisplayName(forElement element: String) -> String {
        if let n = abletonDeviceNames[element] { return n }
        return Self.humanize(element)
    }

    /// "OriginalSimpler" -> "Original Simpler", "8bandEq" -> "8 band Eq", "Compressor2" -> "Compressor".
    static func humanize(_ identifier: String) -> String {
        var out = "", prev: Character = " "
        for c in identifier {
            if (c.isUppercase && (prev.isLowercase || prev.isNumber)) || (c.isLetter && prev.isNumber) { out.append(" ") }
            out.append(c); prev = c
        }
        var trimmed = out
        while let l = trimmed.last, l.isNumber || l == " " { trimmed.removeLast() }   // trailing instance/version digits ("Compressor2")
        let result = trimmed.isEmpty ? out : trimmed
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    /// Version of an installed app whose name starts with `namePrefix` ("Bitwig Studio" -> Bitwig Studio.app).
    func appVersion(namePrefix: String) -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        for url in apps where url.pathExtension == "app" && url.lastPathComponent.lowercased().hasPrefix(namePrefix.lowercased()) {
            if let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String, let d = HostDocument.dotted(in: v) { return d }
        }
        return nil
    }

    func installedVersion(of host: Host) -> String? {
        switch host { case .logic: return logicVersion; case .ableton: return abletonVersion; default: return hostVersions[host] }
    }

    static func detectAbletonVersion() -> String? {
        var urls = ["com.ableton.live"].compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        if urls.isEmpty, let apps = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil) {
            urls = apps.filter { $0.lastPathComponent.hasPrefix("Ableton Live") && $0.pathExtension == "app" }
        }
        for url in urls {
            let info = Bundle(url: url)?.infoDictionary
            if let v = info?["CFBundleShortVersionString"] as? String, let r = v.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) { return String(v[r]) }
        }
        return nil
    }

    /// Logic's bundle identifier differs between releases (Logic Pro 10/11: com.apple.logic10,
    /// Logic Pro Creator Studio 12: com.apple.mobilelogic), so try both, then any "Logic Pro*.app" in /Applications.
    static func detectLogicVersion() -> String? {
        var urls = ["com.apple.logic10", "com.apple.mobilelogic"].compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        if urls.isEmpty, let apps = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil) {
            urls = apps.filter { $0.lastPathComponent.hasPrefix("Logic Pro") && $0.pathExtension == "app" }
        }
        for url in urls {
            if let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
        }
        return nil
    }

    /// Bundles up to two levels deep (vendor sub-folders are common for VST/VST3).
    static func bundles(in dir: URL, ext: String) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.pathExtension.lowercased() == ext {
                out.append(url)
            } else if en.level >= 2 {
                en.skipDescendants()
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Audio Unit v3 plugins ship as app extensions inside host apps, one level below the apps folder.
    static func appExtensions(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return apps.filter { $0.pathExtension == "app" }.flatMap { app -> [URL] in
            let plugins = app.appendingPathComponent("Contents/PlugIns")
            return ((try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "appex" }
        }
    }

    static func components(in bundle: URL) -> [InstalledComponent] {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return [] }
        // Audio Units: top-level AudioComponents. AUv3 extensions: NSExtension > NSExtensionAttributes > AudioComponents.
        let attrs = (plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        let declared = plist["AudioComponents"] as? [[String: Any]] ?? attrs?["AudioComponents"] as? [[String: Any]] ?? []
        let short = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
        let build = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
        let version = [short, build].compactMap { $0 }.first { !$0.isEmpty }
        return declared.compactMap { d in
            guard let type = code(d["type"]), let sub = code(d["subtype"]), let man = code(d["manufacturer"]) else { return nil }
            let full = (d["name"] as? String) ?? bundle.deletingPathExtension().lastPathComponent
            let parts = full.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let (mName, pName) = parts.count == 2 ? (parts[0], parts[1]) : ("", full)
            return InstalledComponent(type: type, subtype: sub, manufacturer: man, fullName: full,
                                      manufacturerName: mName, pluginName: pName, version: version, bundleURL: bundle,
                                      componentVersion: d["version"] as? Int)
        }
    }

    /// Info.plist codes are normally 4-character strings but can be written as integers.
    static func code(_ value: Any?) -> String? {
        if let s = value as? String, s.utf8.count == 4 { return s }
        if let n = value as? Int {
            let u = UInt32(truncatingIfNeeded: n)
            let bytes = [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }
}
