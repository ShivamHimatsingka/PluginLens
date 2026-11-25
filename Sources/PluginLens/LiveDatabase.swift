import Foundation
import SQLite3

/// Ableton Live keeps a database of the plugins it has scanned (`Live-plugins-N.db`), including each plugin's vendor and
/// version string. When Live is installed on this Mac it is the most accurate answer to "which version of this VST3 do I have".
struct LiveDatabase: Sendable {
    struct Record: Hashable, Sendable {
        var identifier: String   // "device:vst3:audiofx:5653545a-4244-5a4f-7a6f-6e652050726f"
        var name: String
        var vendor: String
        var version: String
        /// The 16-byte class ID as lower-case dashed hex, for VST3 entries.
        var classID: String? { identifier.hasPrefix("device:vst3:") ? identifier.split(separator: ":").last.map(String.init) : nil }
    }

    private(set) var records: [Record] = []
    private var byClass: [String: Record] = [:]
    private var byName: [String: [Record]] = [:]

    static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ableton/Live Database")
    }

    init(directory: URL? = nil) {
        guard let directory, let file = Self.newestDatabase(in: directory) else { return }
        var db: OpaquePointer?
        // immutable=1: never take locks or write, even if Live is running.
        let uri = "file:\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path)?immutable=1&mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT dev_identifier, name, vendor, version FROM plugins", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(Record(identifier: text(0), name: text(1), vendor: text(2), version: text(3)))
        }
        for r in records {
            if let c = r.classID { byClass[c.lowercased()] = r }
            byName[InstalledPluginIndex.normalize(r.name), default: []].append(r)
        }
    }

    func record(classIDs: [String]) -> Record? { classIDs.lazy.compactMap { byClass[$0.lowercased()] }.first }
    func records(named name: String) -> [Record] { byName[InstalledPluginIndex.normalize(name)] ?? [] }

    /// `Live-plugins-<n>.db` with the highest n.
    static func newestDatabase(in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Live-plugins-") && $0.pathExtension == "db" }
            .max { (Int($0.deletingPathExtension().lastPathComponent.dropFirst(13)) ?? 0) < (Int($1.deletingPathExtension().lastPathComponent.dropFirst(13)) ?? 0) }
    }
}
