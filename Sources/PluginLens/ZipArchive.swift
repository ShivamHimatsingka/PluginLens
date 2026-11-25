import Foundation

/// A small read-only ZIP reader (stored and deflated entries, no ZIP64, no encryption).
struct ZipArchive {
    struct Entry { var name: String; var method: UInt16; var compressedSize: Int; var size: Int; var localOffset: Int }
    let data: Data
    /// Bytes in front of the archive (zero for a normal ZIP; Bitwig projects carry a ZIP at the end of the file).
    private(set) var base = 0
    private(set) var entries: [Entry] = []
    static let maxEntrySize = 512 * 1024 * 1024

    init(_ data: Data) throws {
        self.data = data
        let b = data
        guard b.count >= 22 else { throw ProjectError.corrupt("the archive is only \(b.count) bytes long") }
        // End of central directory record: scan backwards over at most a 64 KB comment.
        var eocd = -1
        var i = b.count - 22
        let lowest = max(0, b.count - 22 - 65535)
        while i >= lowest {
            if Self.u32(b, i) == 0x06054B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ProjectError.unsupportedFormat("not a ZIP archive") }
        let count = Int(Self.u16(b, eocd + 10)), cdOffset = Int(Self.u32(b, eocd + 16))
        guard count != 0xFFFF, cdOffset != 0xFFFF_FFFF else { throw ProjectError.unsupportedFormat("ZIP64 archives are not supported") }
        let cdSize = Int(Self.u32(b, eocd + 12))
        base = max(0, eocd - cdSize - cdOffset)
        var p = base + cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, Self.u32(b, p) == 0x02014B50 else { throw ProjectError.corrupt("the archive's directory is damaged") }
            let method = Self.u16(b, p + 10), csize = Int(Self.u32(b, p + 20)), usize = Int(Self.u32(b, p + 24))
            let nlen = Int(Self.u16(b, p + 28)), elen = Int(Self.u16(b, p + 30)), clen = Int(Self.u16(b, p + 32)), off = Int(Self.u32(b, p + 42))
            guard p + 46 + nlen <= b.count else { throw ProjectError.corrupt("the archive's directory is damaged") }
            let name = String(decoding: b[(b.startIndex + p + 46)..<(b.startIndex + p + 46 + nlen)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: csize, size: usize, localOffset: off))
            p += 46 + nlen + elen + clen
        }
    }

    func has(_ name: String) -> Bool { entries.contains { $0.name == name } }

    func read(_ name: String) throws -> Data {
        guard let e = entries.first(where: { $0.name == name }) else { throw ProjectError.corrupt("\(name) is missing from the archive") }
        guard e.size <= Self.maxEntrySize, e.compressedSize <= Self.maxEntrySize else { throw ProjectError.unsupportedFormat("\(name) is unreasonably large") }
        let o = base + e.localOffset
        guard o + 30 <= data.count, Self.u32(data, o) == 0x04034B50 else { throw ProjectError.corrupt("\(name) has a damaged header") }
        let start = o + 30 + Int(Self.u16(data, o + 26)) + Int(Self.u16(data, o + 28))
        guard start + e.compressedSize <= data.count else { throw ProjectError.corrupt("\(name) runs past the end of the archive") }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8:
            guard let out = try? (raw as NSData).decompressed(using: .zlib) as Data else { throw ProjectError.corrupt("\(name) could not be decompressed") }
            return out
        default: throw ProjectError.unsupportedFormat("\(name) uses compression method \(e.method)")
        }
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
}
