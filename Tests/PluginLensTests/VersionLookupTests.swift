import XCTest
@testable import PluginLens

final class VersionLookupTests: XCTestCase {
    private func record(_ name: String, _ man: String, _ type: String, _ sub: String) -> RawPluginRecord {
        RawPluginRecord(kind: .audioUnit, name: String(name.prefix(11)), manufacturer: man, type: type, subtype: sub, count: 1, firstOffset: 0)
    }

    func testExactMatchReadsShortVersion() throws {
        let fake = try FakeInstall()
        try fake.addComponent("FabFilter Pro-Q 4", short: "4.01", build: "4.01.1",
                              type: "aumf", subtype: "FQ4p", manufacturer: "FabF", name: "FabFilter: Pro-Q 4")
        let e = PluginResolver.resolve(record("Pro-Q 4", "FabF", "aumf", "FQ4p"), index: fake.index())
        XCTAssertEqual(e.name, "Pro-Q 4")
        XCTAssertEqual(e.manufacturer, "FabFilter")
        XCTAssertEqual(e.installedVersion, "4.01")
        XCTAssertEqual(e.status, .installed)
        XCTAssertFalse(e.isUncertain)
        XCTAssertEqual(e.format, .au)
    }

    func testFallsBackToBundleVersionWhenShortVersionMissing() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Thing", short: nil, build: "7.2.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        let e = PluginResolver.resolve(record("Thing", "Acme", "aufx", "Thng"), index: fake.index())
        XCTAssertEqual(e.installedVersion, "7.2.0")
        XCTAssertEqual(e.status, .installed)
    }

    func testBlankShortVersionFallsBackToBundleVersion() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Thing", short: " ", build: "3", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        XCTAssertEqual(PluginResolver.resolve(record("Thing", "Acme", "aufx", "Thng"), index: fake.index()).installedVersion, "3")
    }

    func testNoVersionStringsGivesVersionUnknown() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Thing", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        let e = PluginResolver.resolve(record("Thing", "Acme", "aufx", "Thng"), index: fake.index())
        XCTAssertNil(e.installedVersion)
        XCTAssertEqual(e.status, .versionUnknown)
    }

    func testMissingPluginIsNotInstalled() throws {
        let fake = try FakeInstall()
        let e = PluginResolver.resolve(record("Gone Plugin", "Zzzz", "aufx", "Gone"), index: fake.index())
        XCTAssertEqual(e.status, .notInstalled)
        XCTAssertNil(e.installedVersion)
        XCTAssertEqual(e.manufacturer, "Zzzz")
    }

    func testExactMatchIgnoresNameDifferences() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Renamed", short: "1.5", type: "aufx", subtype: "Abcd", manufacturer: "Acme", name: "Acme: Totally Different Name")
        let e = PluginResolver.resolve(record("Old Name", "Acme", "aufx", "Abcd"), index: fake.index())
        XCTAssertEqual(e.name, "Totally Different Name")
        XCTAssertEqual(e.status, .installed)
    }

    func testSameCodesInTwoBundlesWithDifferentVersionsIsUncertain() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Thing", short: "1.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        try fake.addComponent("Thing Old", short: "2.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        let e = PluginResolver.resolve(record("Thing", "Acme", "aufx", "Thng"), index: fake.index())
        XCTAssertTrue(e.isUncertain)
        XCTAssertNil(e.installedVersion, "must not guess between 1.0 and 2.0")
        XCTAssertEqual(e.status, .versionUnknown)
    }

    func testSameCodesInTwoBundlesWithSameVersionIsFine() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Thing", short: "1.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        let userDir = fake.root.appendingPathComponent("User"); try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try fake.addComponent("Thing", in: userDir, short: "1.0", type: "aufx", subtype: "Thng", manufacturer: "Acme", name: "Acme: Thing")
        let idx = InstalledPluginIndex(directories: SearchDirectories(audioUnits: [fake.au, userDir], vst: [], vst3: []), logicVersion: nil)
        let e = PluginResolver.resolve(record("Thing", "Acme", "aufx", "Thng"), index: idx)
        XCTAssertEqual(e.installedVersion, "1.0")
        XCTAssertFalse(e.isUncertain)
    }

    func testNameFallbackIsMarkedUncertainNeverInstalled() throws {
        let fake = try FakeInstall()
        // Subtype changed between plugin generations; manufacturer and name prefix still agree.
        try fake.addComponent("Big Verb 2", short: "2.1", type: "aufx", subtype: "BVv2", manufacturer: "Acme", name: "Acme: Big Verb 2")
        let e = PluginResolver.resolve(record("Big Verb 2", "Acme", "aufx", "BVv1"), index: fake.index())
        XCTAssertTrue(e.isUncertain)
        XCTAssertEqual(e.status, .versionUnknown)
        XCTAssertEqual(e.versionText, "2.1 (uncertain)")
    }

    func testAmbiguousNameFallbackIsNotInstalled() throws {
        let fake = try FakeInstall()
        try fake.addComponent("A", short: "1", type: "aufx", subtype: "AAAA", manufacturer: "Acme", name: "Acme: Reverb One")
        try fake.addComponent("B", short: "1", type: "aufx", subtype: "BBBB", manufacturer: "Acme", name: "Acme: Reverb Two")
        let e = PluginResolver.resolve(record("Reverb", "Acme", "aufx", "ZZZZ"), index: fake.index())
        XCTAssertEqual(e.status, .notInstalled, "two candidates: refuse to guess")
    }

    func testNameFallbackRequiresSameManufacturer() throws {
        let fake = try FakeInstall()
        try fake.addComponent("X", short: "1", type: "aufx", subtype: "AAAA", manufacturer: "Other", name: "Other: Reverb")
        let e = PluginResolver.resolve(record("Reverb", "Acme", "aufx", "ZZZZ"), index: fake.index())
        XCTAssertEqual(e.status, .notInstalled)
    }

    func testBuiltInUsesLogicVersion() throws {
        let fake = try FakeInstall()
        let raw = RawPluginRecord(kind: .builtIn, name: "St-Delay", manufacturer: "GAME", type: "", subtype: "", count: 1, firstOffset: 0)
        let e = PluginResolver.resolve(raw, index: fake.index(logicVersion: "12.2"))
        XCTAssertEqual(e.name, "Stereo Delay")
        XCTAssertEqual(e.format, .builtIn)
        XCTAssertEqual(e.status, .installed)
        XCTAssertEqual(e.installedVersion, "12.2 (Logic Pro)")
        let none = PluginResolver.resolve(raw, index: fake.index(logicVersion: nil))
        XCTAssertEqual(none.status, .versionUnknown)
    }

    func testAlsoInstalledAsVST3IsReportedSeparately() throws {
        let fake = try FakeInstall()
        try fake.addComponent("Acme Verb", short: "1.0", type: "aufx", subtype: "Verb", manufacturer: "Acme", name: "Acme: Verb")
        try fake.addPlain("Acme Verb", ext: "vst3", in: fake.vst3)
        let e = PluginResolver.resolve(record("Verb", "Acme", "aufx", "Verb"), index: fake.index())
        XCTAssertEqual(e.format, .au)
        XCTAssertEqual(e.otherFormats, [.vst3])
        XCTAssertEqual(e.formatText, "AU (+VST3 installed)")
    }

    func testIntegerComponentCodesAreDecoded() {
        XCTAssertEqual(InstalledPluginIndex.code(0x61756678), "aufx")
        XCTAssertEqual(InstalledPluginIndex.code("aumf"), "aumf")
        XCTAssertNil(InstalledPluginIndex.code("toolong"))
    }

    func testBrokenInfoPlistIsIgnored() throws {
        let fake = try FakeInstall()
        let bad = fake.au.appendingPathComponent("Bad.component/Contents")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: bad.appendingPathComponent("Info.plist"))
        XCTAssertTrue(fake.index().components.isEmpty)
    }
}
