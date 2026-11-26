import XCTest
@testable import PluginLens

/// The older GarageBand layout: `projectData` is a property list (an NSKeyedArchiver archive) whose data blobs hold the same plugin records as Logic's ProjectData.
final class GarageBandLayoutTests: XCTestCase {
    func testPropertyListWrappedRecordsMatchTheBareFile() throws {
        let bare = try Fixtures.data("mixed_missing")
        let plist: [String: Any] = ["$objects": ["$null", ["blob": bare, "other": Data([1, 2, 3])], ["list": [bare]]]]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let wrapped = try ProjectDataParser.parseAny(xml)
        let direct = try ProjectDataParser.parse(bare)
        XCTAssertEqual(wrapped.records.map(\.key), direct.records.map(\.key), "duplicate blobs are merged, not listed twice")
        XCTAssertEqual(wrapped.records.first?.count, (direct.records.first?.count ?? 0) * 2)
    }

    func testPropertyListWithoutProjectBlocksIsRejected() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["a": "b"], format: .xml, options: 0)
        XCTAssertThrowsError(try ProjectDataParser.parseAny(xml))
        XCTAssertThrowsError(try ProjectDataParser.parseAny(Data("<?xml broken".utf8)))
    }
}
