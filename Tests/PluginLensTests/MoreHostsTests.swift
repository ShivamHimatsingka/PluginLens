import XCTest
@testable import PluginLens

final class MoreHostsTests: XCTestCase {
    // MARK: FL Studio builder

    private func varint(_ n: Int) -> [UInt8] {
        var out: [UInt8] = [], v = n
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
        return out
    }
    private func utf16(_ s: String) -> [UInt8] { (s + "\0").utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] } }
    private func text(_ id: UInt8, _ s: String, ascii: Bool = false) -> [UInt8] {
        let bytes = ascii ? Array((s + "\0").utf8) : utf16(s)
        return [id] + varint(bytes.count) + bytes
    }
    private func blob(_ id: UInt8, _ bytes: [UInt8]) -> [UInt8] { [id] + varint(bytes.count) + bytes }
    private func flp(_ events: [[UInt8]]) -> Data {
        let body = events.flatMap { $0 }
        var d = Data("FLhd".utf8)
        d.append(contentsOf: [6, 0, 0, 0, 0, 0, 1, 0, 96, 0]); d.append(Data("FLdt".utf8))
        d.append(contentsOf: [UInt8(body.count & 255), UInt8(body.count >> 8 & 255), UInt8(body.count >> 16 & 255), UInt8(body.count >> 24 & 255)])
        d.append(contentsOf: body); return d
    }
    private func wrapperState(path: String, extra: String = "") -> [UInt8] {
        [1, 2, 3, 4, 0, 0] + utf16(path) + Array(extra.utf8)
    }
    private var project: Data {
        flp([
            [0x9C, 0xE0, 0x22, 0x02, 0x00],                       // a 4-byte event (tempo-like), to exercise sizing
            [0x40, 0x01, 0x00],                                    // 2-byte event
            text(199, "21.2.3.4004"),
            [0x40, 0x00, 0x00], text(201, "Sytrus"),
            [0x40, 0x01, 0x00], text(201, "Fruity Wrapper"), text(203, "FabFilter Pro-Q 4"),
            blob(213, wrapperState(path: "/Library/Audio/Plug-Ins/VST3/FabFilter Pro-Q 4.vst3", extra: #"<X pluginVersion="1.2.3"/>"#)),
            [0x40, 0x02, 0x00], text(201, "Sampler"),
            [0x40, 0x03, 0x00], text(201, "Fruity Wrapper"), text(203, "Mystery Synth"), blob(213, [1, 2, 3]),
            [0x40, 0x04, 0x00], text(201, "Fruity Wrapper"), text(203, "ValhallaRoom"),
            blob(213, [0] + Array("/Library/Audio/Plug-Ins/Components/ValhallaRoomAU64.component".utf8) + [0]),
        ])
    }

    // MARK: FL Studio tests

    func testFLStudioParsesVersionAndPlugins() throws {
        let doc = try FLStudioParser.parse(project)
        XCTAssertEqual(doc.savedVersion, "21.2.3.4004"); XCTAssertEqual(doc.savedWith, "FL Studio 21.2.3.4004")
        XCTAssertEqual(doc.plugins.map(\.name), ["Sytrus", "FabFilter Pro-Q 4", "Mystery Synth", "ValhallaRoom"], "samplers are not plugins")
        XCTAssertEqual(doc.plugins[0].format, .flBuiltIn)
        XCTAssertEqual(doc.plugins[1].format, .vst3); XCTAssertEqual(doc.plugins[1].fileName, "FabFilter Pro-Q 4.vst3")
        XCTAssertTrue(doc.plugins[2].formatGuess, "no path in the wrapper state: format unknown")
        XCTAssertEqual(doc.plugins[3].format, .au); XCTAssertEqual(doc.plugins[3].fileName, "ValhallaRoomAU64.component")
    }

    func testFLStudioAsciiTextAndLongEventsAreHandled() throws {
        let long = [UInt8](repeating: 7, count: 300)     // needs a two-byte size
        let doc = try FLStudioParser.parse(flp([text(199, "11.0.1", ascii: true), blob(210, long), text(201, "Fruity Limiter", ascii: true)]))
        XCTAssertEqual(doc.savedVersion, "11.0.1"); XCTAssertEqual(doc.plugins.map(\.name), ["Fruity Limiter"])
    }

    func testFLStudioRealMinimalFileParsesWithoutPlugins() throws {
        let doc = try FLStudioParser.parse(Fixtures.file("minimal", "flp"))
        XCTAssertTrue(doc.plugins.isEmpty); XCTAssertNil(doc.savedVersion)
    }

    func testFLStudioMalformedInput() throws {
        XCTAssertThrowsError(try FLStudioParser.parse(Data("not an flp file at all, definitely".utf8)))
        XCTAssertThrowsError(try FLStudioParser.parse(Data("FLhd".utf8)))
        let full = project
        for cut in stride(from: 22, to: full.count, by: 11) { _ = try? FLStudioParser.parse(full.prefix(cut)) }       // truncations never crash
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 { var d = full.prefix(22); d.append(contentsOf: (0..<500).map { _ in UInt8.random(in: 0...255, using: &rng) }); _ = try? FLStudioParser.parse(d) }
        let doc = try FLStudioParser.parse(full.prefix(full.count - 3))
        XCTAssertFalse(doc.warnings.isEmpty, "a cut-off file is reported")
    }

    func testFLStudioResolvesAgainstInstalledPlugins() throws {
        let fake = try FakeInstall()
        try fake.addPlain("FabFilter Pro-Q 4", ext: "vst3", in: fake.vst3)
        try fake.addComponent("ValhallaRoomAU64", short: "2.0.5", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FL-\(UUID().uuidString).flp")
        try project.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: url, kind: .flStudio), index: fake.index()) else { return XCTFail() }
        let by = Dictionary(uniqueKeysWithValues: r.plugins.map { ($0.name, $0) })
        XCTAssertEqual(by["FabFilter Pro-Q 4"]?.installedVersion, "1.0"); XCTAssertEqual(by["FabFilter Pro-Q 4"]?.savedVersion, "1.2.3")
        XCTAssertEqual(by["FabFilter Pro-Q 4"]?.versionCheck, .installedOlder)
        XCTAssertEqual(by["Valhalla DSP, LLC: ValhallaRoom"]?.status ?? by["ValhallaRoom"]?.status, .installed)
        XCTAssertEqual(by["Mystery Synth"]?.status, .notInstalled)
        XCTAssertEqual(by["Sytrus"]?.format, .flBuiltIn); XCTAssertEqual(r.lastSavedFrom, "FL Studio 21.2.3.4004")
    }

    // MARK: Pro Tools text export

    private let ptText = """
    SESSION NAME:\tdemo
    SAMPLE RATE:\t48000.000000


    P L U G - I N S  L I S T I N G
    MANUFACTURER \tPLUG-IN NAME \tVERSION \tFORMAT \tSTEMS \tNUMBER OF PLUG-INS
    Avid \tEQ III \t1.0 \tAAX Native \tMono \t2
    FabFilter \tPro-Q 4 \t4.01 \tAAX Native \tStereo \t3
    Nobody \tGhost Verb \t2.2 \tAAX Native \tStereo \t1

    T R A C K  L I S T I N G
    TRACK NAME:\tGtr
    PLUG-INS: \tEQ III (mono)\tPro-Q 4 (stereo)\tGhost Verb (stereo)\t
    CHANNEL \tEVENT
    """

    func testProToolsListingGivesManufacturerAndSavedVersion() throws {
        let doc = try ProToolsTextParser.parse(Data(ptText.utf8))
        XCTAssertEqual(doc.plugins.map(\.name), ["EQ III", "Pro-Q 4", "Ghost Verb"], "track-line duplicates are folded into the listing")
        XCTAssertEqual(doc.plugins[1].vendor, "FabFilter"); XCTAssertEqual(doc.plugins[1].knownSaved.first?.version, "4.01")
        XCTAssertEqual(doc.plugins[0].format, .proToolsBuiltIn)
        XCTAssertTrue(doc.warnings.isEmpty)
    }

    func testProToolsResolvesAAXBundlesAndComparesVersions() throws {
        let fake = try FakeInstall()
        try fake.addPlain("FabFilter Pro-Q 4", ext: "aaxplugin", in: fake.aax)    // Info.plist version "1.0"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PT-\(UUID().uuidString).txt")
        try Data(ptText.utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ProjectScanner.isProToolsExport(url))
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: url, kind: .proToolsText), index: fake.index()) else { return XCTFail() }
        let by = Dictionary(uniqueKeysWithValues: r.plugins.map { ($0.name, $0) })
        XCTAssertEqual(by["Pro-Q 4"]?.installedVersion, "1.0"); XCTAssertEqual(by["Pro-Q 4"]?.savedVersion, "4.01"); XCTAssertEqual(by["Pro-Q 4"]?.versionCheck, .installedOlder)
        XCTAssertEqual(by["Pro-Q 4"]?.isUncertain, false, "manufacturer + name matches the bundle file name")
        XCTAssertEqual(by["Ghost Verb"]?.status, .notInstalled)
        XCTAssertEqual(by["EQ III"]?.format, .proToolsBuiltIn); XCTAssertEqual(by["EQ III"]?.savedVersion, "1.0")
    }

    func testProToolsExportWithoutListingStillListsNamesWithAWarning() throws {
        let doc = try ProToolsTextParser.parse(try Fixtures.file("session_info", "txt"))
        XCTAssertEqual(doc.plugins.map(\.name), ["Foo"]); XCTAssertFalse(doc.warnings.isEmpty)
    }

    func testProToolsRejectsOtherText() {
        XCTAssertThrowsError(try ProToolsTextParser.parse(Data("hello, this is just some text file".utf8)))
        XCTAssertFalse(ProjectScanner.isProToolsExport(URL(fileURLWithPath: "/nonexistent.txt")))
    }

    // MARK: Unsupported DAWs

    func testUnsupportedProjectsAreListedWithAReason() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Uns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["a.cpr", "b.ptx", "c.npr", "d.txt"] { try Data("not a session".utf8).write(to: dir.appendingPathComponent(f)) }
        let found = ProjectScanner.discover(at: dir)
        XCTAssertEqual(found.map(\.name).sorted(), ["a", "b", "c"], "plain .txt files are not projects")
        for p in found {
            guard case .failed(let e) = ProjectLoader.load(p, index: FakeInstallIndex.empty), case .notSupportedYet(let daw, let hint) = e else { return XCTFail() }
            XCTAssertFalse(daw.isEmpty); XCTAssertFalse(hint.isEmpty)
        }
        XCTAssertTrue(found.first { $0.name == "b" }.map { if case .unsupported(let d, let h) = $0.kind { return d == "Pro Tools" && h.contains("Session Info as Text") } else { return false } } ?? false)
    }
}
