import XCTest
@testable import PluginLens

/// Opt-in check against the public Cubase test projects of github.com/fgimian/cubase-project-plugins (MIT), which ship with the plugin list
/// each project is known to contain. Set PLUGINLENS_CUBASE_TESTDATA (or write the folder to /tmp/pluginlens_cubase_testdata) to run it.
final class CubaseGroundTruthTests: XCTestCase {
    private struct Case { let file: String; let version: String; let channelPlugins: Bool; let dither: String }
    private let cases = [
        Case(file: "Example Project (Cubase 4.5 32-bit).cpr", version: "4.5.2", channelPlugins: false, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 4.5 64-bit).cpr", version: "4.5.2", channelPlugins: false, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 5 64-bit).cpr", version: "5.5.3", channelPlugins: false, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 6.5 64-bit).cpr", version: "6.5.5", channelPlugins: false, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 7 64-bit).cpr", version: "7.0.7", channelPlugins: true, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 8.5 64-bit).cpr", version: "8.5.30", channelPlugins: true, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 9.5).cpr", version: "9.5.50", channelPlugins: true, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 11).cpr", version: "11.0.41", channelPlugins: true, dither: "UV22HR"),
        Case(file: "Example Project (Cubase 13).cpr", version: "13.0.10", channelPlugins: true, dither: "Lin Dither"),
        Case(file: "Example Project (Cubase 14).cpr", version: "14.0.30", channelPlugins: true, dither: "Lin Dither"),
    ]

    func testPluginListsMatchTheKnownContentsOfRealCubaseProjects() throws {
        let dir = ProcessInfo.processInfo.environment["PLUGINLENS_CUBASE_TESTDATA"] ?? (try? String(contentsOfFile: "/tmp/pluginlens_cubase_testdata", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dir, !dir.isEmpty else { throw XCTSkip("set PLUGINLENS_CUBASE_TESTDATA to a folder holding the fgimian/cubase-project-plugins testdata") }
        for c in cases {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(c.file)
            guard let data = try? Data(contentsOf: url) else { XCTFail("missing \(c.file)"); continue }
            let doc = try CubaseParser.parse(data)
            XCTAssertEqual(doc.savedVersion, c.version, c.file)
            // The tool's expected list, minus the mixer plumbing this app deliberately hides ("Standard Panner", "Input Filter").
            var expected: [String: String] = [
                "1C3A662167D347A99F7D797EA4911CDB": "Elephant", "565354414152626172747361636F7573": "ArtsAcousticReverb", "565354416D62726F6D6E697370686572": "Omnisphere",
                "56535444475443747261636B636F6D70": "TrackComp", "56535455564852757632326872000000": c.dither, "56535473796C3173796C656E74683100": "Sylenth1",
                "77BBA7CA90F14C9BB298BA9010D6DD78": "StereoEnhancer", "946051208E29496E804F64A825C8A047": "StudioEQ", "D39D5B69D6AF42FA1234567868495645": "Hive",
            ]
            if c.channelPlugins { expected["297BA567D83144E1AE921DEF07B41156"] = "EQ" }
            let actual = Dictionary(uniqueKeysWithValues: doc.plugins.compactMap { p in p.classID.map { ($0, p.name) } })
            XCTAssertEqual(actual, expected, c.file)
        }
        // SX3 predates plugin entries in this form: header only.
        if let sx3 = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("Example Project (Cubase SX3).cpr")) {
            let doc = try CubaseParser.parse(sx3)
            XCTAssertEqual(doc.savedVersion, "3.1.1"); XCTAssertEqual(doc.savedWith, "Cubase SX 3.1.1"); XCTAssertTrue(doc.plugins.isEmpty)
        }
    }

    func testVST2WrapperClassIDsDecodeToTheVST2IDAndName() {
        let sylenth = CubaseParser.vst2Wrapper("56535473796C3173796C656E74683100")
        XCTAssertEqual(sylenth?.id, "syl1"); XCTAssertEqual(sylenth?.name, "sylenth1")
        XCTAssertNil(CubaseParser.vst2Wrapper("D39D5B69D6AF42FA1234567868495645"), "a plain VST3 class ID is not a wrapper")
    }

    func testRenamedInstrumentTracksReportTheOriginalPluginName() throws {
        func tok(_ s: String) -> [UInt8] { [UInt8(s.utf8.count + 1)] + Array(s.utf8) + [0] }
        var b: [UInt8] = Array("RIFF".utf8) + [0, 0, 1, 0] + Array("NUND".utf8) + Array("ROOT".utf8) + [0, 0, 0, 0x20]
        b += Array("PAppVersion\0".utf8) + [UInt8](repeating: 0, count: 9) + tok("Cubase") + [0, 0, 0] + tok("Version 12.0.5") + [0, 0, 0] + tok("Jan  1 2022") + [UInt8](repeating: 0, count: 7) + tok("WIN64")
        b += Array("Plugin isA\0".utf8) + [0, 0, 0, 0] + tok("VstCtrlInternalEffect") + [0, 0, 0, 0]
        b += Array("Plugin UID\0".utf8) + [UInt8](repeating: 0, count: 22) + tok("D39D5B69D6AF42FA1234567868495645") + [0, 0, 0] + tok("Plugin Name") + [0, 0, 0, 0, 0] + tok("My Lead Track") + [0, 0, 0]
        b += tok("Original Plugin Name") + [0, 0, 0, 0, 0] + tok("Hive") + [UInt8](repeating: 0, count: 32)
        let doc = try CubaseParser.parse(Data(b))
        XCTAssertEqual(doc.savedWith, "Cubase 12.0.5"); XCTAssertEqual(doc.plugins.map(\.name), ["Hive"])
    }
}
