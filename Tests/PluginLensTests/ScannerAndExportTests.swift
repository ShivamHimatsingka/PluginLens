import XCTest
@testable import PluginLens

final class ScannerAndExportTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PluginLensScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    private func makePackage(_ path: String, projectData: Data?, savedFrom: String? = "Logic Pro 12.2 (6644)") throws -> URL {
        let pkg = tmp.appendingPathComponent(path)
        let alt = pkg.appendingPathComponent("Alternatives/000")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        if let projectData { try projectData.write(to: alt.appendingPathComponent("ProjectData")) }
        if let savedFrom {
            try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["LastSavedFrom": savedFrom], format: .binary, options: 0)
            try plist.write(to: pkg.appendingPathComponent("Resources/ProjectInformation.plist"))
        }
        return pkg
    }

    // MARK: Discovery

    func testDiscoversNestedPackagesAndIgnoresTheirContents() throws {
        let good = RecordBuilder.project([])
        try makePackage("A.logicx", projectData: good)
        try makePackage("Sub/Deeper/B.logicx", projectData: good)
        try makePackage("Sub/C.logicx", projectData: good)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Other"), withIntermediateDirectories: true)
        let found = ProjectScanner.discover(at: tmp)
        XCTAssertEqual(found.map(\.name), ["A", "B", "C"])
    }

    func testPickingASinglePackageReturnsJustThatPackage() throws {
        let pkg = try makePackage("Solo.logicx", projectData: RecordBuilder.project([]))
        XCTAssertEqual(ProjectScanner.discover(at: pkg).map(\.name), ["Solo"])
    }

    func testLegacyProjectsAreListedAsUnsupported() throws {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Old.logic"), withIntermediateDirectories: true)
        let found = ProjectScanner.discover(at: tmp)
        XCTAssertEqual(found.first?.kind, .legacy)
        guard case .failed(.legacyFormat) = ProjectLoader.load(found[0], index: FakeInstallIndex.empty) else { return XCTFail() }
    }

    func testProjectFolderWithoutExtensionIsFound() throws {
        try makePackage("Extracted Folder", projectData: RecordBuilder.project([]), savedFrom: nil)
        XCTAssertEqual(ProjectScanner.discover(at: tmp).map(\.name), ["Extracted Folder"])
    }

    // MARK: Failure isolation

    func testBadProjectsFailIndividuallyAndOthersStillLoad() throws {
        let rec = RecordBuilder.au(name: "Pro-Q 4", manufacturer: "FabF", type: "aumf", subtype: "FQ4p")
        try makePackage("1 good.logicx", projectData: RecordBuilder.project([rec]))
        try makePackage("2 empty.logicx", projectData: nil)
        try makePackage("3 tiny.logicx", projectData: Data([1, 2, 3]))
        try makePackage("4 wrongformat.logicx", projectData: Data(repeating: 0x41, count: 500))
        let index = FakeInstallIndex.empty
        let results = ProjectScanner.discover(at: tmp).map { ($0.name, ProjectLoader.load($0, index: index)) }
        XCTAssertEqual(results.count, 4)
        guard case .loaded(let r) = results[0].1 else { return XCTFail("good project should load") }
        XCTAssertEqual(r.plugins.map(\.status), [.notInstalled])
        guard case .failed(.noProjectData) = results[1].1 else { return XCTFail("\(results[1].1)") }
        guard case .failed(.corrupt) = results[2].1 else { return XCTFail("\(results[2].1)") }
        guard case .failed(.unsupportedFormat) = results[3].1 else { return XCTFail("\(results[3].1)") }
    }

    func testNewerLogicVersionProducesWarningNotFailure() throws {
        try makePackage("Future.logicx", projectData: RecordBuilder.project([]), savedFrom: "Logic Pro 13.0 (9999)")
        let p = ProjectScanner.discover(at: tmp)[0]
        guard case .loaded(let r) = ProjectLoader.load(p, index: FakeInstallIndex.empty) else { return XCTFail() }
        XCTAssertTrue(r.warnings.contains { $0.contains("newer") })
        XCTAssertEqual(r.lastSavedFrom, "Logic Pro 13.0 (9999)")
    }

    func testUnreadableProjectDataBecomesErrorNotCrash() throws {
        let pkg = try makePackage("Locked.logicx", projectData: RecordBuilder.project([]))
        let file = pkg.appendingPathComponent("Alternatives/000/ProjectData")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let p = DiscoveredProject(url: pkg, kind: .logicx)
        if getuid() != 0, case .failed(.unreadable) = ProjectLoader.load(p, index: FakeInstallIndex.empty) {} else if getuid() != 0 {
            XCTFail("expected .unreadable")
        }
    }

    func testNewestAlternativeIsUsed() throws {
        let pkg = try makePackage("Alts.logicx", projectData: RecordBuilder.project([]))
        let alt1 = pkg.appendingPathComponent("Alternatives/001"); try FileManager.default.createDirectory(at: alt1, withIntermediateDirectories: true)
        let rec = RecordBuilder.au(name: "Newer", manufacturer: "Acme", type: "aufx", subtype: "Newr")
        try RecordBuilder.project([rec]).write(to: alt1.appendingPathComponent("ProjectData"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: alt1.appendingPathComponent("ProjectData").path)
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: pkg, kind: .logicx), index: FakeInstallIndex.empty) else { return XCTFail() }
        XCTAssertEqual(r.plugins.map(\.name), ["Newer"])
        XCTAssertTrue(r.warnings.contains { $0.contains("alternatives") })
    }

    // MARK: Export

    private func sampleReport() -> ProjectReport {
        let plugins = [
            PluginEntry(id: "1", name: "Pro-Q 4", manufacturer: "FabFilter", format: .au, installedVersion: "4.01", status: .installed,
                        isUncertain: false, note: nil, otherFormats: [.vst3], codes: "aumf/FQ4p/FabF", bundlePath: nil),
            PluginEntry(id: "2", name: "=EVIL(\"x\"), a|b", manufacturer: "Zzzz", format: .au, installedVersion: nil, status: .notInstalled,
                        isUncertain: false, note: "Not here, really", otherFormats: [], codes: "aufx/Gone/Zzzz", bundlePath: nil),
        ]
        return ProjectReport(project: DiscoveredProject(url: URL(fileURLWithPath: "/tmp/My Song.logicx"), kind: .logicx),
                             projectDataURL: nil, lastModified: nil, lastSavedFrom: "Logic Pro 12.2", plugins: plugins, warnings: [])
    }

    func testMarkdownExport() {
        let md = Exporters.markdown(sampleReport())
        XCTAssertTrue(md.contains("# My Song"))
        XCTAssertTrue(md.contains("| Pro-Q 4 | FabFilter | AU (+VST3 installed) | — | 4.01 | Not stored | Installed |"))
        XCTAssertTrue(md.contains("a\\|b"), "pipes in names must be escaped")
        XCTAssertTrue(md.contains("Not installed"))
    }

    func testCSVExportQuotesAndNeutralisesFormulas() {
        let csv = Exporters.csv(sampleReport())
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Plugin,Manufacturer,Format,Saved with,Installed version,Version check,Status,AU codes,Note")
        XCTAssertEqual(lines[1], "Pro-Q 4,FabFilter,AU (+VST3 installed),,4.01,Not stored,Installed,aumf/FQ4p/FabF,")
        XCTAssertTrue(lines[2].hasPrefix("\"'=EVIL(\"\"x\"\"), a|b\",Zzzz"), lines[2])
        XCTAssertTrue(lines[2].hasSuffix("\"Not here, really\""))
    }
}

enum FakeInstallIndex {
    static var empty: InstalledPluginIndex {
        InstalledPluginIndex(directories: SearchDirectories(audioUnits: [], vst: [], vst3: []), logicVersion: nil)
    }
}
