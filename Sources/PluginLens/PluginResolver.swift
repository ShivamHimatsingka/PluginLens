import Foundation

/// Display names for Logic's internal built-in short names. Only entries we are confident about;
/// anything else is shown as stored. (Logic stores built-in names truncated to 11 characters.)
enum BuiltInNames {
    static let table: [String: String] = [
        "St-Delay": "Stereo Delay",
        "SmpleDly": "Sample Delay",
        "Space D": "Space Designer",
    ]
    static func displayName(for stored: String) -> String { table[stored] ?? stored }
}

/// Matches parsed records to installed bundles.
///
/// Rules, in order:
/// 1. Exact match on AU type + subtype + manufacturer code. If several installed bundles claim the code and
///    their versions disagree, the result is "uncertain" and no version is reported.
/// 2. Fallback: same manufacturer code and exactly one component whose name starts with the (truncated) stored
///    name. Reported as "uncertain" - never as a confident match.
/// 3. Otherwise "Not installed".
enum PluginResolver {
    /// - Parameter projectLogicVersion: the Logic version that last saved the project; it is the "saved with" version of built-ins.
    static func resolve(_ r: RawPluginRecord, index: InstalledPluginIndex, projectLogicVersion: String? = nil) -> PluginEntry {
        var e: PluginEntry
        switch r.kind {
        case .builtIn:
            e = resolveBuiltIn(r, index: index)
            if let v = projectLogicVersion {
                e.savedVersion = "\(v) (Logic Pro)"
                e.savedVersionSource = "ProjectInformation.plist (LastSavedFrom)"
                e.versionCheck = compare(saved: [v], installed: index.logicVersion)
            }
        case .audioUnit:
            e = resolveAudioUnit(r, index: index)
            if r.saved.isEmpty {
                e.versionCheck = e.status == .notInstalled ? .notInstalled : .notStored
            } else {
                let versions = r.saved.map(\.version)
                e.savedVersion = versions.joined(separator: ", ")
                e.savedVersionSource = r.saved.map(\.source).first
                e.versionCheck = e.status == .notInstalled ? .notInstalled
                    : compare(saved: versions, installed: e.isUncertain ? nil : e.installedVersion)
            }
        }
        return e
    }

    /// Compares the version(s) saved in the project with the installed one. With several saved versions (instances saved by
    /// different plugin versions) the newest is compared, and any disagreement is reported.
    static func compare(saved: [String], installed: String?) -> VersionCheck {
        guard let installed else { return .cannotCompare }
        var worst: VersionCheck = .same
        for v in saved {
            switch SavedVersionExtractor.compare(v, installed) {
            case .orderedSame: continue
            case .orderedAscending: worst = .installedNewer
            case .orderedDescending: return .installedOlder
            case nil: if v != installed { worst = .differs }
            }
        }
        return worst
    }

    private static func resolveBuiltIn(_ r: RawPluginRecord, index: InstalledPluginIndex) -> PluginEntry {
        let version = index.logicVersion.map { "\($0) (Logic Pro)" }
        return PluginEntry(id: r.key, name: BuiltInNames.displayName(for: r.name), manufacturer: "Apple",
                           format: .builtIn, installedVersion: version,
                           status: version == nil ? .versionUnknown : .installed,
                           isUncertain: false,
                           note: version == nil ? "Logic Pro is not installed, so its built-in plugin version can't be read."
                                                : "Built-in plugins are versioned with Logic Pro itself.",
                           otherFormats: [], codes: "", bundlePath: nil)
    }

    private static func resolveAudioUnit(_ r: RawPluginRecord, index: InstalledPluginIndex) -> PluginEntry {
        let exact = index.exact(type: r.type, subtype: r.subtype, manufacturer: r.manufacturer)
        if !exact.isEmpty {
            return entry(r, matches: exact, uncertain: false, index: index, extraNote: nil)
        }
        let byName = index.byNamePrefix(r.name, manufacturer: r.manufacturer)
        let distinctBundles = Set(byName.map(\.bundleURL))
        if distinctBundles.count == 1 {
            return entry(r, matches: byName, uncertain: true, index: index,
                         extraNote: "No component with codes \(r.codes) is installed; matched by manufacturer code and name only.")
        }
        // Logic can't load VST/VST3, so a same-named VST build doesn't make the project's AU available.
        let others = index.otherFormats(forPluginNamed: r.name)
        var note = "No installed Audio Unit has codes \(r.codes). Name is truncated by Logic; manufacturer shown as its four-character code."
        if !others.isEmpty { note += " A VST build with a matching name exists but Logic cannot load it." }
        return PluginEntry(id: r.key, name: r.name, manufacturer: r.manufacturer, format: .au,
                           installedVersion: nil, status: .notInstalled, isUncertain: false,
                           note: note, otherFormats: [], codes: r.codes, bundlePath: nil)
    }

    private static func entry(_ r: RawPluginRecord, matches: [InstalledComponent], uncertain: Bool,
                              index: InstalledPluginIndex, extraNote: String?) -> PluginEntry {
        let first = matches[0]
        let versions = Set(matches.compactMap(\.version))
        let bundles = Set(matches.map(\.bundleURL))
        var isUncertain = uncertain
        var version: String? = versions.first
        var notes: [String] = []
        let others = index.otherFormats(forPluginNamed: first.bundleURL.deletingPathExtension().lastPathComponent)
        if !others.isEmpty { notes.append("Also installed: " + others.map { "\($0.format.rawValue) \($0.version)" }.joined(separator: ", ") + ".") }
        if let extraNote { notes.append(extraNote) }
        if bundles.count > 1 && versions.count > 1 {
            isUncertain = true
            version = nil
            let list = matches.map { "\($0.bundleURL.lastPathComponent) \($0.version ?? "?")" }.joined(separator: "; ")
            notes.append("Several installed bundles share these codes with different versions: \(list).")
        }
        if version == nil && !(bundles.count > 1 && versions.count > 1) {
            notes.append("The installed bundle's Info.plist has no version string.")
        }
        let status: PluginStatus = (version == nil || isUncertain) ? .versionUnknown : .installed
        return PluginEntry(id: r.key, name: first.pluginName, manufacturer: first.manufacturerName.isEmpty ? r.manufacturer : first.manufacturerName,
                           format: .au, installedVersion: version, status: status, isUncertain: isUncertain,
                           note: notes.isEmpty ? nil : notes.joined(separator: " "),
                           otherFormats: others.map(\.format),
                           codes: r.codes, bundlePath: first.bundleURL.path)
    }
}
