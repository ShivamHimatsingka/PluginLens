import Foundation

// MARK: - Errors

/// Per-project failures. These are shown in the detail pane and never abort a scan.
enum ProjectError: Error, LocalizedError, Hashable, Sendable {
    case noProjectData
    case unreadable(String)
    case unsupportedFormat(String)
    case corrupt(String)
    case legacyFormat

    var errorDescription: String? {
        switch self {
        case .noProjectData:
            return "No ProjectData file was found in this package (looked in Alternatives/*/ProjectData)."
        case .unreadable(let why):
            return "The project could not be read: \(why)"
        case .unsupportedFormat(let why):
            return "Unsupported project format: \(why)"
        case .corrupt(let why):
            return "The project file looks corrupt or incomplete: \(why)"
        case .legacyFormat:
            return "This is a legacy Logic (.logic) project. Only .logicx packages are supported."
        }
    }
}

// MARK: - Discovered projects

struct DiscoveredProject: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case logicx, legacy }
    var url: URL
    var kind: Kind
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - Parser output

/// A plugin record exactly as found in ProjectData, de-duplicated within one project.
struct RawPluginRecord: Hashable, Sendable {
    enum Kind: String, Sendable { case audioUnit, builtIn }
    var kind: Kind
    /// Name as stored: Logic truncates it to 11 characters.
    var name: String
    /// AU manufacturer code, or "GAME" for Logic built-ins.
    var manufacturer: String
    var type: String
    var subtype: String
    /// How many records with the same identity were found.
    var count: Int
    var firstOffset: Int

    var key: String {
        kind == .audioUnit ? "au:\(type)/\(subtype)/\(manufacturer)" : "builtin:\(name)"
    }
    var codes: String { kind == .audioUnit ? "\(type)/\(subtype)/\(manufacturer)" : "" }
}

struct ParseResult: Sendable {
    var records: [RawPluginRecord]
    var warnings: [String]
}

// MARK: - Resolved plugin rows

enum PluginFormat: String, Hashable, Sendable {
    case au = "AU"
    case vst = "VST"
    case vst3 = "VST3"
    case builtIn = "Logic built-in"
}

enum PluginStatus: String, Hashable, Sendable {
    case installed = "Installed"
    case notInstalled = "Not installed"
    case versionUnknown = "Version unknown"

    var sortRank: Int {
        switch self {
        case .notInstalled: return 0
        case .versionUnknown: return 1
        case .installed: return 2
        }
    }
}

struct PluginEntry: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
    var format: PluginFormat
    var installedVersion: String?
    var status: PluginStatus
    /// True when the bundle was matched without an exact AU code match, or several bundles disagree.
    var isUncertain: Bool
    var note: String?
    /// VST/VST3 builds of the same plugin that are also installed (informational only).
    var otherFormats: [PluginFormat]
    var codes: String
    var bundlePath: String?

    var versionText: String {
        guard let v = installedVersion else { return "—" }
        return isUncertain ? "\(v) (uncertain)" : v
    }
    var formatText: String {
        otherFormats.isEmpty ? format.rawValue : "\(format.rawValue) (+\(otherFormats.map(\.rawValue).joined(separator: ", ")) installed)"
    }
    var statusText: String { isUncertain && status != .notInstalled ? "\(status.rawValue) (uncertain)" : status.rawValue }
    var needsAttention: Bool { status != .installed }
}

struct ProjectReport: Sendable {
    var project: DiscoveredProject
    var projectDataURL: URL?
    var lastModified: Date?
    var lastSavedFrom: String?
    var plugins: [PluginEntry]
    var warnings: [String]
}

enum LoadState: Sendable {
    case pending
    case loading
    case loaded(ProjectReport)
    case failed(ProjectError)
}
