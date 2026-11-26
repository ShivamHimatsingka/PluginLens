import XCTest
@testable import PluginLens

final class AbletonTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PLAbl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func int(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }

    // "VSTZ" "BDZO" "zone" " Pro" as 4 big-endian words: class ID 5653545a-4244-5a4f-7a6f-6e652050726f
    private var ozoneUID: [Int] { ["VSTZ", "BDZO", "zone", " Pro"].map(int) }
    private let ozoneID = "device:vst3:audiofx:5653545a-4244-5a4f-7a6f-6e652050726f"

    private func index(db rows: [(String, String, String, String)] = [], fake: FakeInstall? = nil, live: String? = "12.4.6", names: [String: String] = [:]) throws -> InstalledPluginIndex {
        let dbDir = tmp.appendingPathComponent("db")
        if !rows.isEmpty { try AbletonSetBuilder.database(in: dbDir, rows: rows) }
        var dirs = fake?.directories ?? SearchDirectories(audioUnits: [], vst: [], vst3: [])
        dirs.liveDatabase = rows.isEmpty ? nil : dbDir
        return InstalledPluginIndex(directories: dirs, logicVersion: nil, abletonVersion: live, logicPluginNames: [], abletonDeviceNames: names)
    }

    private func load(_ xml: String, index: InstalledPluginIndex, name: String = "Song.als") throws -> LoadState {
        let url = tmp.appendingPathComponent(name)
        try AbletonSetBuilder.gzip(xml).write(to: url)
        return ProjectLoader.load(DiscoveredProject(url: url, kind: .abletonSet), index: index)
    }

    // MARK: Parsing

    func testParsesGzipSetAndBuiltInDevices() throws {
        let xml = AbletonSetBuilder.set(devices: "<Compressor2 Id=\"1\"><On Value=\"true\"/></Compressor2><Eq8 Id=\"2\"/><Compressor2 Id=\"3\"/>")
        let set = try AbletonSetParser.parse(AbletonSetBuilder.gzip(xml))
        XCTAssertEqual(set.creator, "Ableton Live 12.1"); XCTAssertEqual(set.liveVersion, "12.1"); XCTAssertEqual(set.majorVersion, "5")
        XCTAssertEqual(set.devices.map(\.name), ["Compressor2", "Eq8"], "duplicates merge")
        XCTAssertEqual(set.devices.first?.count, 2)
    }

    func testRackContainersAreNotListedButTheirDevicesAre() throws {
        let xml = AbletonSetBuilder.set(devices: "<AudioEffectGroupDevice Id=\"1\"><Branches><AudioEffectBranch><DeviceChain><AudioToAudioDeviceChain><Devices><Limiter Id=\"2\"/></Devices></AudioToAudioDeviceChain></DeviceChain></AudioEffectBranch></Branches></AudioEffectGroupDevice>")
        XCTAssertEqual(try AbletonSetParser.parse(AbletonSetBuilder.gzip(xml)).devices.map(\.name), ["Limiter"])
    }

    func testPlainXMLIsAcceptedAndGarbageIsRejected() throws {
        XCTAssertEqual(try AbletonSetParser.parse(Data(AbletonSetBuilder.set(devices: "<Eq8/>").utf8)).devices.count, 1)
        XCTAssertThrowsError(try AbletonSetParser.parse(Data(repeating: 0x41, count: 200)))
        XCTAssertThrowsError(try AbletonSetParser.parse(Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + [UInt8](repeating: 7, count: 40)))) { guard case ProjectError.corrupt = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try AbletonSetParser.parse(AbletonSetBuilder.gzip("<?xml version=\"1.0\"?><Something/>")))
        XCTAssertThrowsError(try AbletonSetParser.parse(Data()))
    }

    func testTruncatedGzipDoesNotCrash() throws {
        let full = try AbletonSetBuilder.gzip(AbletonSetBuilder.set(devices: "<Eq8/>"))
        for n in [20, 40, full.count / 2, full.count - 9] { _ = try? AbletonSetParser.parse(full.prefix(n)) }
    }

    func testHexStateBuffersAreDecoded() throws {
        let state = Data("pluginVersion=\"2.0.5\"".utf8)
        let xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.vst3(name: "ValhallaRoom", uid: [1, 2, 3, 4], state: state))
        let d = try XCTUnwrap(AbletonSetParser.parse(AbletonSetBuilder.gzip(xml)).devices.first)
        XCTAssertEqual(d.kind, .vst3); XCTAssertEqual(d.name, "Ozone 12 Dynamics".isEmpty ? "" : "ValhallaRoom")
        XCTAssertEqual(d.states, [state])
        XCTAssertEqual(d.fields["Fields.2"], "3")
    }

    // MARK: Matching VST3 through Live's database

    func testVST3IsMatchedByClassIDAndTakesTheDatabaseVersion() throws {
        let idx = try index(db: [(ozoneID, "Ozone 12 Dynamics", "iZotope", "12.0.1"), ("device:vst3:audiofx:00000000-0000-0000-0000-000000000000", "Other", "X", "9")])
        let xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.vst3(name: "Ozone 12 Dynamics", uid: ozoneUID))
        guard case .loaded(let r) = try load(xml, index: idx) else { return XCTFail() }
        let e = try XCTUnwrap(r.plugins.first)
        XCTAssertEqual(e.manufacturer, "iZotope"); XCTAssertEqual(e.installedVersion, "12.0.1"); XCTAssertEqual(e.status, .installed)
        XCTAssertEqual(e.format, .vst3); XCTAssertFalse(e.isUncertain)
        XCTAssertEqual(e.savedVersion, "12 (from name)"); XCTAssertEqual(e.versionCheck, .sameGeneration)
    }

    func testVST3ClassIDWorksInEitherByteOrder() throws {
        let le: [Int] = ozoneUID.map { Int(UInt32($0).byteSwapped) }
        let d = AbletonDevice(kind: .vst3, name: "x", fields: Dictionary(uniqueKeysWithValues: le.enumerated().map { ("Fields.\($0)", String($1)) }))
        XCTAssertTrue(d.vst3ClassIDs.contains("5653545a-4244-5a4f-7a6f-6e652050726f"))
        let signed = AbletonDevice(kind: .vst3, name: "x", fields: Dictionary(uniqueKeysWithValues: ozoneUID.map { Int(Int32(truncatingIfNeeded: $0)) }.enumerated().map { ("Fields.\($0)", String($1)) }))
        XCTAssertTrue(signed.vst3ClassIDs.contains("5653545a-4244-5a4f-7a6f-6e652050726f"), "Live writes signed 32-bit values")
    }

    func testUnknownClassIDFallsBackToUniqueNameThenToNotInstalled() throws {
        let idx = try index(db: [(ozoneID, "Ozone 12 Dynamics", "iZotope", "12.0.1")])
        var xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.vst3(name: "Ozone 12 Dynamics", uid: [9, 9, 9, 9]))
        guard case .loaded(let r1) = try load(xml, index: idx) else { return XCTFail() }
        XCTAssertTrue(r1.plugins[0].isUncertain, "name-only match is never certain"); XCTAssertEqual(r1.plugins[0].status, .versionUnknown)
        xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.vst3(name: "Gone Plugin", uid: [9, 9, 9, 9]))
        guard case .loaded(let r2) = try load(xml, index: idx) else { return XCTFail() }
        XCTAssertEqual(r2.plugins[0].status, .notInstalled)
    }

    func testWithoutLiveDatabaseVST3FallsBackToBundleName() throws {
        let fake = try FakeInstall()
        try fake.addPlain("Cool Verb", ext: "vst3", in: fake.vst3)
        let idx = try index(fake: fake)
        let xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.vst3(name: "Cool Verb", uid: [1, 2, 3, 4]))
        guard case .loaded(let r) = try load(xml, index: idx) else { return XCTFail() }
        XCTAssertEqual(r.plugins[0].installedVersion, "1.0"); XCTAssertTrue(r.plugins[0].isUncertain)
    }

    // MARK: Matching AU through the state plist

    func testAUIsMatchedByCodesFoundInItsStatePlistAndSavedVersionIsRead() throws {
        let state = try PropertyListSerialization.data(fromPropertyList: [
            "type": int("aufx"), "subtype": int("Ruum"), "manufacturer": int("oDin"), "version": 0,
            "jucePluginState": Data(#"<ValhallaRoom pluginVersion="2.0.5"/>"#.utf8)] as [String: Any], format: .xml, options: 0)
        let fake = try FakeInstall()
        try fake.addComponent("ValhallaRoom", short: "2.1.0", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        let xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.au(name: "ValhallaRoom", manufacturer: "Valhalla DSP, LLC", state: state))
        guard case .loaded(let r) = try load(xml, index: try index(fake: fake)) else { return XCTFail() }
        let e = try XCTUnwrap(r.plugins.first)
        XCTAssertEqual(e.format, .au); XCTAssertEqual(e.installedVersion, "2.1.0"); XCTAssertEqual(e.savedVersion, "2.0.5")
        XCTAssertEqual(e.versionCheck, .installedNewer); XCTAssertFalse(e.isUncertain)
    }

    func testAUWithoutAnyCodesIsMatchedByNameButUncertain() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Thing", short: "3.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        let xml = AbletonSetBuilder.set(devices: AbletonSetBuilder.au(name: "Thing", manufacturer: "Acme", state: nil))
        guard case .loaded(let r) = try load(xml, index: try index(fake: fake)) else { return XCTFail() }
        XCTAssertTrue(r.plugins[0].isUncertain); XCTAssertEqual(r.plugins[0].status, .versionUnknown)
    }

    // MARK: Built-ins, saved with, errors

    func testBuiltInDevicesUseTheLiveVersion() throws {
        let xml = AbletonSetBuilder.set(creator: "Ableton Live 12.1", devices: "<Eq8/><Compressor2/>")
        guard case .loaded(let r) = try load(xml, index: try index(live: "12.4.6", names: ["Eq8": "EQ Eight", "Compressor2": "Compressor"])) else { return XCTFail() }
        XCTAssertEqual(r.plugins.map(\.name), ["EQ Eight", "Compressor"]); XCTAssertEqual(r.plugins[0].format, .abletonBuiltIn)
        XCTAssertEqual(r.plugins[0].savedVersion, "12.1 (Live)"); XCTAssertEqual(r.plugins[0].installedVersion, "12.4.6 (Live)")
        XCTAssertEqual(r.plugins[0].versionCheck, .installedNewer)
        guard case .loaded(let same) = try load(AbletonSetBuilder.set(creator: "Ableton Live 12.4", devices: "<Eq8/>"), index: try index(live: "12.4.6")) else { return XCTFail() }
        XCTAssertEqual(same.plugins[0].versionCheck, .same, "12.4 and 12.4.6 are the same release line")
        guard case .loaded(let none) = try load(xml, index: try index(live: nil)) else { return XCTFail() }
        XCTAssertEqual(none.plugins[0].status, .versionUnknown)
    }

    func testBuiltInNamesComeFromTheInstalledLiveOrAreMadeReadable() throws {
        let withLive = try index(names: ["Eq8": "EQ Eight"])
        XCTAssertEqual(withLive.abletonDisplayName(forElement: "Eq8"), "EQ Eight")
        XCTAssertEqual(withLive.abletonDisplayName(forElement: "SomeNewDevice"), "Some New Device", "a device Live doesn't know yet still reads well")
        XCTAssertEqual(try index().abletonDisplayName(forElement: "OriginalSimpler"), "Original Simpler")
        XCTAssertEqual(InstalledPluginIndex.humanize("Compressor2"), "Compressor"); XCTAssertEqual(InstalledPluginIndex.humanize("8bandEq"), "8 band Eq")
    }

    func testRacksAreRecognisedFromTheirStructureNotTheirName() throws {
        let xml = AbletonSetBuilder.set(devices: "<BrandNewRackKind Id=\"1\"><Branches><Branch><DeviceChain><Devices><Limiter Id=\"2\"/><AnotherRack><Branches><Branch><DeviceChain><Devices><Gate Id=\"3\"/></Devices></DeviceChain></Branch></Branches></AnotherRack></Devices></DeviceChain></Branch></Branches></BrandNewRackKind>")
        XCTAssertEqual(try AbletonSetParser.parse(AbletonSetBuilder.gzip(xml)).devices.map(\.name), ["Limiter", "Gate"])
    }

    func testNewerSchemaWarnsAndBadSetFailsAlone() throws {
        guard case .loaded(let r) = try load(AbletonSetBuilder.set(major: "6", devices: "<Eq8/>"), index: try index()) else { return XCTFail() }
        XCTAssertTrue(r.warnings.contains { $0.contains("schema 6") })
        let bad = tmp.appendingPathComponent("Bad.als"); try Data(repeating: 1, count: 100).write(to: bad)
        guard case .failed = ProjectLoader.load(DiscoveredProject(url: bad, kind: .abletonSet), index: try index()) else { return XCTFail() }
    }

    // MARK: Discovery and database

    func testScannerFindsSetsAndSkipsBackupFolders() throws {
        let proj = tmp.appendingPathComponent("My Song Project"); let backup = proj.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let data = try AbletonSetBuilder.gzip(AbletonSetBuilder.set(devices: "<Eq8/>"))
        try data.write(to: proj.appendingPathComponent("My Song.als")); try data.write(to: backup.appendingPathComponent("My Song [2026-01-01].als"))
        let found = ProjectScanner.discover(at: tmp)
        XCTAssertEqual(found.map(\.name), ["My Song"]); XCTAssertEqual(found.first?.kind, .abletonSet)
        XCTAssertEqual(ProjectScanner.discover(at: proj.appendingPathComponent("My Song.als")).count, 1)
    }

    func testLiveDatabasePicksNewestFileAndReadsRows() throws {
        let dir = tmp.appendingPathComponent("dbs")
        try AbletonSetBuilder.database(in: dir, number: 1, rows: [("device:vst3:audiofx:aaaaaaaa-0000-0000-0000-000000000000", "Old", "V", "1")])
        try AbletonSetBuilder.database(in: dir, number: 12, rows: [("device:vst3:audiofx:bbbbbbbb-0000-0000-0000-000000000000", "New", "V", "2.0")])
        let db = LiveDatabase(directory: dir)
        XCTAssertEqual(db.records.map(\.name), ["New"]); XCTAssertEqual(db.record(classIDs: ["BBBBBBBB-0000-0000-0000-000000000000"])?.version, "2.0")
        XCTAssertTrue(LiveDatabase(directory: tmp.appendingPathComponent("missing")).records.isEmpty)
    }
}
