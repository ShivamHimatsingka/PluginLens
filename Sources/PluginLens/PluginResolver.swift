import Foundation

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
            applySavedVersion(&e, saved: r.saved, storedName: r.name)
        }
        return e
    }

    /// Fills in `savedVersion` and `versionCheck` from the best evidence available: the AU state version, a convention or generic
    /// field from the plugin state, and finally the product generation in the plugin's name.
    static func applySavedVersion(_ e: inout PluginEntry, saved: [SavedVersion], storedName: String) {
        let installed = e.isUncertain ? nil : e.installedVersion
        if let best = saved.map(\.confidence).min() {
            let group = saved.filter { $0.confidence == best }
            e.savedConfidence = best
            e.savedVersionSource = group.first?.source
            e.savedVersion = group.map(\.version).joined(separator: ", ")
            if e.status == .notInstalled { e.versionCheck = .notInstalled; return }
            switch best {
            case .exact:
                let saved = group.compactMap(\.componentValue).max()
                if let saved, !e.isUncertain, let now = e.installedComponentVersion {
                    e.versionCheck = saved == now ? .same : (saved < now ? .installedNewer : .installedOlder)
                } else { e.versionCheck = .cannotCompare }
            case .heuristic:
                // A field we could not tie to a known convention (it may describe a preset or a dependency): show it, never judge it.
                e.savedVersion = group.map(\.version).joined(separator: ", ") + " (unverified)"
                e.versionCheck = .unverified
            default:
                e.versionCheck = compare(saved: group.map(\.version), installed: installed)
            }
            return
        }
        // Nothing stored in the state: fall back to the generation in the plugin's name ("Ozone 12").
        let stored = storedName
        guard let gen = SavedVersionExtractor.generation(inName: stored) else {
            e.versionCheck = e.status == .notInstalled ? .notInstalled : .notStored
            return
        }
        e.savedVersion = "\(gen) (from name)"
        e.savedVersionSource = "The plugin's name in the project (\"\(stored)\"), which includes its product generation."
        e.savedConfidence = .generation
        if e.status == .notInstalled { e.versionCheck = .notInstalled; return }
        guard !e.isUncertain, let product = e.installedProductName else { e.versionCheck = .cannotCompare; return }
        if let now = SavedVersionExtractor.generation(inName: product) {
            e.versionCheck = now == gen ? .sameGeneration : .differs
        } else { e.versionCheck = .cannotCompare }
    }

    /// Compares the version(s) saved in the project with the installed one. With several saved versions (instances saved by
    /// different plugin versions) the newest is compared, and any disagreement is reported.
    static func compare(saved: [String], installed: String?) -> VersionCheck {
        guard let installed else { return .cannotCompare }
        var worst: VersionCheck = .same
        for v in saved {
            // A saved version with fewer parts ("12.4") that is a prefix of the installed one ("12.4.6") is the same release line.
            let sp = v.split(separator: ".").count
            if sp <= 2, installed.split(separator: " ").first.map({ $0.hasPrefix(v + ".") }) == true { continue }
            switch SavedVersionExtractor.compare(v, installed) {
            case .orderedSame: continue
            case .orderedAscending: worst = .installedNewer
            case .orderedDescending: return .installedOlder
            case nil: if v != installed { worst = .differs }
            }
        }
        return worst
    }

    static func resolveBuiltIn(_ r: RawPluginRecord, index: InstalledPluginIndex) -> PluginEntry {
        let version = index.logicVersion.map { "\($0) (Logic Pro)" }
        return PluginEntry(id: r.key, name: index.logicDisplayName(forStored: r.name), manufacturer: "Apple",
                           format: .builtIn, installedVersion: version,
                           status: version == nil ? .versionUnknown : .installed,
                           isUncertain: false,
                           note: version == nil ? "Logic Pro is not installed, so its built-in plugin version can't be read."
                                                : "Built-in plugins are versioned with Logic Pro itself.",
                           otherFormats: [], codes: "", bundlePath: nil)
    }

    static func resolveAudioUnit(_ r: RawPluginRecord, index: InstalledPluginIndex) -> PluginEntry {
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
                           codes: r.codes, bundlePath: first.bundleURL.path,
                           installedComponentVersion: first.componentVersion, installedProductName: first.pluginName)
    }
}
