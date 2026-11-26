import XCTest
@testable import PluginLens

final class ProToolsSessionTests: XCTestCase {
    // MARK: A synthetic session in the layout of a real one (scrambled with the same table the format uses)

    private func str(_ s: String) -> [UInt8] { u32(s.utf8.count) + Array(s.utf8) }
    private func u32(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)] }
    private func block(_ type: Int, _ ct: Int, _ content: [UInt8], children: [[UInt8]] = []) -> [UInt8] {
        let inner = content + children.flatMap { $0 }
        return [0x5A, UInt8(type & 255), UInt8(type >> 8)] + u32(inner.count + 2) + [UInt8(ct & 255), UInt8(ct >> 8)] + inner
    }
    private func plugin(_ name: String, ids: [String], effect: String) -> [UInt8] {
        block(6, 0x1017, [3] + str(name) + ids.flatMap { Array($0.utf8.reversed()) } + [2, 1, 2, 1, 100, 0, 1] + str(effect) + [1, 1])
    }
    private func session(type: UInt8 = 5, key: UInt8 = 0x86, plugins: [(String, [String], String)], product: Bool = true) -> Data {
        var body: [UInt8] = []
        if product {
            body += block(4, 0x0003, [3] + str("Pro Tools Ultimate") + [3, 0, 0, 0] + str("2019.12.0") + [1] + str("Release") + str("Pro Tools Session File"))
        }
        body += block(2, 0x1018, [], children: plugins.map { plugin($0.0, ids: $0.1, effect: $0.2) })
        body += [UInt8](repeating: 0, count: 20_000)               // enough bytes that several scrambling pages are used
        var file: [UInt8] = [0x03] + Array("0010111100101011".utf8) + [0, type, key] + body
        let delta = ProToolsSessionParser.unscrambleDelta(key: key, type: type)
        let table = (0..<256).map { UInt8(truncatingIfNeeded: $0 * Int(delta)) }
        for i in 0x14..<file.count { file[i] ^= table[type == 1 ? (i & 255) : ((i >> 12) & 255)] }
        return Data(file)
    }

    func testPluginListAndSavingVersionAreRead() throws {
        let doc = try ProToolsSessionParser.parse(session(plugins: [("Reason Rack Plugin", ["REAS", "RRPL", "RRP2"], "com.reasonstudios.reasonrackplugin.stereo"), ("Pro-Q 4", ["FabF", "PQ4a", "PQ4b"], "com.fabfilter.proq4")]))
        XCTAssertEqual(doc.savedWith, "Pro Tools Ultimate 2019.12.0"); XCTAssertEqual(doc.savedVersion, "2019.12.0")
        XCTAssertEqual(doc.plugins.map(\.name), ["Reason Rack Plugin", "Pro-Q 4"]); XCTAssertEqual(doc.plugins[0].ids, "REAS:RRPL:RRP2"); XCTAssertEqual(doc.plugins[0].format, .aax)
    }

    func testBothScramblingTypesWork() throws {
        for type: UInt8 in [1, 5] {
            let doc = try ProToolsSessionParser.parse(session(type: type, key: 0x42, plugins: [("Xx", ["ACME", "XXXX", "YYYY"], "id")]))
            XCTAssertEqual(doc.plugins.map(\.name), ["Xx"], "type \(type)")
        }
    }

    func testPluginsFromTheHostsOwnManufacturerAreBuiltIn() throws {
        let doc = try ProToolsSessionParser.parse(session(plugins: [("EQ III 7-Band", ["Digi", "EQ7B", "EQ7M"], "com.avid.eq3"), ("Other", ["ACME", "OTHR", "OTHR"], "x")]))
        XCTAssertTrue(doc.plugins[0].isHostBuiltIn); XCTAssertEqual(doc.plugins[0].format, .proToolsBuiltIn); XCTAssertFalse(doc.plugins[1].isHostBuiltIn)
    }

    func testResolvesAgainstInstalledAAXPlugins() throws {
        let fake = try FakeInstall(); try fake.addPlain("Reason Rack Plugin", ext: "aaxplugin", in: fake.aax)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PT-\(UUID().uuidString).ptx")
        try session(plugins: [("Reason Rack Plugin", ["REAS", "RRPL", "RRP2"], "e"), ("Gone Verb", ["ACME", "GONE", "GONE"], "e")]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ProjectScanner.discover(at: url).first?.kind, .proToolsSession)
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: url, kind: .proToolsSession), index: fake.index()) else { return XCTFail() }
        XCTAssertEqual(r.plugins.map(\.status), [.versionUnknown, .notInstalled], "matched by name only, so not certain"); XCTAssertTrue(r.plugins[0].isUncertain); XCTAssertEqual(r.plugins[0].installedVersion, "1.0"); XCTAssertEqual(r.plugins[0].codes, "REAS:RRPL:RRP2")
        XCTAssertEqual(r.lastSavedFrom, "Pro Tools Ultimate 2019.12.0")
    }

    func testRejectsOtherFilesWrongKeysAndDamage() throws {
        XCTAssertThrowsError(try ProToolsSessionParser.parse(Data(repeating: 0x41, count: 200)))
        XCTAssertThrowsError(try ProToolsSessionParser.parse(Data([0x03] + [UInt8](repeating: 0, count: 100))), "unknown scrambling type")
        let good = session(plugins: [("Xx", ["ACME", "XXXX", "YYYY"], "id")])
        for cut in stride(from: 0x40, to: good.count, by: 997) { _ = try? ProToolsSessionParser.parse(good.prefix(cut)) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 { var d = good.prefix(0x14); d.append(contentsOf: (0..<2000).map { _ in UInt8.random(in: 0...255, using: &rng) }); _ = try? ProToolsSessionParser.parse(d) }
    }
}
