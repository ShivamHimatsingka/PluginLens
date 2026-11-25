import XCTest
@testable import PluginLens

final class RealFormatsTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PLReal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func load(_ name: String, _ kind: DiscoveredProject.Kind, _ data: Data, _ index: InstalledPluginIndex) throws -> LoadState {
        let url = tmp.appendingPathComponent(name); try data.write(to: url)
        return ProjectLoader.load(DiscoveredProject(url: url, kind: kind), index: index)
    }

    // MARK: A real REAPER project (saved by REAPER 7.28 on macOS)

    func testRealReaperProjectWithNeuralAmpModeler() throws {
        let doc = try ReaperParser.parse(Fixtures.file("neural_amp_modeler", "rpp"))
        XCTAssertEqual(doc.savedVersion, "7.28")
        let p = try XCTUnwrap(doc.plugins.first)
        XCTAssertEqual(p.name, "NeuralAmpModeler"); XCTAssertEqual(p.vendor, "StevenAtkinson"); XCTAssertEqual(p.format, .vst3); XCTAssertEqual(p.fileName, "NeuralAmpModeler.vst3")
        XCTAssertEqual(SavedVersionExtractor.statePlistCandidates(try XCTUnwrap(p.states.first)).versions.first?.version, "0.7.12",
                       "the plugin's own version is stored in its saved state")
        let fake = try FakeInstall()
        try fake.addPlain("NeuralAmpModeler", ext: "vst3", in: fake.vst3)
        guard case .loaded(let r) = try load("n.rpp", .reaper, Fixtures.file("neural_amp_modeler", "rpp"), fake.index()) else { return XCTFail() }
        XCTAssertEqual(r.plugins.first?.savedVersion, "0.7.12"); XCTAssertEqual(r.plugins.first?.status, .installed)
    }

    // MARK: FL Studio wrapper layout (as found in real FL Studio 20.8.4 projects)

    private func chunk(_ id: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        var o: [UInt8] = []; for k in 0..<4 { o.append(UInt8(id >> (8 * UInt32(k)) & 255)) }
        for k in 0..<8 { o.append(UInt8((UInt64(bytes.count) >> (8 * UInt64(k))) & 255)) }
        return o + bytes
    }
    private func wrapper(type: UInt8 = 10, _ chunks: [[UInt8]]) -> [UInt8] { [type, 0, 0, 0] + chunks.flatMap { $0 } }
    private func flEvent(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var n = payload.count, v: [UInt8] = []
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; v.append(b) } while n > 0
        return [id] + v + payload
    }
    private func flText(_ id: UInt8, _ s: String) -> [UInt8] { flEvent(id, (s + "\0").utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }) }
    private func flp(_ events: [[UInt8]]) -> Data {
        let body = events.flatMap { $0 }
        var d = Data("FLhd".utf8); d.append(contentsOf: [6, 0, 0, 0, 0, 0, 1, 0, 96, 0]); d.append(Data("FLdt".utf8))
        d.append(contentsOf: (0..<4).map { UInt8(body.count >> (8 * $0) & 255) }); d.append(contentsOf: body); return d
    }

    func testFLWrapperChunksGiveNameVendorPathAndState() throws {
        let vst2 = wrapper([chunk(1, [0, 0]), chunk(50, [0]), chunk(51, Array("1lys".utf8)), chunk(54, Array("Sylenth1".utf8)),
                            chunk(55, Array(#"C:\Program Files\Steinberg\VstPlugins\LennarDigital\Sylenth1"#.utf8)), chunk(56, Array("LennarDigital".utf8)), chunk(53, [1, 2, 3])])
        let vst3 = wrapper(type: 8, [chunk(2, [0]), chunk(54, Array("OTT".utf8)), chunk(55, Array(#"C:\Program Files\Common Files\VST3\OTT.vst3"#.utf8)),
                                      chunk(56, Array("Xfer Records".utf8)), chunk(53, Array(#"<X pluginVersion="1.37.0"/>"#.utf8))])
        let doc = try FLStudioParser.parse(flp([
            flText(199, "20.8.4.2576"),
            flText(201, "Fruity Wrapper"), flText(203, "VST2"), flEvent(213, vst2),
            flText(201, "Fruity Wrapper"), flText(203, "OTT (failed to load)"), flEvent(213, vst3),
            flText(201, ""), flText(203, "Sampler"), flText(201, "MIDI Out"), flText(201, "Fruity Balance"),
        ]))
        XCTAssertEqual(doc.plugins.map(\.name), ["Sylenth1", "OTT", "Fruity Balance"], "the wrapper's own name wins over FL's display name")
        XCTAssertEqual(doc.plugins[0].vendor, "LennarDigital"); XCTAssertEqual(doc.plugins[0].format, .vst); XCTAssertFalse(doc.plugins[0].formatGuess)
        XCTAssertEqual(doc.plugins[1].format, .vst3); XCTAssertEqual(doc.plugins[1].fileName, "OTT.vst3"); XCTAssertEqual(doc.plugins[1].vendor, "Xfer Records")
        XCTAssertEqual(SavedVersionExtractor.statePlistCandidates(doc.plugins[1].states[0]).versions.first?.version, "1.37.0")
    }

    // MARK: Waveform: names of built-ins and racks

    func testWaveformBuiltInNamesAndRacks() throws {
        let xml = #"<?xml version="1.0"?><EDIT appVersion="Waveform 13.5.19"><TRACK><PLUGIN type="8bandEq" id="1"/><PLUGIN type="comp" id="2"/><PLUGIN type="naturalReverb" id="3"/><PLUGIN type="rack" id="4"/><PLUGIN type="level" id="5"/><PLUGIN type="vst" uniqueId="4c777379" filename="/usr/lib/vst/mx_tune.so" name="mx_tune" manufacturer="liuanlin-mx" id="6"/></TRACK></EDIT>"#
        let doc = try WaveformParser.parse(Data(xml.utf8))
        XCTAssertEqual(doc.plugins.map(\.name), ["8-Band EQ", "Compressor", "Natural Reverb", "mx_tune"])
        XCTAssertEqual(doc.savedVersion, "13.5.19")
    }

    // MARK: ZIP

    func zip(_ files: [(String, Data)], deflate: Bool) throws -> Data {
        func le(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8(v >> (8 * $0) & 255) }) }
        var out = Data(), central = Data()
        let method = deflate ? 8 : 0
        for (name, content) in files {
            let payload: Data = deflate ? try (content as NSData).compressed(using: .zlib) as Data : content
            let nameData = Data(name.utf8)
            let offset = out.count
            var local = Data()
            for part in [le(0x04034B50, 4), le(20, 2), le(0, 2), le(method, 2), le(0, 4), le(0, 4), le(payload.count, 4), le(content.count, 4),
                         le(nameData.count, 2), le(0, 2), nameData, payload] { local.append(part) }
            out.append(local)
            var entry = Data()
            for part in [le(0x02014B50, 4), le(20, 2), le(20, 2), le(0, 2), le(method, 2), le(0, 4), le(0, 4), le(payload.count, 4), le(content.count, 4),
                         le(nameData.count, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 4), le(offset, 4), nameData] { entry.append(part) }
            central.append(entry)
        }
        var end = Data()
        for part in [le(0x06054B50, 4), le(0, 2), le(0, 2), le(files.count, 2), le(files.count, 2), le(central.count, 4), le(out.count, 4), le(0, 2)] { end.append(part) }
        return out + central + end
    }

    func testZipReadsStoredAndDeflatedEntries() throws {
        let files = [("a.txt", Data("hello".utf8)), ("dir/b.xml", Data(String(repeating: "<x/>", count: 500).utf8))]
        for deflate in [false, true] {
            let z = try ZipArchive(try zip(files, deflate: deflate))
            XCTAssertEqual(z.entries.map(\.name), ["a.txt", "dir/b.xml"])
            XCTAssertEqual(try z.read("a.txt"), files[0].1); XCTAssertEqual(try z.read("dir/b.xml"), files[1].1)
            XCTAssertThrowsError(try z.read("missing"))
        }
    }

    func testZipRejectsGarbageAndTruncation() throws {
        XCTAssertThrowsError(try ZipArchive(Data("not a zip file at all, just text.".utf8)))
        XCTAssertThrowsError(try ZipArchive(Data()))
        let good = try zip([("a.txt", Data("hello world".utf8))], deflate: true)
        for n in [10, 30, good.count - 10] { XCTAssertThrowsError(try ZipArchive(good.prefix(n))) }
        var bad = good; bad[bad.startIndex + 5] ^= 0xFF
        _ = try? ZipArchive(bad).read("a.txt")        // must not crash
    }

    // MARK: DAWproject

    func testDawprojectFixtureListsEveryDeviceWithItsVersion() throws {
        let doc = try DawprojectParser.parse(Fixtures.file("sample", "dawproject"))
        XCTAssertEqual(doc.savedWith, "Bitwig Studio 5.3.13"); XCTAssertEqual(doc.savedVersion, "5.3.13"); XCTAssertEqual(doc.hostLabel, "Bitwig Studio")
        XCTAssertEqual(doc.plugins.map(\.name), ["Ozone 12 Dynamics", "Sylenth1", "ValhallaRoom", "Surge XT", "EQ-5", "Reverb"])
        XCTAssertEqual(doc.plugins.map(\.format), [.vst3, .vst, .au, .clap, .dawBuiltIn, .dawBuiltIn])
        XCTAssertEqual(doc.plugins[0].knownSaved.first?.version, "12.0.1"); XCTAssertNil(doc.plugins[1].knownSaved.first)
    }

    func testDawprojectResolvesAgainstInstalledPlugins() throws {
        let fake = try FakeInstall()
        try fake.addComponent("ValhallaRoom", short: "2.1.0", type: "aufx", subtype: "Ruum", manufacturer: "oDin", name: "Valhalla DSP, LLC: ValhallaRoom")
        try fake.addPlain("Ozone 12 Dynamics", ext: "vst3", in: fake.vst3)
        guard case .loaded(let r) = try load("s.dawproject", .dawproject, Fixtures.file("sample", "dawproject"), fake.index()) else { return XCTFail() }
        let by = Dictionary(uniqueKeysWithValues: r.plugins.map { ($0.name, $0) })
        XCTAssertEqual(by["ValhallaRoom"]?.installedVersion, "2.1.0"); XCTAssertEqual(by["ValhallaRoom"]?.savedVersion, "2.0.5"); XCTAssertEqual(by["ValhallaRoom"]?.versionCheck, .installedNewer)
        XCTAssertEqual(by["Ozone 12 Dynamics"]?.status, .versionUnknown, "matched by name only, so never reported as certain"); XCTAssertEqual(by["Ozone 12 Dynamics"]?.isUncertain, true)
        XCTAssertEqual(by["Sylenth1"]?.status, .notInstalled)
        XCTAssertEqual(r.lastSavedFrom, "Bitwig Studio 5.3.13")
    }

    func testDawprojectRejectsOtherArchivesAndBrokenXML() throws {
        XCTAssertThrowsError(try DawprojectParser.parse(try zip([("other.txt", Data("x".utf8))], deflate: false)))
        XCTAssertThrowsError(try DawprojectParser.parse(try zip([("project.xml", Data("<Other/>".utf8))], deflate: true)))
        XCTAssertThrowsError(try DawprojectParser.parse(try zip([("project.xml", Data("<Project><Unclosed".utf8))], deflate: false)))
    }

    // MARK: LMMS

    private func lmmsXML(_ body: String) -> String { #"<?xml version="1.0"?><lmms-project creator="LMMS" version="1.0" type="song" creatorversion="1.2.2"><head/><song><trackcontainer>"# + body + "</trackcontainer></song></lmms-project>" }
    private func qCompress(_ s: String) throws -> Data {
        let raw = Data(s.utf8)
        var d = Data((0..<4).map { UInt8(raw.count >> (8 * (3 - $0)) & 255) })
        d.append(contentsOf: [0x78, 0x9C]); d.append(try (raw as NSData).compressed(using: .zlib) as Data); d.append(Data(count: 4)); return d
    }

    func testLMMSPluginsFromPlainAndCompressedProjects() throws {
        let body = #"""
        <track><instrumenttrack><instrument name="tripleoscillator"><tripleoscillator/></instrument></instrumenttrack></track>
        <track><instrumenttrack><instrument name="vestige"><vestige plugin="C:\VST\Synth One.dll" state="x"/></instrument>
          <fxchain><effect name="ladspaeffect" on="1"><ladspacontrols ports="2"/><key><attribute name="file" value="caps"/><attribute name="plugin" value="Plate"/></key></effect>
          <effect name="bassbooster"/></fxchain></instrumenttrack></track>
        """#
        for data in [Data(lmmsXML(body).utf8), try qCompress(lmmsXML(body))] {
            let doc = try LMMSParser.parse(data)
            XCTAssertEqual(doc.savedVersion, "1.2.2")
            XCTAssertEqual(doc.plugins.map(\.name), ["tripleoscillator", "Synth One", "Plate", "bassbooster"])
            XCTAssertEqual(doc.plugins[1].format, .vst); XCTAssertEqual(doc.plugins[1].fileName, "Synth One.dll")
            XCTAssertEqual(doc.plugins[2].format, .ladspa); XCTAssertEqual(doc.plugins[0].format, .dawBuiltIn)
        }
    }

    func testLMMSRejectsOtherAndDamagedFiles() throws {
        XCTAssertThrowsError(try LMMSParser.parse(Data("<?xml version=\"1.0\"?><Other attr=\"value that is long enough\"/>".utf8)))
        XCTAssertThrowsError(try LMMSParser.parse(Data(repeating: 0x41, count: 100)))
        XCTAssertThrowsError(try LMMSParser.parse(Data([0, 0, 1, 0, 0x78, 0x9C] + [UInt8](repeating: 7, count: 40))))
        let good = try qCompress(lmmsXML("<track/>"))
        for n in [8, 20, good.count - 8] { _ = try? LMMSParser.parse(good.prefix(n)) }
    }

    func testScannerRecognisesDawprojectAndLMMS() throws {
        for f in ["a.dawproject", "b.mmpz", "c.mmp"] { try Data(count: 40).write(to: tmp.appendingPathComponent(f)) }
        let kinds = Dictionary(uniqueKeysWithValues: ProjectScanner.discover(at: tmp).map { ($0.url.lastPathComponent, $0.kind) })
        XCTAssertEqual(kinds["a.dawproject"], .dawproject); XCTAssertEqual(kinds["b.mmpz"], .lmms); XCTAssertEqual(kinds["c.mmp"], .lmms)
    }
}
