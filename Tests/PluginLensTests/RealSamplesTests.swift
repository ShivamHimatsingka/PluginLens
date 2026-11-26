import XCTest
@testable import PluginLens

/// Opt-in regression tests on real project files from public sources (they are not shipped here). Set PLUGINLENS_SAMPLES to a folder laid out as
///   flp/ lmms/ reaper/ ardour/ waveform/ ableton/ cubase/ bitwig/ reason/x_live/ reason/x_logic/ reason/x_pro-tools/ reason/x_reason-standalone/
/// (or write the folder to /tmp/pluginlens_samples). Each test names the file it checks and what that file is known to contain.
final class RealSamplesTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        let p = ProcessInfo.processInfo.environment["PLUGINLENS_SAMPLES"] ?? (try? String(contentsOfFile: "/tmp/pluginlens_samples", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p, !p.isEmpty else { throw XCTSkip("set PLUGINLENS_SAMPLES to the folder of real sample projects") }
        root = URL(fileURLWithPath: p)
    }

    private func load(_ relative: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProjectReport {
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("missing sample \(relative)") }
        let p = try XCTUnwrap(ProjectScanner.discover(at: url).first, "not recognised: \(relative)", file: file, line: line)
        guard case .loaded(let r) = ProjectLoader.load(p, index: InstalledPluginIndex()) else { XCTFail("did not load: \(relative)", file: file, line: line); throw XCTSkip("load failed") }
        return r
    }
    private func plugin(_ r: ProjectReport, _ name: String) -> PluginEntry? { r.plugins.first { $0.name == name } }

    func testProToolsSessionWithTheReasonRackPlugin() throws {
        let r = try load("reason/x_pro-tools/reason-bassline-and-pad-pro-tools/Reason Bassline and Pad.ptx")
        XCTAssertEqual(r.lastSavedFrom, "Pro Tools Ultimate 2019.12.0")
        XCTAssertEqual(r.plugins.map(\.name), ["Reason Rack Plugin"]); XCTAssertEqual(r.plugins.first?.codes, "REAS:RRPL:RRP2"); XCTAssertEqual(r.plugins.first?.format, .aax)
    }

    func testLogicProjectWithTheReasonRackPlugin() throws {
        let r = try load("reason/x_logic/reason-bassline-and-pad-logic/Reason Bassline and Pad.logicx")
        XCTAssertEqual(plugin(r, "Reason Rack")?.codes, "aumf/ReEf/Reas")
    }

    func testAbletonSetWithThirdPartyVST3Plugins() throws {
        let r = try load("reason/x_live/reason-bassline-and-pad-live/Reason Bassline and Pad.als")
        XCTAssertEqual(r.lastSavedFrom, "Ableton Live 10.1.9")
        XCTAssertEqual(plugin(r, "Reason Rack Plugin")?.format, .vst3); XCTAssertEqual(plugin(r, "Reason Rack Plugin Effect")?.format, .vst3)
        XCTAssertEqual(r.plugins.filter { $0.format == .abletonBuiltIn }.count, 2)
    }

    func testFLStudioProjectWithNativeAndWrappedPlugins() throws {
        let r = try load("flp/FL_20.8.4.flp")
        XCTAssertEqual(plugin(r, "Sylenth1")?.format, .vst); XCTAssertEqual(plugin(r, "OTT")?.format, .vst3); XCTAssertEqual(plugin(r, "OTT")?.manufacturer, "Xfer Records")
        XCTAssertNotNil(plugin(r, "BooBass")); XCTAssertNil(plugin(r, "Sampler")); XCTAssertNil(plugin(r, "Layer"), "channel types are not plugins")
        XCTAssertGreaterThanOrEqual(r.plugins.filter { $0.format == .flBuiltIn }.count, 8)
    }

    func testREAPERProjectReadsTheVersionStoredInThePluginState() throws {
        let r = try load("reaper/NAM.rpp")
        XCTAssertEqual(plugin(r, "NeuralAmpModeler")?.savedVersion, "0.7.12"); XCTAssertEqual(r.lastSavedFrom, "REAPER 7.28/macOS-arm64")
    }

    func testBitwigProjects() throws {
        let linux = try load("bitwig/canon.bwproject")
        XCTAssertEqual(plugin(linux, "Space Piano")?.savedVersion, "1.3.0"); XCTAssertEqual(linux.lastSavedFrom, "Bitwig Studio 5.3.13")
        let windows = try load("bitwig/thunder.bwproject")
        XCTAssertEqual(plugin(windows, "RapturePro_64")?.savedVersion, "2.0.5.0"); XCTAssertNotNil(plugin(windows, "EQ-5"))
        let old = try load("bitwig/theme.bwproject")
        XCTAssertEqual(plugin(old, "FM8")?.format, .vst); XCTAssertNotNil(plugin(old, "Peak Limiter"))
    }

    func testLMMSAndWaveformAndArdourProjects() throws {
        let lmms = try load("lmms/DirtyLove.mmpz")
        XCTAssertNotNil(plugin(lmms, "tripleoscillator")); XCTAssertEqual(plugin(lmms, "Reverb")?.format, .ladspa)
        let wf = try load("waveform/undred.tracktionedit")
        XCTAssertEqual(plugin(wf, "mx_tune")?.format, .vst); XCTAssertNotNil(plugin(wf, "Natural Reverb")); XCTAssertNil(plugin(wf, "Volume"), "a track's own volume/level are not listed")
        let ardour = try load("ardour/Moog.ardour")
        XCTAssertEqual(plugin(ardour, "Calf Reverb")?.format, .lv2); XCTAssertNil(plugin(ardour, "Amp"))
    }

    func testCubaseProject() throws {
        let r = try load("cubase/MSDS.cpr")
        XCTAssertEqual(r.lastSavedFrom, "Cubase 10.5.20"); XCTAssertNotNil(plugin(r, "Mystic")); XCTAssertNil(plugin(r, "Standard Panner"), "mixer plumbing is not a plugin")
    }

    func testProjectsWithoutPluginsLoadCleanly() throws {
        for f in ["waveform/default.tracktionedit", "ardour/empty.ardour", "ableton/sonic.als", "cubase/testdata/Example Project (Cubase SX3).cpr"] {
            XCTAssertTrue(try load(f).plugins.isEmpty, f)
        }
    }

    func testReasonSongIsListedWithAnExplanation() throws {
        let url = root.appendingPathComponent("reason/x_reason-standalone/reason-bassline-and-pad-reason-standalone/Reason Bassline and Pad.reason")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("missing sample") }
        guard case .failed(.notSupportedYet) = ProjectLoader.load(try XCTUnwrap(ProjectScanner.discover(at: url).first), index: InstalledPluginIndex()) else { return XCTFail() }
    }
}
