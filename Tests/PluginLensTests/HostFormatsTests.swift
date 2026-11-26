import XCTest
@testable import PluginLens

final class HostFormatsTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PLHost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func idx(_ fake: FakeInstall? = nil, reaper: String? = nil) -> InstalledPluginIndex {
        fake?.index() ?? InstalledPluginIndex(directories: SearchDirectories(audioUnits: [], vst: [], vst3: []), logicVersion: nil, abletonVersion: nil)
    }
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    private func load(_ name: String, _ kind: DiscoveredProject.Kind, _ content: String, index: InstalledPluginIndex) throws -> LoadState {
        let url = tmp.appendingPathComponent(name); try Data(content.utf8).write(to: url)
        return ProjectLoader.load(DiscoveredProject(url: url, kind: kind), index: index)
    }

    // MARK: REAPER

    private var rpp: String {
        let state = b64(#"<ValhallaRoom pluginVersion="2.0.5" presetName="Default"/>"#)
        return """
        <REAPER_PROJECT 0.1 "7.27/macOS-arm64" 1700000000
          RIPPLE 0
          <TRACK {AAAA}
            NAME "Guitar"
            <FXCHAIN
              SHOW 0
              <VST "VST3: Pro-Q 4 (FabFilter)" "FabFilter Pro-Q 4.vst3" 0 "" 1181954349{5653} ""
                \(state.prefix(20))
                \(state.dropFirst(20))
              >
              FLOATPOS 0 0 0 0
              <AU "AU: ValhallaRoom (Valhalla DSP, LLC)" "Valhalla DSP, LLC: ValhallaRoom" "" 
                \(state)
              >
              <VST "VST: ReaComp (Cockos)" reacomp.vst.dylib 0 "" 1919247213<5653> ""
              >
              <JS utility/volume_pan ""
              >
              <CLAP "CLAP: Surge XT (Surge Synth Team)" org.surge-synth-team.surge-xt "" 
              >
            >
          >
          <TRACK {BBBB}
            <FXCHAIN
              <VST "VST3: Pro-Q 4 (FabFilter)" "FabFilter Pro-Q 4.vst3" 0 "" 1181954349{5653} ""
              >
            >
          >
        >
        """
    }

    func testReaperParsesAllEffectKindsAndMergesDuplicates() throws {
        let doc = try ReaperParser.parse(Data(rpp.utf8))
        XCTAssertEqual(doc.savedVersion, "7.27"); XCTAssertEqual(doc.savedWith, "REAPER 7.27/macOS-arm64")
        XCTAssertEqual(doc.plugins.map(\.name), ["Pro-Q 4", "ValhallaRoom", "ReaComp", "volume_pan", "Surge XT"])
        let q = doc.plugins[0]
        XCTAssertEqual(q.format, .vst3); XCTAssertEqual(q.vendor, "FabFilter"); XCTAssertEqual(q.fileName, "FabFilter Pro-Q 4.vst3"); XCTAssertEqual(q.count, 2)
        XCTAssertEqual(doc.plugins[1].format, .au); XCTAssertEqual(doc.plugins[1].auFullName, "Valhalla DSP, LLC: ValhallaRoom")
        XCTAssertTrue(doc.plugins[2].isHostBuiltIn); XCTAssertEqual(doc.plugins[3].format, .jsfx); XCTAssertEqual(doc.plugins[4].format, .clap)
    }

    func testReaperStateIsDecodedAcrossLinesAndVersionIsRead() throws {
        let doc = try ReaperParser.parse(Data(rpp.utf8))
        let au = doc.plugins[1]
        XCTAssertEqual(au.states.count, 1)
        XCTAssertEqual(SavedVersionExtractor.statePlistCandidates(au.states[0]).versions.first?.version, "2.0.5")
    }

    func testReaperResolvesAgainstInstalledPlugins() throws {
        let fake = try FakeInstall()
        try fake.addPlain("FabFilter Pro-Q 4", ext: "vst3", in: fake.vst3)
        try fake.addComponent("ValhallaRoom", short: "2.1.0", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        guard case .loaded(let r) = try load("a.rpp", .reaper, rpp, index: idx(fake)) else { return XCTFail() }
        let byName = Dictionary(uniqueKeysWithValues: r.plugins.map { ($0.name, $0) })
        XCTAssertEqual(byName["Pro-Q 4"]?.installedVersion, "1.0"); XCTAssertEqual(byName["Pro-Q 4"]?.status, .installed)
        let v = try XCTUnwrap(byName["ValhallaRoom"])
        XCTAssertEqual(v.installedVersion, "2.1.0"); XCTAssertEqual(v.savedVersion, "2.0.5"); XCTAssertEqual(v.versionCheck, .installedNewer); XCTAssertFalse(v.isUncertain)
        XCTAssertEqual(byName["Surge XT"]?.status, .notInstalled)
        XCTAssertEqual(byName["ReaComp"]?.format, .reaperBuiltIn); XCTAssertEqual(r.lastSavedFrom, "REAPER 7.27/macOS-arm64")
    }

    func testReaperRejectsOtherFilesAndTinyFiles() {
        XCTAssertThrowsError(try ReaperParser.parse(Data("hello world, this is not a project".utf8)))
        XCTAssertThrowsError(try ReaperParser.parse(Data("<REAPER".utf8)))
        XCTAssertNoThrow(try ReaperParser.parse(Data("<REAPER_PROJECT 0.1 \"7.0/macOS\" 1\n>\n".utf8)))
    }

    func testReaperTokenizer() {
        XCTAssertEqual(ReaperParser.tokenize(#"VST "VST3: A (B)" "x y.vst3" 0 "" 123{AB} """#), ["VST", "VST3: A (B)", "x y.vst3", "0", "", "123{AB}", ""])
        XCTAssertEqual(ReaperParser.tokenize("JS `a b` 'c d' e"), ["JS", "a b", "c d", "e"])
    }

    func testReaperMalformedInputNeverCrashes() throws {
        var text = rpp
        for cut in stride(from: 20, to: text.count, by: 37) { _ = try? ReaperParser.parse(Data(text.prefix(cut).utf8)) }
        text = rpp.replacingOccurrences(of: ">", with: "")
        _ = try? ReaperParser.parse(Data(text.utf8))
    }

    // MARK: Waveform

    func testWaveformPluginsAreParsedAndAUIdentifierGivesCodes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <EDIT appVersion="Waveform 12.0.5" projectID="1">
          <TRACK>
            <PLUGIN type="au" name="ValhallaRoom" manufacturer="Valhalla DSP, LLC" filename="AudioUnit:Effects/aufx,Ruum,oDin" uid="1"/>
            <PLUGIN type="vst3" name="Pro-Q 4" manufacturer="FabFilter" filename="/Library/Audio/Plug-Ins/VST3/FabFilter Pro-Q 4.vst3" uid="2"/>
            <PLUGIN type="compressor" name="Compressor"/><PLUGIN type="volume" name="Volume &amp; Pan"/><PLUGIN type="level"/></TRACK>
        </EDIT>
        """
        let doc = try WaveformParser.parse(Data(xml.utf8))
        XCTAssertEqual(doc.savedVersion, "12.0.5"); XCTAssertEqual(doc.plugins.map(\.name), ["ValhallaRoom", "Pro-Q 4", "Compressor"], "the track's volume and level are skipped")
        XCTAssertEqual(doc.plugins[0].auCodes, .init(type: "aufx", subtype: "Ruum", manufacturer: "oDin"))
        XCTAssertEqual(doc.plugins[1].fileName, "/Library/Audio/Plug-Ins/VST3/FabFilter Pro-Q 4.vst3")
        let fake = try FakeInstall()
        try fake.addPlain("FabFilter Pro-Q 4", ext: "vst3", in: fake.vst3)
        try fake.addComponent("ValhallaRoom", short: "2.0.5", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        guard case .loaded(let r) = try load("e.tracktionedit", .waveform, xml, index: idx(fake)) else { return XCTFail() }
        XCTAssertEqual(r.plugins.map(\.status), [.installed, .installed, .versionUnknown])
        XCTAssertEqual(r.plugins[2].format, .waveformBuiltIn)
    }

    func testWaveformRejectsOtherXML() {
        XCTAssertThrowsError(try WaveformParser.parse(Data("<?xml version=\"1.0\"?><Other attr=\"value that is long enough\"/>".utf8)))
    }

    // MARK: Ardour

    func testArdourProcessorsAndAUUniqueIDs() throws {
        func n(_ s: String) -> UInt32 { UInt32(s.utf8.reduce(0) { $0 << 8 | Int($1) }) }
        let xml = """
        <?xml version="1.0"?><Session version="7003" name="s" sample-rate="48000"><Routes><Route name="Vox">
          <Processor id="1" name="Amp" type="amp"/><Processor id="2" name="meter" type="meter"/>
          <Processor id="3" name="ValhallaRoom" type="audiounit" unique-id="\(n("aufx"))-\(n("Ruum"))-\(n("oDin"))"/>
          <Processor id="4" name="ACE Reverb" type="lv2" unique-id="urn:ace"/>
          <Processor id="5" name="Pro-Q 4" type="vst3"/>
        </Route></Routes></Session>
        """
        let doc = try ArdourParser.parse(Data(xml.utf8))
        XCTAssertEqual(doc.plugins.map(\.name), ["ValhallaRoom", "ACE Reverb", "Pro-Q 4"])
        XCTAssertEqual(doc.plugins[0].auCodes, .init(type: "aufx", subtype: "Ruum", manufacturer: "oDin"))
        XCTAssertEqual(doc.plugins[1].format, .lv2)
        let fake = try FakeInstall()
        try fake.addComponent("ValhallaRoom", short: "2.0.5", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        guard case .loaded(let r) = try load("s.ardour", .ardour, xml, index: idx(fake)) else { return XCTFail() }
        XCTAssertEqual(r.plugins[0].installedVersion, "2.0.5"); XCTAssertEqual(r.plugins[1].status, .versionUnknown); XCTAssertEqual(r.plugins[2].status, .notInstalled)
    }

    func testNameOnlyMatchFindsTheUniqueBundleContainingTheName() throws {
        let fake = try FakeInstall()
        try fake.addPlain("FabFilter Pro-Q 4", ext: "vst3", in: fake.vst3)
        let xml = #"<?xml version="1.0"?><Session version="7003"><Routes><Route><Processor name="Pro-Q 4" type="vst3"/></Route></Routes></Session>"#
        guard case .loaded(let r) = try load("n.ardour", .ardour, xml, index: idx(fake)) else { return XCTFail() }
        XCTAssertTrue(r.plugins[0].isUncertain); XCTAssertEqual(r.plugins[0].status, .versionUnknown); XCTAssertEqual(r.plugins[0].installedVersion, "1.0")
        try fake.addPlain("Other Pro-Q 4", ext: "vst3", in: fake.vst3)
        guard case .loaded(let r2) = try load("n2.ardour", .ardour, xml, index: idx(fake)) else { return XCTFail() }
        XCTAssertEqual(r2.plugins[0].status, .notInstalled, "two candidates: refuse to guess")
    }

    func testArdourFileFromAnotherAppIsRejected() {
        XCTAssertThrowsError(try ArdourParser.parse(Data("<?xml version=\"1.0\"?><NotArdour a=\"b\"/>".utf8)))
    }

    // MARK: Discovery and Apple-family packages

    func testScannerRecognisesAllExtensions() throws {
        for f in ["a.rpp", "b.tracktionedit", "c.ardour", "d.als"] { try Data(count: 32).write(to: tmp.appendingPathComponent(f)) }
        try Data(count: 32).write(to: tmp.appendingPathComponent("e.rpp-bak"))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("g.band/Alternatives/000"), withIntermediateDirectories: true)
        let kinds = Dictionary(uniqueKeysWithValues: ProjectScanner.discover(at: tmp).map { ($0.url.lastPathComponent, $0.kind) })
        XCTAssertEqual(kinds["a.rpp"], .reaper); XCTAssertEqual(kinds["b.tracktionedit"], .waveform); XCTAssertEqual(kinds["c.ardour"], .ardour)
        XCTAssertEqual(kinds["d.als"], .abletonSet); XCTAssertEqual(kinds["g.band"], .logicx); XCTAssertNil(kinds["e.rpp-bak"])
    }

    func testBandPackageWithLowercaseProjectDataIsReadWithAWarning() throws {
        let band = tmp.appendingPathComponent("Song.band/Resources"); try FileManager.default.createDirectory(at: band, withIntermediateDirectories: true)
        let rec = RecordBuilder.au(name: "Pro-Q 4", manufacturer: "FabF", type: "aumf", subtype: "FQ4p")
        try RecordBuilder.project([rec]).write(to: band.appendingPathComponent("projectData"))
        let state = ProjectLoader.load(DiscoveredProject(url: tmp.appendingPathComponent("Song.band"), kind: .logicx), index: idx())
        guard case .loaded(let r) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(r.plugins.count, 1); XCTAssertTrue(r.warnings.contains { $0.contains("GarageBand") })
    }

    func testBandPackageWithoutProjectDataFailsCleanly() throws {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Empty.band"), withIntermediateDirectories: true)
        guard case .failed(.noProjectData) = ProjectLoader.load(DiscoveredProject(url: tmp.appendingPathComponent("Empty.band"), kind: .logicx), index: idx()) else { return XCTFail() }
    }
}
