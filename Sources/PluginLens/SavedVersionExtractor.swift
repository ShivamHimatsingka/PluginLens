import Foundation

/// A plugin version found inside a plugin's saved state in ProjectData: the version of the plugin that was
/// running when the project was last saved.
struct SavedVersion: Hashable, Sendable {
    var version: String
    /// Which convention it was read from, e.g. `pluginVersion attribute`.
    var source: String
}

/// Logic stores each plugin's AU state as an embedded XML plist (`type`, `subtype`, `manufacturer`, plus the plugin's own
/// state blobs). There is no universal version field: the plist's `version` key is the AU state-format version and is
/// almost always 0. Some plugins, however, write their own version into their state. This extractor looks for the
/// conventions seen in real projects, and reports nothing for plugins that don't store a version.
enum SavedVersionExtractor {
    /// (needle, label, required byte after the value, must the byte before the needle be a non-letter)
    private struct Pattern { let needle: String; let source: String; let terminators: Set<UInt8>; let boundary: Bool }
    private static let patterns: [Pattern] = [
        Pattern(needle: "pluginVersion=\"", source: "pluginVersion attribute", terminators: [0x22], boundary: false),
        Pattern(needle: "\"productVersion\":\"", source: "productVersion field", terminators: [0x22], boundary: false),
        Pattern(needle: "PlugVersion ", source: "PlugVersion line", terminators: [0x0A, 0x0D, 0x20], boundary: false),
        Pattern(needle: "Version=\"", source: "Version attribute", terminators: [0x22], boundary: true),
    ]
    private static let maxScan = 8 * 1024 * 1024

    /// Every embedded plugin-state plist in the file, keyed by the same key as `RawPluginRecord.key`.
    static func extract(from data: Data) -> [String: [SavedVersion]] {
        var result: [String: [SavedVersion]] = [:]
        let start = Data("<?xml".utf8), end = Data("</plist>".utf8)
        var cursor = data.startIndex
        while let s = data.range(of: start, in: cursor..<data.endIndex) {
            guard let e = data.range(of: end, in: s.lowerBound..<data.endIndex) else { break }
            cursor = e.upperBound
            guard let plist = (try? PropertyListSerialization.propertyList(from: data.subdata(in: s.lowerBound..<e.upperBound), format: nil)) as? [String: Any],
                  let t = plist["type"] as? Int, let sub = plist["subtype"] as? Int, let man = plist["manufacturer"] as? Int
            else { continue }
            let key = "au:\(fourCC(t))/\(fourCC(sub))/\(fourCC(man))"
            for value in plist.values {
                let blob: Data
                if let d = value as? Data { blob = d } else if let str = value as? String { blob = Data(str.utf8) } else { continue }
                if let v = find(in: blob) {
                    var list = result[key] ?? []
                    if !list.contains(v) { list.append(v) }
                    result[key] = list
                    break
                }
            }
        }
        return result
    }

    static func find(in blob: Data) -> SavedVersion? {
        let hay = blob.count > maxScan ? blob.prefix(maxScan) : blob
        for p in patterns {
            var from = hay.startIndex
            let needle = Data(p.needle.utf8)
            while let r = hay.range(of: needle, in: from..<hay.endIndex) {
                from = r.upperBound
                if p.boundary, r.lowerBound > hay.startIndex {
                    let prev = hay[hay.index(before: r.lowerBound)]
                    if (0x41...0x5A).contains(prev) || (0x61...0x7A).contains(prev) { continue }
                }
                var bytes: [UInt8] = []
                var i = r.upperBound
                while i < hay.endIndex, bytes.count < 24, !p.terminators.contains(hay[i]) { bytes.append(hay[i]); i = hay.index(after: i) }
                if let v = String(bytes: bytes, encoding: .utf8), isDottedVersion(v) { return SavedVersion(version: v, source: p.source) }
            }
        }
        return nil
    }

    /// "2.0.5", "1.3", "10.0.0.1": digits separated by dots, at least one dot. Bare integers are too ambiguous.
    static func isDottedVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    static func fourCC(_ n: Int) -> String {
        let u = UInt32(truncatingIfNeeded: n)
        return String(decoding: [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)], as: UTF8.self)
    }

    /// Compares dotted versions numerically. nil if either side isn't dotted-numeric.
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        func nums(_ s: String) -> [Int]? {
            let head = s.split(separator: " ").first.map(String.init) ?? s
            let p = head.split(separator: ".").map { Int($0) }
            return p.contains(where: { $0 == nil }) || p.isEmpty ? nil : p.compactMap { $0 }
        }
        guard var x = nums(a), var y = nums(b) else { return nil }
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        for (l, r) in zip(x, y) where l != r { return l < r ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}
