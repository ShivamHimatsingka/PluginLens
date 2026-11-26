import XCTest
@testable import PluginLens

final class StudioOneTests: XCTestCase {
    private let zipper = RealFormatsTests()

    // MARK: DAWproject as written by Studio One (project.xml validated against the official Project.xsd)

    private let studioOneProject = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Project version="1.0"><Application name="Studio One" version="6.5.2"/><Structure><Track contentType="audio" loaded="true" id="id2" name="Keys"><Channel audioChannels="2" role="regular" solo="false" id="id3"><Devices>
    <Vst3Plugin deviceID="d39d5b69-d6af-42fa-1234-567868495645" deviceName="Hive" deviceRole="instrument" deviceVendor="u-he" loaded="true" pluginVersion="2.1.1" id="id4" name="Hive"><Parameters/><Enabled value="true" id="id5" name="On/Off"/><State path="plugins/hive.vstpreset"/></Vst3Plugin>
    <ClapPlugin deviceID="org.surge-synth-team.surge-xt" deviceName="Surge XT" deviceRole="instrument" loaded="true" id="id6" name="Surge XT"><State path="plugins/surge.clap-preset"/></ClapPlugin>
    <Vst2Plugin deviceID="1937337905" deviceName="Sylenth1" deviceRole="instrument" deviceVendor="LennarDigital" loaded="true" id="id7" name="Sylenth1"/>
    <Equalizer deviceName="Pro EQ" deviceRole="audioFX" loaded="true" id="id8"/></Devices></Channel></Track></Structure></Project>
    """

    private func archive() throws -> Data {
        try zipper.zip([("project.xml", Data(studioOneProject.utf8)), ("metadata.xml", Data("<MetaData/>".utf8)),
                        ("plugins/hive.vstpreset", Data(#"VST3....<Hive pluginVersion="2.1.1"/>"#.utf8)), ("plugins/surge.clap-preset", Data("clap".utf8))], deflate: true)
    }

    func testDawprojectClassIDsStateFilesAndApplication() throws {
        let doc = try DawprojectParser.parse(archive())
        XCTAssertEqual(doc.savedWith, "Studio One 6.5.2"); XCTAssertEqual(doc.hostLabel, "Studio One")
        let hive = try XCTUnwrap(doc.plugins.first)
        XCTAssertEqual(hive.classID, "D39D5B69D6AF42FA1234567868495645", "VST3 deviceID is the canonical UUID of the class ID")
        XCTAssertEqual(hive.knownSaved.first?.version, "2.1.1"); XCTAssertEqual(hive.states.count, 1, "the State path points at a file in the archive")
        XCTAssertEqual(doc.plugins[1].format, .clap); XCTAssertEqual(doc.plugins[2].format, .vst); XCTAssertEqual(doc.plugins[3].format, .dawBuiltIn)
        XCTAssertEqual(doc.plugins.map(\.name), ["Hive", "Surge XT", "Sylenth1", "Pro EQ"])
    }

    func testDawprojectMissingStateFileIsIgnored() throws {
        let z = try zipper.zip([("project.xml", Data(studioOneProject.utf8))], deflate: false)
        XCTAssertTrue(try DawprojectParser.parse(z).plugins[0].states.isEmpty)
    }

    // MARK: Native songs

    private func song(_ files: [(String, String)]) throws -> Data { try zipper.zip(files.map { ($0.0, Data($0.1.utf8)) }, deflate: true) }

    private let songXML = #"<?xml version="1.0" encoding="UTF-8"?><Song x:id="Song" xmlns:y="y"><Attributes x:id="a" name="demo"/><AudioDevice x:id="1" deviceName="FabFilter/Pro-Q 4" classID="{D39D5B69-D6AF-42FA-1234-567868495645}"/><ProcessGraph::SlotNode x:id="2"/><AudioDevice deviceName="Pro EQ"/><AudioDevice deviceName="FabFilter/Pro-Q 4"/></Song>"#
    private let mixerXML = #"<?xml version="1.0"?><AudioMixer><Attributes pname="Par défaut"/><AudioTrackChannel label="Gtr"/></AudioMixer>"#
    private let poolXML = #"<?xml version="1.0"?><MediaPool><AudioEffectClipItem x:id="3" name="Soundtoys/EchoBoy" classID="56535453-6f75-6e64-7479-736563686f62"/></MediaPool>"#

    func testNativeSongPluginsFromAllThreeFiles() throws {
        let doc = try StudioOneSongParser.parse(song([("Song/song.xml", songXML), ("Song/mediapool.xml", poolXML), ("Devices/audiomixer.xml", mixerXML), ("metainfo.xml", #"<MetaInformation><Attribute id="Application" text="Studio One 5.5.2"/></MetaInformation>"#)]))
        XCTAssertEqual(doc.plugins.map(\.name), ["Pro-Q 4", "Pro EQ", "EchoBoy"])
        XCTAssertEqual(doc.plugins[0].vendor, "FabFilter"); XCTAssertEqual(doc.plugins[0].classID, "D39D5B69D6AF42FA1234567868495645"); XCTAssertTrue(doc.plugins[0].formatGuess)
        XCTAssertTrue(doc.plugins[1].isHostBuiltIn); XCTAssertEqual(doc.savedVersion, "5.5.2")
        XCTAssertFalse(doc.warnings.isEmpty, "the older layout is flagged as unverified")
    }

    /// Excerpts of a real Studio One 7.2 song (format version 8): plugin slots carry a `classInfo` element.
    private let realMixerXML = """
    <?xml version="1.0" encoding="UTF-8"?><AudioMixer><Attributes x:id="Inserts"><Attributes name="FX01"><Attributes x:id="deviceData" name="iZotope Ozone 5"/>
    <Attributes x:id="ghostData" presetType="fxb"><Attributes x:id="classInfo" classID="{5653545A-6E4F-3569-7A6F-746F7065206F}" name="iZotope Ozone 5" category="AudioEffect" subCategory="VST2"/></Attributes>
    <Attributes x:id="Presets" pname="Par défaut" dirty="0"/></Attributes>
    <Attributes name="FX02"><Attributes x:id="ghostData"><Attributes x:id="classInfo" classID="{D39D5B69-D6AF-42FA-1234-567868495645}" name="Hive" category="AudioSynth" subCategory="VST3"/></Attributes></Attributes>
    <Attributes name="FX03"><Attributes x:id="ghostData"><Attributes x:id="classInfo" classID="{00000000-0000-0000-0000-000000000001}" name="Pro EQ" category="AudioEffect"/></Attributes></Attributes></Attributes></AudioMixer>
    """

    func testRealSongLayoutUsesClassInfoAndIgnoresPresetNames() throws {
        let doc = try StudioOneSongParser.parse(song([("Song/song.xml", "<Song/>"), ("Devices/audiomixer.xml", realMixerXML),
                                                      ("metainfo.xml", #"<MetaInformation><Attribute id="Document:Generator" value="Studio One/7.2.3.108761"/></MetaInformation>"#)]))
        XCTAssertEqual(doc.plugins.map(\.name), ["iZotope Ozone 5", "Hive", "Pro EQ"], "preset names such as 'Par défaut' are not plugins")
        XCTAssertEqual(doc.plugins[0].format, .vst); XCTAssertEqual(doc.plugins[0].ids, "ZnO5", "the VST2 four-character ID is unpacked from the class ID")
        XCTAssertEqual(doc.plugins[1].format, .vst3); XCTAssertEqual(doc.plugins[1].classID, "D39D5B69D6AF42FA1234567868495645")
        XCTAssertTrue(doc.plugins[2].isHostBuiltIn, "no VST/AU sub-category means one of the DAW's own devices")
        XCTAssertEqual(doc.savedVersion, "7.2.3.108761"); XCTAssertTrue(doc.warnings.isEmpty)
    }

    func testBareProjectXMLIsAcceptedAsDawproject() throws {
        let doc = try DawprojectParser.parse(Data(studioOneProject.utf8))
        XCTAssertEqual(doc.plugins.map(\.name), ["Hive", "Surge XT", "Sylenth1", "Pro EQ"])
    }

    func testNativeSongResolvesAgainstInstalledPlugins() throws {
        let fake = try FakeInstall(); try fake.addPlain("FabFilter Pro-Q 4", ext: "vst3", in: fake.vst3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("S1-\(UUID().uuidString).song")
        try song([("Song/song.xml", songXML)]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ProjectScanner.discover(at: url).first?.kind, .studioOne)
        guard case .loaded(let r) = ProjectLoader.load(DiscoveredProject(url: url, kind: .studioOne), index: fake.index()) else { return XCTFail() }
        XCTAssertEqual(r.plugins[0].installedVersion, "1.0"); XCTAssertTrue(r.plugins[0].isUncertain)
    }

    func testNativeSongRejectsOtherArchivesAndSurvivesDamage() throws {
        XCTAssertThrowsError(try StudioOneSongParser.parse(song([("other.xml", "<x/>")])))
        XCTAssertThrowsError(try StudioOneSongParser.parse(Data("not a zip".utf8)))
        let good = try song([("Song/song.xml", songXML), ("Devices/audiomixer.xml", mixerXML)])
        for cut in stride(from: 10, to: good.count, by: 29) { _ = try? StudioOneSongParser.parse(good.prefix(cut)) }
        XCTAssertNoThrow(try StudioOneSongParser.parse(song([("Song/song.xml", "<Song><Broken")])))
    }

    func testCleanRemovesPrefixesButKeepsValues() {
        let out = String(decoding: StudioOneSongParser.clean(Data(#"<a:B::C x:id="1" label="12:30 C:\x"/>"#.utf8)), as: UTF8.self)
        XCTAssertEqual(out, #"<BC id="1" label="12:30 C:\x"/>"#)
    }
}
