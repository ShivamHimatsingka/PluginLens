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
            liveDatabase: LiveDatabase.standardDirectory)
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
    private(set) var liveDatabase = LiveDatabase()

    init(directories: SearchDirectories = .standard, logicVersion: String? = InstalledPluginIndex.detectLogicVersion(),
         abletonVersion: String? = InstalledPluginIndex.detectAbletonVersion()) {
        self.logicVersion = logicVersion
        self.abletonVersion = abletonVersion
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
        for (dirs, format, ext) in [(directories.vst, PluginFormat.vst, "vst"), (directories.vst3, .vst3, "vst3")] {
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

    func otherFormats(forPluginNamed name: String) -> [(format: PluginFormat, version: String)] {
        let found = vstNames[Self.normalize(name)] ?? [:]
        return [PluginFormat.vst, .vst3].compactMap { f in found[f].map { (f, $0) } }
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
