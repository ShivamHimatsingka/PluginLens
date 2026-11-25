import XCTest
@testable import PluginLens

final class ParserTests: XCTestCase {

    // MARK: Real-record fixtures (stripped of everything but the plugin records)

    func testRealFixtureDecodesKnownPlugins() throws {
        let result = try ProjectDataParser.parse(Fixtures.data("modern_rock_ballad"))
        let au = result.records.filter { $0.kind == .audioUnit }
        let byName = Dictionary(uniqueKeysWithValues: au.map { ($0.name, $0) })

        let proQ = try XCTUnwrap(byName["Pro-Q 4"])
        XCTAssertEqual([proQ.type, proQ.subtype, proQ.manufacturer], ["aumf", "FQ4p", "FabF"])
        let valhalla = try XCTUnwrap(byName["ValhallaRoo"])
        XCTAssertEqual([valhalla.type, valhalla.subtype, valhalla.manufacturer], ["aufx", "Ruum", "oDin"])
        let uad = try XCTUnwrap(byName["UADx Pure P"])
        XCTAssertEqual([uad.type, uad.subtype, uad.manufacturer], ["aufx", "U3C2", "UADx"])
    }

    func testRealFixtureDeduplicatesRepeatedRecords() throws {
        let result = try ProjectDataParser.parse(Fixtures.data("modern_rock_ballad"))
        let keys = result.records.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "records must be unique per plugin")
        let proQ = try XCTUnwrap(result.records.first { $0.name == "Pro-Q 4" })
        XCTAssertGreaterThan(proQ.count, 1, "the source project has several Pro-Q 4 instances")
    }

    func testRealFixtureFindsBuiltIns() throws {
        let result = try ProjectDataParser.parse(Fixtures.data("modern_rock_ballad"))
        let builtIns = result.records.filter { $0.kind == .builtIn }.map(\.name)
        XCTAssertTrue(builtIns.contains("Compressor"), "built-ins: \(builtIns)")
        XCTAssertTrue(builtIns.contains("Limiter"))
    }

    func testAllFixturesParse() throws {
        for name in ["modern_rock_ballad", "guitar_rig", "mixed_missing"] {
            let r = try ProjectDataParser.parse(Fixtures.data(name))
            XCTAssertFalse(r.records.isEmpty, name)
        }
    }

    // MARK: Synthetic edge cases

    func testSyntheticRecordRoundTrip() throws {
        let d = RecordBuilder.project([
            RecordBuilder.au(name: "Some Long Plugin Name", manufacturer: "Acme", type: "aufx", subtype: "Abcd"),
            RecordBuilder.au(name: "Synth", manufacturer: "-NI-", type: "aumu", subtype: "NiK8", flags: [1, 2]),
            RecordBuilder.builtIn(name: "St-Delay"),
        ])
        let r = try ProjectDataParser.parse(d).records
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].name, "Some Long P", "names are truncated to 11 characters by Logic")
        XCTAssertEqual(r[0].codes, "aufx/Abcd/Acme")
        XCTAssertEqual(r[1].manufacturer, "-NI-")
        XCTAssertEqual(r[2].kind, .builtIn)
    }

    func testRejectsLookalikeBytesInBlobs() throws {
        // "aufx" bytes with garbage where the name should be must not produce a plugin.
        var junk = Data(count: 24)
        junk.append(contentsOf: [2, 2])
        junk.append(Data("dS29CRV0dDuy".utf8))          // 12 chars, no NUL terminator
        junk.append(Data("abcdxfuaefgh".utf8) + Data(count: 16))   // manufacturer, reversed "aufx", subtype
        let noFlags = RecordBuilder.au(name: "NoFlags", manufacturer: "Acme", type: "aufx", subtype: "Abcd", flags: [7, 9])
        let binaryName = Data(count: 24) + Data([2, 2, 0x01, 0xFF, 0x80, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]) // control bytes
        let d = RecordBuilder.project([junk, noFlags, binaryName])
        XCTAssertTrue(try ProjectDataParser.parse(d).records.isEmpty)
    }

    func testProjectWithNoPluginsIsValid() throws {
        let r = try ProjectDataParser.parse(RecordBuilder.project([]))
        XCTAssertTrue(r.records.isEmpty)
    }

    // MARK: Failure handling

    func testWrongMagicIsUnsupported() {
        var d = RecordBuilder.header(padTo: 256)
        d[0] = 0x62 // "bplist..."-ish
        XCTAssertThrowsError(try ProjectDataParser.parse(d)) {
            guard case ProjectError.unsupportedFormat = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testTinyFileIsCorrupt() {
        XCTAssertThrowsError(try ProjectDataParser.parse(Data([0x23, 0x47]))) {
            guard case ProjectError.corrupt = $0 else { return XCTFail("got \($0)") }
        }
        XCTAssertThrowsError(try ProjectDataParser.parse(Data()))
    }

    func testTruncatedFileKeepsEarlierRecordsAndNeverCrashes() throws {
        let full = try Fixtures.data("modern_rock_ballad")
        let complete = try ProjectDataParser.parse(full).records.count
        for fraction in stride(from: 0.1, through: 0.95, by: 0.05) {
            let cut = full.prefix(max(64, Int(Double(full.count) * fraction)))
            let r = try ProjectDataParser.parse(Data(cut))   // must not throw or trap
            XCTAssertLessThanOrEqual(r.records.count, complete)
        }
        // Cut in the middle of a record: the partial record is dropped, not misread.
        let rec = RecordBuilder.au(name: "Pro-Q 4", manufacturer: "FabF", type: "aumf", subtype: "FQ4p")
        let partial = RecordBuilder.header() + rec.prefix(rec.count - 20)
        XCTAssertTrue(try ProjectDataParser.parse(partial).records.isEmpty)
    }

    func testRandomGarbageNeverCrashes() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var d = Data([0x23, 0x47, 0xC0, 0xAB])
            d.append(contentsOf: (0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try ProjectDataParser.parse(d)
        }
    }

    func testGhostFixtureHasAnUninstalledPlugin() throws {
        let records = try ProjectDataParser.parse(Fixtures.data("mixed_missing")).records
        let ghost = try XCTUnwrap(records.first { $0.manufacturer == "Zzzz" })
        let entry = PluginResolver.resolve(ghost, index: FakeInstallIndex.empty)
        XCTAssertEqual(entry.status, .notInstalled)
        XCTAssertGreaterThan(records.count, 5)
    }
}
