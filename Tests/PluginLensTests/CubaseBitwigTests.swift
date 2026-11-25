import XCTest
@testable import PluginLens

final class CubaseBitwigTests: XCTestCase {
    // MARK: Builders that follow the layouts seen in real Cubase 10.5 and Bitwig 5.3 projects

    private func u32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
    private func cubaseKey(_ k: String) -> [UInt8] { u32(k.utf8.count + 1) + Array(k.utf8) + [0] }
    private func cubaseString(_ key: String, _ v: String) -> [UInt8] {
        cubaseKey(key) + [0, 8] + u32(v.utf8.count + 1 + 3) + Array(v.utf8) + [0, 0xEF, 0xBB, 0xBF]
    }
    private func cubase(app: String = "Cubase", version: String = "10.5.20", plugins: [(guid: String, name: String)]) -> Data {
        var body: [UInt8] = Array("ROOT".utf8) + [0, 0, 0, 0x20] + cubaseKey("Version") + Array("PAppVersion".utf8) + [0, 0, 0, 0x52, 0, 0, 0, 7] + Array(app.utf8) + [0, 0, 0, 0, 0x10]
        body += Array("Version \(version)".utf8) + [0, 0, 0, 0, 0x0C] + Array("May  5 2020".utf8) + [0, 0, 0, 1, 0x90, 0, 0, 0, 6] + Array("WIN64".utf8) + [0]
        for p in plugins {
            body += cubaseKey("Plugin UID") + [0, 0, 2, 0, 6, 0, 0, 0, 1] + cubaseString("GUID", p.guid) + cubaseString("Plugin Name", p.name) + cubaseKey("Audio Input Count") + [0, 0, 1, 0, 0, 0, 0]
        }
        let payload = Array("NUND".utf8) + body
        return Data(Array("RIFF".utf8) + [UInt8(payload.count & 255), UInt8(payload.count >> 8 & 255), UInt8(payload.count >> 16 & 255), UInt8(payload.count >> 24 & 255)] + payload + [UInt8](repeating: 0, count: 32))
    }
    private func field(_ id: Int, _ text: String) -> [UInt8] { [0, 0, UInt8(id >> 8), UInt8(id & 255), 8] + u32(text.utf8.count) + Array(text.utf8) }

    private func vstpreset(classID: String, body: String) -> Data {
        var d = Data("VST3".utf8); d.append(contentsOf: [1, 0, 0, 0]); d.append(Data(classID.utf8))
        let comp = Data(body.utf8)
        var listOffset = UInt64(48 + comp.count)
        d.append(Data(bytes: &listOffset, count: 8)); d.append(comp)
        d.append(Data("List".utf8)); d.append(contentsOf: [1, 0, 0, 0]); d.append(Data("Comp".utf8))
        var off: UInt64 = 48, size = UInt64(comp.count)
        d.append(Data(bytes: &off, count: 8)); d.append(Data(bytes: &size, count: 8)); return d
    }

    private func bitwig(version: String = "5.3.13", plugins: [(classID: String, version: String, name: String)], withStates: Bool = true) throws -> Data {
        var b: [UInt8] = Array("BtWg00010002008f000016d7".utf8) + [0, 0, 0, 4] + u32(4) + Array("meta".utf8)
        b += Array("application_version_name".utf8) + [8, 0, 0, 0] + u32(version.utf8.count) + Array(version.utf8)
        for p in plugins {
            b += [0, 0, 0x27, 0x5C, 1, 0x30, 0, 0] + field(0x0CE4, p.classID) + field(0x0C5E, p.version) + [0, 0, 0, 0, 0, 0] + field(0x0199, p.name) + field(0x019A, "") + field(0x019B, "")
        }
        var out = Data(b)
        if withStates {
            let files = plugins.map { ("plugin-states/\(UUID().uuidString.lowercased()).vstpreset", vstpreset(classID: $0.classID, body: #"<X pluginVersion="9.9.9"/>"#)) }
            out.append(try RealFormatsTests().zip(files, deflate: true))
        }
        return out
    }

    // MARK: Cubase / Nuendo

    func testCubaseListsPluginsAndSavingVersion() throws {
        let doc = try CubaseParser.parse(cubase(plugins: [
            ("D56B9C6CA4F946018EED73EB83A74B58", "Input Filter"), ("1234567890ABCDEF1234567890ABCDEF", "Standard Panner"),
            ("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD", "Mystic"), ("11111111222222223333333344444444", "FabFilter Pro-Q 4"),
            ("11111111222222223333333344444444", "FabFilter Pro-Q 4"),
        ]))
        XCTAssertEqual(doc.host, .cubase); XCTAssertEqual(doc.savedWith, "Cubase 10.5.20"); XCTAssertEqual(doc.savedVersion, "10.5.20")
        XCTAssertEqual(doc.plugins.map(\.name), ["Mystic", "FabFilter Pro-Q 4"], "mixer plumbing is skipped and duplicates merge")
        XCTAssertTrue(doc.plugins[0].isHostBuiltIn); XCTAssertEqual(doc.plugins[0].vendor, "Steinberg")
        XCTAssertEqual(doc.plugins[1].format, .vst3); XCTAssertEqual(doc.plugins[1].classID, "11111111222222223333333344444444"); XCTAssertEqual(doc.plugins[1].count, 2)
    }

    func testNuendoIsRecognisedFromTheSavingApplication() throws {
        let doc = try CubaseParser.parse(cubase(app: "Nuendo", version: "12.0.40", plugins: []))
        XCTAssertEqual(doc.host, .nuendo); XCTAssertEqual(doc.savedWith, "Nuendo 12.0.40")
    }

    func testCubaseResolvesAgainstInstalledVST3() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CB-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Song.cpr"); try cubase(plugins: [("11111111222222223333333344444444", "Pro-Q 4"), ("55555555666666667777777788888888", "Gone Verb")]).write(to: url)
        let fake = try FakeInstall(); try fake.addPlain("FabFilter Pro-Q 4", ext: "vst3", in: fake.vst3)
        XCTAssertEqual(ProjectScanner.discover(at: dir).first?.kind, .cubase)
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: url, kind: .cubase), index: fake.index()) else { return XCTFail() }
        XCTAssertEqual(r.plugins.map(\.status), [.versionUnknown, .notInstalled]); XCTAssertEqual(r.plugins[0].installedVersion, "1.0"); XCTAssertTrue(r.plugins[0].isUncertain)
        XCTAssertEqual(r.lastSavedFrom, "Cubase 10.5.20")
    }

