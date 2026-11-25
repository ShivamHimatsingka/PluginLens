import Foundation
import AppKit

struct SearchDirectories: Sendable {
    var audioUnits: [URL]
    var vst: [URL]
    var vst3: [URL]

    static var standard: SearchDirectories {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func dirs(_ sub: String) -> [URL] {
            [home.appendingPathComponent("Library/Audio/Plug-ins/\(sub)"),
             URL(fileURLWithPath: "/Library/Audio/Plug-ins/\(sub)")]
        }
        return SearchDirectories(
            audioUnits: dirs("Components") + [URL(fileURLWithPath: "/System/Library/Components")],
            vst: dirs("VST"),
            vst3: dirs("VST3"))
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

    var key: String { "\(type)/\(subtype)/\(manufacturer)" }
}

/// A snapshot of what is installed. Built once per scan, then read-only.
struct InstalledPluginIndex: Sendable {
    private(set) var components: [InstalledComponent] = []
    private var byKey: [String: [InstalledComponent]] = [:]
    private var vstNames: [String: Set<PluginFormat>] = [:]
    var logicVersion: String?

    init(directories: SearchDirectories = .standard, logicVersion: String? = InstalledPluginIndex.detectLogicVersion()) {
        self.logicVersion = logicVersion
        for dir in directories.audioUnits {
            for bundle in Self.bundles(in: dir, ext: "component") {
                components.append(contentsOf: Self.components(in: bundle))
            }
        }
        for c in components { byKey[c.key, default: []].append(c) }
        for (dirs, format, ext) in [(directories.vst, PluginFormat.vst, "vst"), (directories.vst3, .vst3, "vst3")] {
            for dir in dirs {
                for bundle in Self.bundles(in: dir, ext: ext) {
                    let name = bundle.deletingPathExtension().lastPathComponent
                    vstNames[Self.normalize(name), default: []].insert(format)
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

    func otherFormats(forPluginNamed name: String) -> [PluginFormat] {
        let set = vstNames[Self.normalize(name)] ?? []
        return [.vst, .vst3].filter(set.contains)
    }

    // MARK: Helpers

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
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

    static func components(in bundle: URL) -> [InstalledComponent] {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return [] }
        let declared = plist["AudioComponents"] as? [[String: Any]] ?? []
        let short = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
        let build = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
        let version = [short, build].compactMap { $0 }.first { !$0.isEmpty }
        return declared.compactMap { d in
            guard let type = code(d["type"]), let sub = code(d["subtype"]), let man = code(d["manufacturer"]) else { return nil }
            let full = (d["name"] as? String) ?? bundle.deletingPathExtension().lastPathComponent
            let parts = full.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let (mName, pName) = parts.count == 2 ? (parts[0], parts[1]) : ("", full)
            return InstalledComponent(type: type, subtype: sub, manufacturer: man, fullName: full,
                                      manufacturerName: mName, pluginName: pName, version: version, bundleURL: bundle)
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
