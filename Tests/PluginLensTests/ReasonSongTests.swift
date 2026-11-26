import XCTest
@testable import PluginLens

final class ReasonSongTests: XCTestCase {
    private func be(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
    private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be(body.count) + body + (body.count % 2 == 1 ? [0] : []) }
    private func property(_ name: String, _ value: String) -> [UInt8] {
        let wwid: [UInt8] = [0xBC, 1, 0, 0, 0, 0, 0, 0, UInt8(name.utf8.count >> 8), UInt8(name.utf8.count & 255)] + Array(name.utf8)
        let body = be(value.utf8.count) + Array(value.utf8)
        return chunk("FORM", Array("WWWI".utf8) + chunk("WWID", wwid) + chunk("BODY", body))
    }
    private func song(_ props: [(String, String)]) -> Data {
        let cat = chunk("CAT ", Array("WWWI".utf8) + props.flatMap { property($0.0, $0.1) })
        let form = chunk("FORM", Array("X15S".utf8) + cat + chunk("BODY", [UInt8](repeating: 0x5A, count: 64)))
        var d = Array("X15_FILE".utf8) + be(0x40000) + [UInt8](repeating: 0, count: 0x34 - 12)
        d += [UInt8](repeating: 0xFE, count: 0x40000 + 0x34 - d.count - 0)
        return Data(d + form)
    }

    func testReadsVersionRefillsAndTempo() throws {
        let info = try XCTUnwrap(ReasonSongInfo.read(song([("PROGRAMVERSION", "12.7.4"), ("REFILLS", "Factory Sound Bank"), ("REFILLS", "Orkester"), ("SONGTEMPO", "128000")])))
        XCTAssertEqual(info.programVersion, "12.7.4"); XCTAssertEqual(info.refills, ["Factory Sound Bank", "Orkester"]); XCTAssertEqual(info.tempoBPM, 128)
    }

    func testRejectsOtherFilesAndTruncation() {
        XCTAssertNil(ReasonSongInfo.read(Data("not a song".utf8)))
        XCTAssertNil(ReasonSongInfo.read(Data(Array("X15_FILE".utf8) + [UInt8](repeating: 0xFE, count: 0x50000))), "no plain header, as in older songs")
        let good = song([("PROGRAMVERSION", "12.7.4")])
        for cut in stride(from: 0x40000, to: good.count, by: 7) { _ = ReasonSongInfo.read(good.prefix(cut)) }
    }

    func testLoaderAddsTheVersionToTheExplanation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString).reason")
        try song([("PROGRAMVERSION", "12.7.4"), ("REFILLS", "Factory Sound Bank")]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let p = try XCTUnwrap(ProjectScanner.discover(at: url).first)
        guard case .failed(.notSupportedYet(let daw, let hint)) = ProjectLoader.load(p, index: InstalledPluginIndex()) else { return XCTFail() }
        XCTAssertEqual(daw, "Reason"); XCTAssertTrue(hint.contains("saved with Reason 12.7.4") && hint.contains("Factory Sound Bank"), hint)
    }
}