    func testCubaseRejectsOtherFilesAndSurvivesDamage() throws {
        XCTAssertThrowsError(try CubaseParser.parse(Data(repeating: 0x41, count: 200)))
        XCTAssertThrowsError(try CubaseParser.parse(Data("404: Not Found".utf8)))
        let full = cubase(plugins: [("11111111222222223333333344444444", "Pro-Q 4")])
        for cut in stride(from: 64, to: full.count, by: 17) { _ = try? CubaseParser.parse(full.prefix(cut)) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<30 { var d = full.prefix(40); d.append(contentsOf: (0..<600).map { _ in UInt8.random(in: 0...255, using: &rng) }); _ = try? CubaseParser.parse(d) }
    }

    func testDotCprThatIsNotRIFFIsListedAsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CP-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not riff at all".utf8).write(to: dir.appendingPathComponent("x.cpr"))
        guard case .unsupported = ProjectScanner.discover(at: dir).first?.kind else { return XCTFail() }
    }

    // MARK: Bitwig

    func testBitwigVST3RecordGivesNameClassIDVersionAndState() throws {
        let doc = try BitwigParser.parse(try bitwig(plugins: [("D39D5B69D6AF42FA1234567863625379", "1.3.0", "Space Piano")]))
        XCTAssertEqual(doc.savedWith, "Bitwig Studio 5.3.13")
        let p = try XCTUnwrap(doc.plugins.first)
        XCTAssertEqual(p.name, "Space Piano"); XCTAssertEqual(p.format, .vst3); XCTAssertEqual(p.classID, "D39D5B69D6AF42FA1234567863625379")
        XCTAssertEqual(p.knownSaved.first?.version, "1.3.0"); XCTAssertEqual(p.states.count, 1, "the ZIP at the end of the file holds the plugin's saved state")
        XCTAssertEqual(SavedVersionExtractor.statePlistCandidates(p.states[0]).versions.first?.version, "9.9.9")
    }

    func testBitwigWithoutTrailingZipAndWithManyPlugins() throws {
        let doc = try BitwigParser.parse(try bitwig(plugins: [("11111111222222223333333344444444", "2.0.0", "A Synth"), ("55555555666666667777777788888888", "1.0.1", "B Verb"), ("11111111222222223333333344444444", "2.0.0", "A Synth")], withStates: false))
        XCTAssertEqual(doc.plugins.map(\.name), ["A Synth", "B Verb"]); XCTAssertEqual(doc.plugins[0].count, 2); XCTAssertTrue(doc.plugins[0].states.isEmpty)
    }

    func testBitwigResolvesAndComparesVersions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BW-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Song.bwproject"); try bitwig(plugins: [("11111111222222223333333344444444", "0.9.0", "Cool Verb")]).write(to: url)
        let fake = try FakeInstall(); try fake.addPlain("Cool Verb", ext: "vst3", in: fake.vst3)
        XCTAssertEqual(ProjectScanner.discover(at: dir).first?.kind, .bitwig)
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: url, kind: .bitwig), index: fake.index()) else { return XCTFail() }
        XCTAssertTrue(r.plugins[0].savedVersion?.contains("0.9.0") == true, "the record's version is reported (the fixture's state says 9.9.9, so both are shown)")
    }

    func testBitwigRejectsOtherFilesAndSurvivesDamage() throws {
        XCTAssertThrowsError(try BitwigParser.parse(Data(repeating: 0x41, count: 200)))
        let full = try bitwig(plugins: [("D39D5B69D6AF42FA1234567863625379", "1.3.0", "Space Piano")])
        for cut in stride(from: 64, to: full.count, by: 23) { _ = try? BitwigParser.parse(full.prefix(cut)) }
    }

    func testZipWithLeadingDataIsReadableAtItsOffsets() throws {
        let z = try RealFormatsTests().zip([("a.txt", Data("hello".utf8))], deflate: true)
        let prefixed = Data(repeating: 0x42, count: 1000) + z
        let archive = try ZipArchive(prefixed)
        XCTAssertEqual(archive.base, 1000); XCTAssertEqual(try archive.read("a.txt"), Data("hello".utf8))
    }
}
