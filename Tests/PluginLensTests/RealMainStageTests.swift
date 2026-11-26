import XCTest
@testable import PluginLens

/// Runs on the concerts MainStage ships with (skipped when MainStage isn't installed).
final class RealMainStageTests: XCTestCase {
    private func concerts() throws -> [URL] {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications"))?.filter { $0.hasPrefix("MainStage") } ?? []
        let dirs = apps.map { URL(fileURLWithPath: "/Applications/\($0)/Contents/Resources/MainStage Concerts") }
        let all = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "concert" }
        if all.isEmpty { throw XCTSkip("MainStage's bundled concerts are not installed") }
        return all
    }

    func testEveryBundledConcertLoadsWithPlugins() throws {
        let index = InstalledPluginIndex()
        var summary = ""
        for url in try concerts() {
            let p = try XCTUnwrap(ProjectScanner.discover(at: url).first, url.lastPathComponent)
            guard case .loaded(let r) = ProjectLoader.load(p, index: index) else { XCTFail("did not load \(url.lastPathComponent)"); continue }
            XCTAssertFalse(r.plugins.isEmpty, url.lastPathComponent)
            summary += "\(url.lastPathComponent): \(r.plugins.count) plugins, \(r.plugins.filter { $0.format == .builtIn }.count) built-in, e.g. \(r.plugins.prefix(4).map { "\($0.name)[\($0.format.rawValue)]" })\n"
        }
        print(summary)
    }

    func testGuitarAmpConcertHasItsChannelStripPlugins() throws {
        let url = try XCTUnwrap(try concerts().first { $0.lastPathComponent == "Guitar Amp.concert" })
        let p = try XCTUnwrap(ProjectScanner.discover(at: url).first)
        guard case .loaded(let r) = ProjectLoader.load(p, index: InstalledPluginIndex()) else { return XCTFail("did not load") }
        let names = Set(r.plugins.map(\.name))
        for expected in ["Gate", "Channel EQ", "Compressor", "Amp Designer"] { XCTAssertTrue(names.contains(expected), "missing \(expected) in \(names)") }
    }
}
