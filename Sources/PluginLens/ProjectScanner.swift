import Foundation

enum ProjectScanner {
    /// Finds Logic projects at or below `root`. A `.logicx` package is a leaf: its contents are never walked.
    /// Also recognises legacy `.logic` projects (listed, but reported as unsupported) and extracted project
    /// folders that contain `Alternatives/`. Checks for cancellation as it goes.
    static func discover(at root: URL, progress: @Sendable (Int) -> Void = { _ in }) -> [DiscoveredProject] {
        let fm = FileManager.default
        var results: [DiscoveredProject] = []

        if let leaf = classify(root) {
            return [leaf]
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        for case let url as URL in en {
            if Task.isCancelled { break }
            // Live keeps older autosaves in "Backup" folders; they are not separate projects.
            if url.lastPathComponent == "Backup", (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { en.skipDescendants(); continue }
            if let project = classify(url) {
                results.append(project)
                progress(results.count)
                en.skipDescendants()
            }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Projects of these DAWs are listed so you can see they were skipped, with the reason.
    static let unsupportedKinds: [String: (String, String)] = [
        "ptx": ("Pro Tools", "Pro Tools sessions are encrypted. In Pro Tools use File > Export > Session Info as Text, include the plug-in listing, and open the .txt it creates."),
        "ptf": ("Pro Tools", "Pro Tools sessions are encrypted. In Pro Tools use File > Export > Session Info as Text, include the plug-in listing, and open the .txt it creates."),
        "pts": ("Pro Tools", "Pro Tools sessions are encrypted. In Pro Tools use File > Export > Session Info as Text, include the plug-in listing, and open the .txt it creates."),
        "cpr": ("Cubase", "Its project format is proprietary and has not been reverse-engineered here. In Cubase, Project > Plug-in Information lists a project's plugins."),
        "npr": ("Nuendo", "Its project format is proprietary and has not been reverse-engineered here. In Nuendo, Project > Plug-in Information lists a project's plugins."),
        "bwproject": ("Bitwig Studio", "Its project format is proprietary and has not been reverse-engineered here."),
        "cwp": ("Cakewalk", "Its project format is proprietary and has not been reverse-engineered here."),
        "reason": ("Reason", "Its project format is proprietary and has not been reverse-engineered here."),
    ]

    /// Pro Tools "Export Session Info as Text" files start with `SESSION NAME:`.
    static func isProToolsExport(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 32) else { return false }
        return d.starts(with: Data("SESSION NAME:".utf8))
    }

    private static func classify(_ url: URL) -> DiscoveredProject? {
        let ext = url.pathExtension.lowercased()
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if ext == "logicx", isDir { return DiscoveredProject(url: url, kind: .logicx) }
        if ext == "logic" { return DiscoveredProject(url: url, kind: .legacy) }
        if ext == "als", !isDir { return DiscoveredProject(url: url, kind: .abletonSet) }
        if ext == "rpp", !isDir { return DiscoveredProject(url: url, kind: .reaper) }
        if ext == "tracktionedit", !isDir { return DiscoveredProject(url: url, kind: .waveform) }
        if ext == "ardour", !isDir { return DiscoveredProject(url: url, kind: .ardour) }
        if ext == "flp", !isDir { return DiscoveredProject(url: url, kind: .flStudio) }
        if ext == "txt", !isDir, isProToolsExport(url) { return DiscoveredProject(url: url, kind: .proToolsText) }
        if !isDir, let u = unsupportedKinds[ext] { return DiscoveredProject(url: url, kind: .unsupported(daw: u.0, hint: u.1)) }
        // GarageBand and MainStage are built on Logic's engine; their packages are read with the Logic parser (experimental).
        if (ext == "band" || ext == "concert"), isDir { return DiscoveredProject(url: url, kind: .logicx) }
        if isDir, FileManager.default.fileExists(atPath: url.appendingPathComponent("Alternatives").path),
           !locateProjectData(in: url).isEmpty {
            return DiscoveredProject(url: url, kind: .logicx)
        }
        return nil
    }

    /// All `ProjectData` files under `Alternatives/*/`, newest first.
    static func locateProjectData(in package: URL) -> [URL] {
        let fm = FileManager.default
        let alts = package.appendingPathComponent("Alternatives")
        let dirs = (try? fm.contentsOfDirectory(at: alts, includingPropertiesForKeys: nil)) ?? []
        var candidates = dirs.map { $0.appendingPathComponent("ProjectData") }
            .filter { fm.fileExists(atPath: $0.path) }
        if candidates.isEmpty {
            // GarageBand and MainStage packages: look for a file called projectdata (any case) up to three levels down.
            if let en = fm.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let u as URL in en {
                    if en.level > 3 { en.skipDescendants(); continue }
                    if u.lastPathComponent.lowercased() == "projectdata",
                       (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { candidates.append(u) }
                }
            }
        }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return candidates.sorted { mtime($0) > mtime($1) }
    }
}

/// Loads one project end to end. Never throws: every failure becomes a `LoadState.failed`.
enum ProjectLoader {
    /// Newest Logic major version this parser was validated against.
    static let testedMajorVersion = 12

    static func load(_ project: DiscoveredProject, index: InstalledPluginIndex) -> LoadState {
        if project.kind == .legacy { return .failed(.legacyFormat) }
        if project.kind == .abletonSet { return loadAbleton(project, index: index) }
        if case .unsupported(let daw, let hint) = project.kind { return .failed(.notSupportedYet(daw: daw, hint: hint)) }
        if let parse = hostParser(for: project.kind) { return loadHostFile(project, index: index, parse: parse) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: project.url.path) else { return .failed(.unreadable("the file no longer exists")) }

        let dataFiles = ProjectScanner.locateProjectData(in: project.url)
        guard let dataURL = dataFiles.first else { return .failed(.noProjectData) }

        var warnings: [String] = []
        let ext = project.url.pathExtension.lowercased()
        if ext == "band" || ext == "concert" {
            warnings.append("\(ext == "band" ? "GarageBand" : "MainStage") projects are read with the Logic Pro parser. This is experimental and has not been checked against real \(ext == "band" ? "GarageBand" : "MainStage") files.")
        }
        let info = readInfo(project.url)
        if let major = info.major, major > testedMajorVersion {
            warnings.append("Saved by a newer Logic Pro (\(info.savedFrom ?? "?")) than this app was tested with (\(testedMajorVersion).x). Results may be incomplete.")
        }
        if dataFiles.count > 1 {
            warnings.append("This project has \(dataFiles.count) alternatives; showing the most recently modified one.")
        }

        let data: Data
        do { data = try Data(contentsOf: dataURL, options: .mappedIfSafe) }
        catch { return .failed(.unreadable(error.localizedDescription)) }

        let parsed: ParseResult
        do { parsed = try ProjectDataParser.parse(data) }
        catch let e as ProjectError { return .failed(e) }
        catch { return .failed(.corrupt(error.localizedDescription)) }

        var logicVersion: String?
        if let saved = info.savedFrom, let r = saved.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) { logicVersion = String(saved[r]) }
        let plugins = parsed.records.map { PluginResolver.resolve($0, index: index, projectLogicVersion: logicVersion) }
        let modified = (try? dataURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return .loaded(ProjectReport(project: project, projectDataURL: dataURL, lastModified: modified,
                                     lastSavedFrom: info.savedFrom, plugins: plugins,
                                     warnings: warnings + parsed.warnings))
    }

    private static func hostParser(for kind: DiscoveredProject.Kind) -> ((Data) throws -> HostDocument)? {
        switch kind {
        case .reaper: return ReaperParser.parse
        case .waveform: return WaveformParser.parse
        case .ardour: return ArdourParser.parse
        case .flStudio: return FLStudioParser.parse
        case .proToolsText: return ProToolsTextParser.parse
        default: return nil
        }
    }

    /// Shared path for DAWs whose files are parsed to a `HostDocument` (REAPER, Waveform, Ardour).
    private static func loadHostFile(_ project: DiscoveredProject, index: InstalledPluginIndex, parse: (Data) throws -> HostDocument) -> LoadState {
        let data: Data
        do { data = try Data(contentsOf: project.url, options: .mappedIfSafe) }
        catch { return .failed(.unreadable(error.localizedDescription)) }
        let doc: HostDocument
        do { doc = try parse(data) }
        catch let e as ProjectError { return .failed(e) }
        catch { return .failed(.corrupt(error.localizedDescription)) }
        let modified = (try? project.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let plugins = doc.plugins.map { HostResolver.resolve($0, host: doc.host, savedHostVersion: doc.savedVersion, index: index) }
        return .loaded(ProjectReport(project: project, projectDataURL: project.url, lastModified: modified,
                                     lastSavedFrom: doc.savedWith, plugins: plugins, warnings: doc.warnings))
    }

    private static func loadAbleton(_ project: DiscoveredProject, index: InstalledPluginIndex) -> LoadState {
        let data: Data
        do { data = try Data(contentsOf: project.url, options: .mappedIfSafe) }
        catch { return .failed(.unreadable(error.localizedDescription)) }
        let set: AbletonSet
        do { set = try AbletonSetParser.parse(data) }
        catch let e as ProjectError { return .failed(e) }
        catch { return .failed(.corrupt(error.localizedDescription)) }
        var warnings: [String] = []
        if let m = set.majorVersion, m != "5" {
            warnings.append("This set uses file schema \(m); only schema 5 (Live 10-12) has been tested, so some devices may be missing.")
        }
        let modified = (try? project.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let plugins = set.devices.map { AbletonResolver.resolve($0, index: index, setLiveVersion: set.liveVersion) }
        return .loaded(ProjectReport(project: project, projectDataURL: project.url, lastModified: modified,
                                     lastSavedFrom: set.creator, plugins: plugins, warnings: warnings))
    }

    static func lastModified(of project: DiscoveredProject) -> Date? {
        if project.kind != .logicx { return (try? project.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        let url = ProjectScanner.locateProjectData(in: project.url).first ?? project.url
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func readInfo(_ package: URL) -> (savedFrom: String?, major: Int?) {
        let url = package.appendingPathComponent("Resources/ProjectInformation.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let saved = plist["LastSavedFrom"] as? String else { return (nil, nil) }
        // e.g. "Logic Pro Creator Studio 12.2 (6644)": first dotted number.
        var major: Int?
        if let r = saved.range(of: #"\d+(?=\.\d+)"#, options: .regularExpression) { major = Int(saved[r]) }
        return (saved, major)
    }
}
