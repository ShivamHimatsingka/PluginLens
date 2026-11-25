import XCTest
@testable import PluginLens

final class SavedVersionTests: XCTestCase {
    /// An embedded AU state plist as Logic writes it: codes as integers plus the plugin's own state blobs.
    private func statePlist(type: String, subtype: String, manufacturer: String, blobs: [String: Data]) throws -> Data {
        func int(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }
        var d: [String: Any] = ["type": int(type), "subtype": int(subtype), "manufacturer": int(manufacturer),
                                "name": "Untitled", "version": 0, "element-name": "dict"]
        for (k, v) in blobs { d[k] = v }
        return try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    private func project(plugin: Data, plist: Data?) -> Data {
        var d = RecordBuilder.project([plugin])
        if let plist { d.append(plist); d.append(Data(count: 16)) }
        return d
    }

    // MARK: Extraction

    func testPluginVersionAttributeInJuceStateIsExtracted() throws {
        let state = Data("VC2!\u{1}\0\0\0<?xml version=\"1.0\"?> <ValhallaRoom pluginVersion=\"2.0.5\" presetName=\"Default\"/>".utf8)
        let plist = try statePlist(type: "aufx", subtype: "Ruum", manufacturer: "oDin", blobs: ["jucePluginState": state])
        let rec = RecordBuilder.au(name: "ValhallaRoom", manufacturer: "oDin", type: "aufx", subtype: "Ruum")
        let r = try ProjectDataParser.parse(project(plugin: rec, plist: plist)).records
        XCTAssertEqual(r.first?.saved, [SavedVersion(version: "2.0.5", source: "pluginVersion attribute")])
    }

    func testOtherConventions() {
        XCTAssertEqual(SavedVersionExtractor.find(in: Data(#"{"product":"Serum2","productVersion":"2.0.16","url":"x"}"#.utf8))?.version, "2.0.16")
        XCTAssertEqual(SavedVersionExtractor.find(in: Data("PlugVersion 3.4.3\nSAMPLER {".utf8))?.version, "3.4.3")
        XCTAssertEqual(SavedVersionExtractor.find(in: Data(#"<Hero Version="1.0.2" x="1"/>"#.utf8))?.version, "1.0.2")
    }

    func testDoesNotMistakeFormatVersionsForPluginVersions() {
        // XML declaration, chunk format versions, bare integers and unrelated words must not be read as versions.
        XCTAssertNil(SavedVersionExtractor.find(in: Data(#"<?xml version="1.0" encoding="UTF-8"?>"#.utf8)))
        XCTAssertNil(SavedVersionExtractor.find(in: Data(#"<ChunkForVersion ChunkVersion="10.0.0">"#.utf8)))
        XCTAssertNil(SavedVersionExtractor.find(in: Data(#"<Program Version="2" Format="x">"#.utf8)))
        XCTAssertNil(SavedVersionExtractor.find(in: Data(#"pluginVersion="not-a-version""#.utf8)))
        XCTAssertNil(SavedVersionExtractor.find(in: Data()))
    }

    func testPluginsWithoutAVersionInStateReportNone() throws {
        let plist = try statePlist(type: "aumf", subtype: "FQ4p", manufacturer: "FabF", blobs: ["data": Data([1, 2, 3, 4])])
        let rec = RecordBuilder.au(name: "Pro-Q 4", manufacturer: "FabF", type: "aumf", subtype: "FQ4p")
        XCTAssertEqual(try ProjectDataParser.parse(project(plugin: rec, plist: plist)).records.first?.saved, [])
    }

    func testStateOfOneBuildDoesNotLeakToAnother() throws {
        let state = Data(#"<X pluginVersion="9.9.9"/>"#.utf8)
        let plist = try statePlist(type: "aufx", subtype: "Zzzz", manufacturer: "Acme", blobs: ["jucePluginState": state])
        let rec = RecordBuilder.au(name: "Other", manufacturer: "Acme", type: "aufx", subtype: "Othr")
        XCTAssertEqual(try ProjectDataParser.parse(project(plugin: rec, plist: plist)).records.first?.saved, [])
    }

    func testMalformedPlistIsIgnored() throws {
        var d = RecordBuilder.project([RecordBuilder.au(name: "Thing", manufacturer: "Acme", type: "aufx", subtype: "Thng")])
        d.append(Data("<?xml version=\"1.0\"?><plist><dict><key>broken".utf8)); d.append(Data("</plist>".utf8))
        XCTAssertEqual(try ProjectDataParser.parse(d).records.count, 1)
    }

    // MARK: Comparison

    func testVersionComparison() {
        XCTAssertEqual(SavedVersionExtractor.compare("1.0.2", "1.0.2"), .orderedSame)
        XCTAssertEqual(SavedVersionExtractor.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(SavedVersionExtractor.compare("1.9.0", "1.10.0"), .orderedAscending, "numeric, not lexicographic")
        XCTAssertEqual(SavedVersionExtractor.compare("2.0.0", "1.9.9"), .orderedDescending)
        XCTAssertEqual(SavedVersionExtractor.compare("5.5.5.19885 Authorization: X", "5.5.5.19885"), .orderedSame)
        XCTAssertNil(SavedVersionExtractor.compare("abc", "1.0"))
    }

    private func entry(saved: [SavedVersion], installed: String?, installedVersions: [String] = []) throws -> PluginEntry {
        let fake = try FakeInstall()
        if let installed {
            try fake.addComponent("Thing", short: installed, type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        }
        var r = RawPluginRecord(kind: .audioUnit, name: "Thing", manufacturer: "Acme", type: "aufx", subtype: "Thng", count: 1, firstOffset: 0)
        r.saved = saved
        return PluginResolver.resolve(r, index: fake.index())
    }

    func testResolverFlagsUpdatedAndDowngradedPlugins() throws {
        let v = { (s: String) in [SavedVersion(version: s, source: "pluginVersion attribute")] }
        var e = try entry(saved: v("1.0.0"), installed: "1.1.0")
        XCTAssertEqual(e.versionCheck, .installedNewer); XCTAssertEqual(e.savedVersion, "1.0.0")
        e = try entry(saved: v("2.0.0"), installed: "1.1.0")
        XCTAssertEqual(e.versionCheck, .installedOlder)
        e = try entry(saved: v("1.1.0"), installed: "1.1.0")
        XCTAssertEqual(e.versionCheck, .same)
        e = try entry(saved: [], installed: "1.1.0")
        XCTAssertEqual(e.versionCheck, .notStored); XCTAssertNil(e.savedVersion)
        e = try entry(saved: v("1.0.0"), installed: nil)
        XCTAssertEqual(e.versionCheck, .notInstalled)
        XCTAssertEqual(e.savedVersion, "1.0.0", "the saved version is still useful when the plugin is missing")
    }

    func testMixedSavedVersionsAreAllReported() throws {
        let e = try entry(saved: [SavedVersion(version: "1.0.0", source: "s"), SavedVersion(version: "1.1.0", source: "s")], installed: "1.1.0")
        XCTAssertEqual(e.savedVersion, "1.0.0, 1.1.0")
        XCTAssertEqual(e.versionCheck, .installedNewer, "one instance was saved by an older build")
    }

    func testUncertainMatchCannotBeCompared() throws {
        let fake = try FakeInstall()
        try fake.addComponent("A", short: "1.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        try fake.addComponent("B", short: "2.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        var r = RawPluginRecord(kind: .audioUnit, name: "Thing", manufacturer: "Acme", type: "aufx", subtype: "Thng", count: 1, firstOffset: 0)
        r.saved = [SavedVersion(version: "1.0", source: "s")]
        XCTAssertEqual(PluginResolver.resolve(r, index: fake.index()).versionCheck, .cannotCompare)
    }

    func testBuiltInsUseTheLogicVersionThatSavedTheProject() throws {
        let raw = RawPluginRecord(kind: .builtIn, name: "Compressor", manufacturer: "GAME", type: "", subtype: "", count: 1, firstOffset: 0)
        let fake = try FakeInstall()
        var e = PluginResolver.resolve(raw, index: fake.index(logicVersion: "12.2"), projectLogicVersion: "12.2")
        XCTAssertEqual(e.savedVersion, "12.2 (Logic Pro)"); XCTAssertEqual(e.versionCheck, .same)
        e = PluginResolver.resolve(raw, index: fake.index(logicVersion: "12.3"), projectLogicVersion: "12.2")
        XCTAssertEqual(e.versionCheck, .installedNewer)
        e = PluginResolver.resolve(raw, index: fake.index(logicVersion: "11.1"), projectLogicVersion: "12.2")
        XCTAssertEqual(e.versionCheck, .installedOlder)
    }

    // MARK: End to end

    func testEndToEndFromPackageOnDisk() throws {
        let state = Data(#"<ValhallaRoom pluginVersion="2.0.5"/>"#.utf8)
        let plist = try statePlist(type: "aufx", subtype: "Ruum", manufacturer: "oDin", blobs: ["jucePluginState": state])
        let rec = RecordBuilder.au(name: "ValhallaRoo", manufacturer: "oDin", type: "aufx", subtype: "Ruum")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PL-\(UUID().uuidString)/S.logicx")
        let alt = tmp.appendingPathComponent("Alternatives/000"); try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        try project(plugin: rec, plist: plist).write(to: alt.appendingPathComponent("ProjectData"))
        let fake = try FakeInstall()
        try fake.addComponent("ValhallaRoom", short: "2.1.0", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        guard case .loaded(let report) = ProjectLoader.load(DiscoveredProject(url: tmp, kind: .logicx), index: fake.index()) else { return XCTFail() }
        let p = try XCTUnwrap(report.plugins.first)
        XCTAssertEqual(p.savedVersion, "2.0.5"); XCTAssertEqual(p.installedVersion, "2.1.0"); XCTAssertEqual(p.versionCheck, .installedNewer)
        XCTAssertTrue(Exporters.csv(report).contains("ValhallaRoom,Valhalla DSP, LLC") || Exporters.csv(report).contains("2.0.5"))
    }
}
