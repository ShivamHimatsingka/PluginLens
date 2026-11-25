import Foundation
import XCTest
@testable import PluginLens

private final class BundleToken {}

enum Fixtures {
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

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginLensTests-\(UUID().uuidString)")
        for d in [au, vst, vst3] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var directories: SearchDirectories { SearchDirectories(audioUnits: [au], vst: [vst], vst3: [vst3]) }

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

    func index(logicVersion: String? = "12.2") -> InstalledPluginIndex {
        InstalledPluginIndex(directories: SearchDirectories(audioUnits: [au], vst: [vst], vst3: [vst3], applications: [root.appendingPathComponent("Apps")]), logicVersion: logicVersion)
    }
}
