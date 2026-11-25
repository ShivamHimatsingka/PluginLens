import Foundation

/// Extracts plugin records from a Logic Pro `ProjectData` file.
///
/// The format is undocumented. This parser relies only on what Phase 1 verified
/// (see PHASE1_FINDINGS.md): a magic header, and plugin instance records laid out as
///
///     [flags: 2 bytes, each 0x01 or 0x02][name: 12 bytes, NUL padded][manufacturer: 4][type: 4][subtype: 4] ...
///
/// with the three codes stored byte-reversed. Logic built-ins use the same layout but the
/// manufacturer slot holds the ASCII bytes "GAME" and no type/subtype follow.
enum ProjectDataParser {
    static let magic: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    static let minimumSize = 64
    static let auTypes: Set<String> = ["aufx", "aumu", "aumf", "aumi"]
    static let nameFieldLength = 12
    private static let builtInMarker: [UInt8] = Array("GAME".utf8)

    static func parse(_ data: Data) throws -> ParseResult {
        guard data.count >= minimumSize else {
            throw ProjectError.corrupt("ProjectData is only \(data.count) bytes long")
        }
        let b = [UInt8](data)
        guard Array(b[0..<4]) == magic else {
            let head = b[0..<4].map { String(format: "%02x", $0) }.joined()
            throw ProjectError.unsupportedFormat("unexpected header bytes \(head) (expected 2347c0ab)")
        }

        var order: [String] = []
        var found: [String: RawPluginRecord] = [:]
        func add(_ r: RawPluginRecord) {
            if var existing = found[r.key] {
                existing.count += 1
                found[r.key] = existing
            } else {
                order.append(r.key)
                found[r.key] = r
            }
        }

        let n = b.count
        var i = nameFieldLength + 6  // earliest position where a type/marker could sit
        while i + 8 <= n {
            let c = b[i]
            // Reversed AU types start with x(fx) u(mu) f(mf) i(mi); the built-in marker starts with G.
            if c == 0x78 || c == 0x75 || c == 0x66 || c == 0x69, let r = audioUnitRecord(b, typeAt: i) {
                add(r)
                i += 8
                continue
            }
            if c == 0x47, let r = builtInRecord(b, markerAt: i) {
                add(r)
                i += 4
                continue
            }
            i += 1
        }
        return ParseResult(records: order.compactMap { found[$0] }, warnings: [])
    }

    // MARK: Record readers

    private static func audioUnitRecord(_ b: [UInt8], typeAt t: Int) -> RawPluginRecord? {
        let nameStart = t - 16
        guard nameStart >= 2, t + 8 <= b.count else { return nil }
        let type = reversedString(b[t..<t + 4])
        guard auTypes.contains(type) else { return nil }
        let mfrBytes = b[t - 4..<t], subBytes = b[t + 4..<t + 8]
        guard isPrintable(mfrBytes), isPrintable(subBytes) else { return nil }
        guard let name = readName(b, at: nameStart) else { return nil }
        return RawPluginRecord(kind: .audioUnit, name: name,
                               manufacturer: reversedString(mfrBytes), type: type,
                               subtype: reversedString(subBytes), count: 1, firstOffset: nameStart)
    }

    private static func builtInRecord(_ b: [UInt8], markerAt m: Int) -> RawPluginRecord? {
        let nameStart = m - nameFieldLength
        guard nameStart >= 2, m + 4 <= b.count else { return nil }
        guard Array(b[m..<m + 4]) == builtInMarker else { return nil }
        guard let name = readName(b, at: nameStart) else { return nil }
        return RawPluginRecord(kind: .builtIn, name: name, manufacturer: "GAME", type: "", subtype: "",
                               count: 1, firstOffset: nameStart)
    }

    /// Validates the 2 flag bytes and the 12-byte name field; returns the name or nil if this isn't a record.
    private static func readName(_ b: [UInt8], at start: Int) -> String? {
        guard (1...2).contains(b[start - 2]), (1...2).contains(b[start - 1]) else { return nil }
        let field = b[start..<start + nameFieldLength]
        guard let nul = field.firstIndex(of: 0), nul > start else { return nil }
        let text = b[start..<nul]
        guard isPrintable(text), let first = text.first, isAlphanumeric(first) else { return nil }
        guard b[nul..<start + nameFieldLength].allSatisfy({ $0 == 0 }) else { return nil }
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static func isPrintable(_ s: ArraySlice<UInt8>) -> Bool {
        s.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
    }
    private static func isAlphanumeric(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }
    private static func reversedString(_ s: ArraySlice<UInt8>) -> String {
        String(decoding: Array(s.reversed()), as: UTF8.self)
    }
}
