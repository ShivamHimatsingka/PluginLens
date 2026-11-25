import Foundation

// MARK: - Errors

/// Per-project failures. These are shown in the detail pane and never abort a scan.
enum ProjectError: Error, LocalizedError, Hashable, Sendable {
    case noProjectData
    case unreadable(String)
    case unsupportedFormat(String)
    case corrupt(String)
    case legacyFormat
    case notSupportedYet(daw: String, hint: String)

    var errorDescription: String? {
        switch self {
        case .noProjectData:
            return "No ProjectData file was found in this package (looked in Alternatives/*/ProjectData). The project may never have been saved: Logic leaves an empty package with only undo data for untitled sessions."
        case .unreadable(let why):
            return "The project could not be read: \(why)"
        case .unsupportedFormat(let why):
            return "Unsupported project format: \(why)"
        case .corrupt(let why):
            return "The project file looks corrupt or incomplete: \(why)"
        case .legacyFormat:
            return "This is a legacy Logic (.logic) project. Only .logicx packages are supported."
        case .notSupportedYet(let daw, let hint):
            return "\(daw) projects can't be read yet. \(hint)"
        }
    }
}

// MARK: - Hosts

/// A DAW whose projects can be read.
enum Host: String, CaseIterable, Sendable {
    case logic, ableton, reaper, waveform, ardour, garageBand, mainStage, flStudio, proTools, dawproject, lmms
    var displayName: String {
        switch self {
        case .logic: return "Logic Pro"; case .ableton: return "Ableton Live"; case .reaper: return "REAPER"
        case .waveform: return "Waveform"; case .ardour: return "Ardour"; case .garageBand: return "GarageBand"; case .mainStage: return "MainStage"
        case .flStudio: return "FL Studio"; case .proTools: return "Pro Tools"; case .dawproject: return "DAWproject"; case .lmms: return "LMMS"
        }
    }
    var bundleIdentifiers: [String] {
        switch self {
        case .reaper: return ["com.cockos.reaper"]
        case .waveform: return ["com.tracktion.waveform", "com.tracktion.Waveform"]
        case .ardour: return ["org.ardour.Ardour"]
        case .garageBand: return ["com.apple.garageband10"]
        case .mainStage: return ["com.apple.mainstage3"]
        case .flStudio: return ["com.image-line.flstudio"]
        case .proTools: return ["com.avid.ProTools"]
        default: return []
        }
    }
    var appNamePrefixes: [String] {
        switch self {
        case .reaper: return ["REAPER"]; case .waveform: return ["Waveform"]; case .ardour: return ["Ardour"]
        case .garageBand: return ["GarageBand"]; case .mainStage: return ["MainStage"]; case .flStudio: return ["FL Studio"]; case .proTools: return ["Pro Tools"]; case .lmms: return ["LMMS"]; default: return []
        }
    }
}

// MARK: - Discovered projects

struct DiscoveredProject: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case logicx, legacy, abletonSet, reaper, waveform, ardour, flStudio, proToolsText, dawproject, lmms, unsupported(daw: String, hint: String) }
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
    /// Plugin version(s) found in the plugin's saved state, if the plugin stores one.
    var saved: [SavedVersion] = []

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
    case abletonBuiltIn = "Ableton built-in"
    case maxForLive = "Max for Live"
    case clap = "CLAP"
    case lv2 = "LV2"
    case jsfx = "JSFX"
    case reaperBuiltIn = "REAPER built-in"
    case waveformBuiltIn = "Waveform built-in"
    case ardourBuiltIn = "Ardour built-in"
    case aax = "AAX"
    case dawBuiltIn = "Built-in"
    case ladspa = "LADSPA"
    case flBuiltIn = "FL Studio built-in"
    case proToolsBuiltIn = "Pro Tools built-in"
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

/// How the version the project was saved with relates to what is installed now.
enum VersionCheck: String, Hashable, Sendable {
    case same = "Same"
    case sameGeneration = "Same major"
    case installedNewer = "Installed is newer"
    case installedOlder = "Installed is older"
    case differs = "Different"
    case unverified = "Unverified"
    case cannotCompare = "Can't compare"
    case notStored = "Not stored"
    case notInstalled = "Not installed"

    var needsAttention: Bool { self == .installedNewer || self == .installedOlder || self == .differs }
    var sortRank: Int { switch self { case .installedOlder: return 0; case .installedNewer: return 1; case .differs: return 2; case .cannotCompare: return 3; case .unverified: return 3; case .same: return 4; case .sameGeneration: return 4; case .notInstalled: return 5; case .notStored: return 6 } }
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
    /// Version the project was saved with, if the plugin wrote one into its state (or Logic's own version for built-ins).
    var savedVersion: String? = nil
    var savedVersionSource: String? = nil
    /// How trustworthy `savedVersion` is.
    var savedConfidence: SavedVersion.Confidence? = nil
    /// The matched component's declared AU version (`AudioComponents` > `version`), used to compare exact AU state versions.
    var installedComponentVersion: Int? = nil
    /// The matched component's product name, used to compare the product generation in names ("Ozone 12").
    var installedProductName: String? = nil
    var versionCheck: VersionCheck = .notStored

    var savedVersionText: String { savedVersion ?? "—" }
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
