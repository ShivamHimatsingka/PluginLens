import Foundation
import XCTest
import SQLite3
@testable import PluginLens

private final class BundleToken {}

enum Fixtures {
    static func file(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") ?? bundle.url(forResource: name, withExtension: ext)
        return try Data(contentsOf: XCTUnwrap(url, "missing fixture \(name).\(ext)"))
    }

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.url(forResource: name, withExtension: "projectdata", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "projectdata")
        return try Data(contentsOf: XCTUnwrap(url, "missing fixture \(name)"))
    }
}

/// Builds synthetic ProjectData with the record layout documented in PHASE1_FINDINGS.md.
enum RecordBuilder {
    static func header(padTo size: Int = 64) -> Data {
        var d = Data([0x23, 0x47, 0xC0, 0xAB])
        d.append(Data(count: size - 4))
        return d
    }

    private static func reversed(_ s: String) -> Data { Data(Array(s.utf8).reversed()) }

    static func name(_ s: String) -> Data {
        var d = Data(s.utf8.prefix(11))
        d.append(Data(count: 12 - d.count))
        return d
    }

    static func au(name n: String, manufacturer: String, type: String, subtype: String, flags: [UInt8] = [2, 2]) -> Data {
        var d = Data(count: 24)
        d.append(contentsOf: flags)
        d.append(name(n))
        d.append(reversed(manufacturer)); d.append(reversed(type)); d.append(reversed(subtype))
        d.append(Data(count: 16))
        return d
    }

    static func builtIn(name n: String) -> Data {
        var d = Data(count: 24)
        d.append(contentsOf: [2, 2])
        d.append(name(n))
        d.append(Data("GAME".utf8))
        d.append(Data(count: 20))
        return d
    }

    static func project(_ records: [Data]) -> Data {
        var d = header()
        for r in records { d.append(r) }
        d.append(Data(count: 64))
        return d
    }
}

/// Creates fake installed plugin bundles in a temporary directory tree.
final class FakeInstall {
    let root: URL
    var au: URL { root.appendingPathComponent("Components") }
    var vst: URL { root.appendingPathComponent("VST") }
    var vst3: URL { root.appendingPathComponent("VST3") }
    var aax: URL { root.appendingPathComponent("AAX") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginLensTests-\(UUID().uuidString)")
        for d in [au, vst, vst3, aax] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var directories: SearchDirectories { var d = SearchDirectories(audioUnits: [au], vst: [vst], vst3: [vst3]); d.aax = [aax]; return d }

    @discardableResult
    func addComponent(_ bundleName: String, in dir: URL? = nil, short: String? = nil, build: String? = nil,
                      type: String, subtype: String, manufacturer: String, name: String) throws -> URL {
        let bundle = (dir ?? au).appendingPathComponent("\(bundleName).component")
        try write(bundle, short: short, build: build, components: [[
            "type": type, "subtype": subtype, "manufacturer": manufacturer, "name": name, "version": 65536,
        ]])
        return bundle
    }

    @discardableResult
    func addPlain(_ bundleName: String, ext: String, in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("\(bundleName).\(ext)")
        try write(bundle, short: "1.0", build: nil, components: [])
        return bundle
    }

    private func write(_ bundle: URL, short: String?, build: String?, components: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "test.\(bundle.lastPathComponent)"]
        if let short { plist["CFBundleShortVersionString"] = short }
        if let build { plist["CFBundleVersion"] = build }
        if !components.isEmpty { plist["AudioComponents"] = components }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    /// Writes `<root>/Apps/<app>.app/Contents/PlugIns/<appex>.appex` declaring an AUv3 component.
    func addAUv3(app: String, type: String, subtype: String, manufacturer: String, name: String, version: String) throws {
        let appex = root.appendingPathComponent("Apps/\(app).app/Contents/PlugIns/Ext.appex/Contents")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "NSExtension": ["NSExtensionAttributes": ["AudioComponents": [
            ["type": type, "subtype": subtype, "manufacturer": manufacturer, "name": name]]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: appex.appendingPathComponent("Info.plist"))
    }

    func index(logicVersion: String? = "12.2", logicNames: [String] = [], abletonNames: [String: String] = [:]) -> InstalledPluginIndex {
        InstalledPluginIndex(directories: { var d = directories; d.applications = [root.appendingPathComponent("Apps")]; return d }(), logicVersion: logicVersion,
                             abletonVersion: nil, logicPluginNames: logicNames, abletonDeviceNames: abletonNames)
    }
}

/// Builds Ableton Live sets (gzip-compressed XML) for tests.
enum AbletonSetBuilder {
    static func gzip(_ xml: String) throws -> Data {
        let raw = try (Data(xml.utf8) as NSData).compressed(using: .zlib) as Data
        var d = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]); d.append(raw); d.append(Data(count: 8))   // trailer (CRC, size) is ignored by the reader
        return d
    }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }

    static func set(creator: String = "Ableton Live 12.1", major: String = "5", devices: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MajorVersion="\(major)" MinorVersion="12.0_12117" SchemaChangeCount="3" Creator="\(creator)" Revision="x">
          <LiveSet><Tracks><AudioTrack Id="1"><DeviceChain><DeviceChain><Devices>
            \(devices)
          </Devices></DeviceChain></DeviceChain></AudioTrack></Tracks></LiveSet>
        </Ableton>
        """
    }

    static func vst3(name: String, uid: [Int], state: Data? = nil) -> String {
        """
        <PluginDevice Id="2"><PluginDesc><Vst3PluginInfo Id="0"><Name Value="\(name)"/>
        <Uid><Fields.0 Value="\(uid[0])"/><Fields.1 Value="\(uid[1])"/><Fields.2 Value="\(uid[2])"/><Fields.3 Value="\(uid[3])"/></Uid>
        <Preset><Vst3Preset Id="0"><Name Value="preset name"/><ProcessorState>\(state.map(hex) ?? "")</ProcessorState></Vst3Preset></Preset>
        </Vst3PluginInfo></PluginDesc></PluginDevice>
        """
    }

    static func au(name: String, manufacturer: String, state: Data?) -> String {
        """
        <AuPluginDevice Id="3"><PluginDesc><AuPluginInfo Id="0"><Name Value="\(name)"/><Manufacturer Value="\(manufacturer)"/>
        <Preset><AuPreset Id="0"><Buffer>\(state.map(hex) ?? "")</Buffer></AuPreset></Preset></AuPluginInfo></PluginDesc></AuPluginDevice>
        """
    }

    /// A Live plugin database with the given (identifier, name, vendor, version) rows.
    static func database(in dir: URL, number: Int = 1, rows: [(String, String, String, String)]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Live-plugins-\(number).db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE plugins (plugin_id INTEGER PRIMARY KEY, module_id INTEGER, dev_identifier TEXT, name TEXT, vendor TEXT, version TEXT)", nil, nil, nil)
        for r in rows {
            sqlite3_exec(db, "INSERT INTO plugins (dev_identifier,name,vendor,version) VALUES ('\(r.0)','\(r.1)','\(r.2)','\(r.3)')", nil, nil, nil)
        }
    }
}
