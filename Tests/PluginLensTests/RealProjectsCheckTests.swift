import XCTest
@testable import PluginLens

/// Opt-in check against real projects on this machine. Skipped unless PLUGINLENS_PROJECTS is set:
///     PLUGINLENS_PROJECTS=~/Music/Logic xcodebuild ... test -only-testing:PluginLensTests/RealProjectsCheckTests
/// Asserts that no project crashes or fails unexpectedly, and prints a summary.
final class RealProjectsCheckTests: XCTestCase {
    func testScanAndLoadEveryRealProject() throws {
        let path = ProcessInfo.processInfo.environment["PLUGINLENS_PROJECTS"] ?? (try? String(contentsOfFile: "/tmp/pluginlens_projects_path", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = path.flatMap({ $0.isEmpty ? nil : $0 }) else { throw XCTSkip("set PLUGINLENS_PROJECTS to a folder of projects to run this check") }
        let projects = ProjectScanner.discover(at: URL(fileURLWithPath: (root as NSString).expandingTildeInPath))
        let index = InstalledPluginIndex()
        var savedAU = Set<String>(), checks: [String: Int] = [:], changed: [String] = [], unsaved = 0, loaded = 0, failed: [String] = [], plugins = 0, missing: [String] = [], unknown: [String] = [], uncertain = 0
        let start = Date()
        for p in projects {
            switch ProjectLoader.load(p, index: index) {
            case .loaded(let r):
                loaded += 1; plugins += r.plugins.count
                for e in r.plugins {
                    if e.status == .notInstalled { missing.append("\(p.name): \(e.name) [\(e.codes)]") }
                    if e.status == .versionUnknown { unknown.append("\(p.name): \(e.name) — \(e.note ?? "")") }
                    if e.isUncertain { uncertain += 1 }
                    if e.format == .au { savedAU.insert("\(e.name): saved=\(e.savedVersionText) installed=\(e.versionText) [\(e.versionCheck.rawValue)] via \(e.savedVersionSource ?? "-")") }
                    checks[e.versionCheck.rawValue, default: 0] += 1
                    if e.versionCheck.needsAttention && e.formatText != "Logic built-in" { changed.append("\(p.name): \(e.name) saved=\(e.savedVersionText) installed=\(e.versionText) [\(e.versionCheck.rawValue)]") }
                }
            case .failed(.noProjectData): unsaved += 1   // never-saved "Untitled" stubs hold only undo data
            case .failed(let e): failed.append("\(p.name): \(e.localizedDescription)")
            case .pending, .loading: XCTFail("loader returned a transient state")
            }
        }
        print("REALCHECK projects=\(projects.count) loaded=\(loaded) unsavedStubs=\(unsaved) failed=\(failed.count) plugins=\(plugins) missing=\(missing.count) unknown=\(unknown.count) uncertain=\(uncertain) seconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
        print("REALCHECK versionChecks=\(checks.sorted { $0.key < $1.key })")
        savedAU.sorted().forEach { print("REALCHECK AU \($0)") }
        Set(changed).sorted().forEach { print("REALCHECK CHANGED \($0)") }
        failed.forEach { print("REALCHECK FAILED \($0)") }
        missing.forEach { print("REALCHECK MISSING \($0)") }
        unknown.forEach { print("REALCHECK UNKNOWN \($0)") }
        XCTAssertFalse(projects.isEmpty)
        // Projects that are legitimately unreadable would be listed above; none are expected in a healthy library.
        XCTAssertEqual(failed.count, 0, failed.joined(separator: "\n"))
    }
}
