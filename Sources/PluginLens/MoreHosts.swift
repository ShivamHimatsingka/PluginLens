import Foundation

// MARK: - FL Studio

/// FL Studio projects (`.flp`) are a stream of typed events after an `FLhd` / `FLdt` header:
///
///     event id < 64:   1 data byte     64...127: 2 bytes     128...191: 4 bytes
///     event id >= 192: a variable-length size (7 bits per byte, low bits first), then that many bytes
///
/// Text events hold ASCII or UTF-16LE strings. The ones used here:
/// 199 = FL Studio version, 201 = a plugin's internal name ("Sytrus", "Fruity Wrapper"), 203 = its display name,
/// 212/213 = plugin state. Third-party VST/AU plugins are always hosted in "Fruity Wrapper", whose state contains the plugin file's path.
enum FLStudioParser {
    static let maxState = 16 * 1024 * 1024

    static func parse(_ data: Data) throws -> HostDocument {
        let b = [UInt8](data)
        guard b.count >= 22 else { throw ProjectError.corrupt("the project is only \(b.count) bytes long") }
        guard Array(b[0..<4]) == Array("FLhd".utf8) else { throw ProjectError.unsupportedFormat("the file does not start with FLhd") }
        guard Array(b[14..<18]) == Array("FLdt".utf8) else { throw ProjectError.corrupt("the FLdt chunk is missing") }
        var warnings: [String] = []
        var i = 22
        let declared = Int(le32(b, 18))
        let end = min(b.count, 22 + declared)
        if 22 + declared > b.count { warnings.append("The project file is shorter than it declares; the end may be missing.") }

        var version: String?
        var groups: [(internal: String, name: String?, states: [Data], hasPluginData: Bool)] = []
        while i < end {
            let id = Int(b[i]); i += 1
            var size = 0
            switch id {
            case ..<64: size = 1
            case ..<128: size = 2
            case ..<192: size = 4
            default:
                var shift = 0
                while i < end {
                    let byte = Int(b[i]); i += 1
                    size |= (byte & 0x7F) << shift; shift += 7
                    if byte & 0x80 == 0 { break }
                    if shift > 28 { break }
                }
            }
            guard size >= 0, i + size <= b.count else { warnings.append("An event runs past the end of the file; reading stopped there."); break }
            let payload = id >= 192 ? Array(b[i..<i + size]) : []
            i += size
            switch id {
            case 199: version = text(payload)
            case 201: groups.append((text(payload), nil, [], false))
            case 203: if !groups.isEmpty, groups[groups.count - 1].name == nil { groups[groups.count - 1].name = text(payload) }
            case 212, 213:
                if !groups.isEmpty {
                    if id == 213 { groups[groups.count - 1].hasPluginData = true }
                    if payload.count <= maxState { groups[groups.count - 1].states.append(Data(payload)) }
                }
            default: break
            }
        }

        var found: [FoundPlugin] = []
        // A plugin carries plugin data (event 213); channel types such as samplers, layers and clips do not.
        for g in groups where g.hasPluginData {
            if g.internal == "Fruity Wrapper" {
                // Wrapper state: u32 type (8 or 10), then chunks of { u32 id, u64 size, bytes }:
                // 51 = VST2 four-character ID, 53 = the plugin's own state, 54 = name, 55 = plugin path, 56 = vendor.
                let chunks = g.states.compactMap { wrapperChunks($0) }.first
                let name = chunks?[54].map(string) ?? ""
                let path = chunks?[55].map(string) ?? g.states.flatMap { pluginPaths(in: $0) }.first
                let file = path.map { $0.replacingOccurrences(of: "\\", with: "/") }.map { ($0 as NSString).lastPathComponent }
                let ext = file.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
                var p = FoundPlugin(format: .vst, name: !name.isEmpty ? name : (g.name ?? file.map { ($0 as NSString).deletingPathExtension } ?? "Wrapped plugin"),
                                    vendor: chunks?[56].map(string).flatMap { $0.isEmpty ? nil : $0 }, fileName: file,
                                    states: chunks?[53].map { [$0] } ?? g.states)
                switch ext {
                case "vst3": p.format = .vst3
                case "component": p.format = .au
                case "clap": p.format = .clap
                case "vst", "dll": p.format = .vst
                default:
                    if chunks?[51] != nil { p.format = .vst } else { p.formatGuess = true }   // VST2 plugins carry a four-character ID; VST3/AU do not
                }
                found.append(p)
            } else {
                found.append(FoundPlugin(format: .flBuiltIn, name: g.internal, vendor: "Image-Line", isHostBuiltIn: true))
            }
        }
        guard version != nil || !groups.isEmpty || b.count > 40 else { throw ProjectError.corrupt("no events could be read") }
        return HostDocument(host: .flStudio, savedWith: version.map { "FL Studio \($0)" }, savedVersion: HostDocument.dotted(in: version),
                            plugins: HostDocument.merged(found), warnings: warnings)
    }

    // MARK: Helpers

    static func string(_ d: Data) -> String { String(decoding: d, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces)) }

    /// The chunks of a wrapper's plugin event, or nil if the blob does not have that layout.
    static func wrapperChunks(_ blob: Data) -> [Int: Data]? {
        let b = [UInt8](blob)
        guard b.count >= 16, b[0] == 8 || b[0] == 10, b[1] == 0, b[2] == 0, b[3] == 0 else { return nil }
        var i = 4
        var out: [Int: Data] = [:]
        while i + 12 <= b.count {
            let id = Int(le32(b, i))
            var size = 0
            for k in 0..<8 { size |= Int(b[i + 4 + k]) << (8 * k) }
            i += 12
            guard size >= 0, size <= b.count - i else { break }
            out[id] = Data(b[i..<i + size]); i += size
        }
        return out[54] != nil || out[55] != nil ? out : nil
    }

    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }

    /// ASCII/UTF-8 or UTF-16LE (more than half of the odd bytes are zero), without the terminating NUL.
    static func text(_ p: [UInt8]) -> String {
        guard !p.isEmpty else { return "" }
        let pairs = p.count / 2
        let oddZeros = stride(from: 1, to: p.count, by: 2).filter { p[$0] == 0 }.count
        let trim = CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)
        if pairs >= 1, oddZeros * 2 > pairs {
            let units = (0..<pairs).map { UInt16(p[$0 * 2]) | UInt16(p[$0 * 2 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self).trimmingCharacters(in: trim)
        }
        return String(decoding: p, as: UTF8.self).trimmingCharacters(in: trim)
    }

    /// Plugin file paths inside a wrapper's state: ASCII or UTF-16LE strings ending in a plugin extension.
    static func pluginPaths(in blob: Data) -> [String] {
        let re = try! NSRegularExpression(pattern: #"[^\x00-\x1F"<>|]{2,400}?\.(?:vst3|vst|component|clap|dll)"#, options: [.caseInsensitive])
        var out: [String] = []
        let ascii = String(decoding: blob.prefix(4 * 1024 * 1024).map { $0 < 0x20 || $0 > 0x7E ? 0x00 : $0 }, as: UTF8.self)
        var candidates = [ascii]
        for offset in 0...1 where blob.count > offset + 4 {
            let body = blob.dropFirst(offset).prefix(4 * 1024 * 1024)
            let units = stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 }
            candidates.append(String(decoding: units.map { $0 >= 0x20 && $0 < 0x7F || $0 > 0xA0 ? $0 : 0 }, as: UTF16.self))
        }
        for c in candidates {
            let ns = c as NSString
            for m in re.matches(in: c, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                if !out.contains(path) { out.append(path) }
            }
        }
        return out
    }
}

// MARK: - Pro Tools (session info exported as text)

/// Pro Tools sessions (`.ptx`) are encrypted, but Pro Tools can export "Session Info as Text". That file has a per-track
/// `PLUG-INS:` line and, when the option is ticked, a "P L U G - I N S  L I S T I N G" table with MANUFACTURER, PLUG-IN NAME, VERSION, FORMAT,
/// STEMS and NUMBER OF PLUG-INS columns. The listing's version is the plugin version Pro Tools recorded, i.e. the "saved with" version.
enum ProToolsTextParser {
    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 20 else { throw ProjectError.corrupt("the file is only \(data.count) bytes long") }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.first?.hasPrefix("SESSION NAME:") == true else { throw ProjectError.unsupportedFormat("the text does not start with SESSION NAME:") }

        var found: [FoundPlugin] = []
        var listing = false
        var columns: [String] = []
        var sawListing = false
        var warnings: [String] = []
        for raw in lines {
            let squashed = raw.replacingOccurrences(of: " ", with: "")
            if squashed.hasPrefix("PLUG-INSLISTING") || squashed.hasPrefix("PLUG-INLISTING") { listing = true; sawListing = true; columns = []; continue }
            if listing {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { if !columns.isEmpty { listing = false }; continue }
                let cells = raw.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                if columns.isEmpty {
                    if cells.first?.uppercased().hasPrefix("MANUFACTURER") == true { columns = cells.map { $0.uppercased() } } else { listing = false }
                    continue
                }
                func cell(_ names: [String]) -> String? {
                    for n in names { if let i = columns.firstIndex(where: { $0.hasPrefix(n) }), i < cells.count, !cells[i].isEmpty { return cells[i] } }
                    return nil
                }
                guard let name = cell(["PLUG-IN NAME", "PLUGIN NAME", "NAME"]) else { continue }
                let vendor = cell(["MANUFACTURER"]), version = cell(["VERSION"]), fmt = cell(["FORMAT"])?.lowercased()
                var p = FoundPlugin(format: .aax, name: name, vendor: vendor)
                if let own = Host.proTools.ownVendor, vendor?.caseInsensitiveCompare(own) == .orderedSame { p.format = .proToolsBuiltIn; p.isHostBuiltIn = true }
                else if fmt?.contains("audiosuite") == true { p.format = .aax }
                if let version { p.knownSaved = [SavedVersion(version: version, source: "Pro Tools plug-in listing", confidence: .convention)] }
                found.append(p)
            } else if raw.hasPrefix("PLUG-INS:") {
                for entry in raw.dropFirst("PLUG-INS:".count).components(separatedBy: "\t") {
                    var name = entry.trimmingCharacters(in: .whitespaces)
                    if name.isEmpty { continue }
                    if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) { name = String(name[..<open.lowerBound]) }
                    found.append(FoundPlugin(format: .aax, name: name))
                }
            }
        }
        // Track lines only know names; if the listing exists it is authoritative, so drop track-line duplicates of listed plugins.
        var merged: [FoundPlugin] = []
        for p in HostDocument.merged(found) {
            if sawListing, p.knownSaved.isEmpty, p.vendor == nil,
               merged.contains(where: { $0.name == p.name }) || found.contains(where: { $0.name == p.name && $0.vendor != nil }) { continue }
            merged.append(p)
        }
        if !sawListing, !merged.isEmpty { warnings.append("This export has no plug-in listing, so manufacturers and versions are unknown. In Pro Tools, tick the plug-in listing when exporting Session Info as Text.") }
        return HostDocument(host: .proTools, savedWith: nil, savedVersion: nil, plugins: merged, warnings: warnings)
    }
}

// MARK: - Pro Tools sessions (.ptx, .ptf, .pts)

/// A Pro Tools session is a scrambled file: byte 0x12 says how (1 for Pro Tools 5-9, 5 for 10 and later) and byte 0x13 is a key value. From offset 0x14 each byte is XORed with a table entry
/// generated from the key: for type 1 the entry is `(i * delta) & 255` indexed by the byte offset modulo 256; for type 5 it is `(i * delta) & 255` indexed by `offset >> 12`.
/// `delta` is the first `i` in 0..<256 with `(i * m) & 255 == key` (m = 53 for type 1, 11 for type 5), negated for type 5.
/// The unscrambled data is a tree of blocks: `5A`, a 16-bit block type, a 32-bit size, a 16-bit content type, then the content (children are blocks inside the content).
/// Byte 0x11 says whether integers are big-endian. Content type 0x0003 holds the product ("Pro Tools Ultimate"), its version ("2019.12.0") and the kind of file; content type 0x1017 is one entry of the
/// session's plugin list: a length-prefixed plugin name, three byte-reversed four-character IDs (AAX manufacturer, product, plugin), and a length-prefixed effect identifier.
enum ProToolsSessionParser {
    /// The manufacturer ID Pro Tools uses for its own plugins (Digidesign's four-character code); it is an ID in the file format, not a plugin name.
    static let ownManufacturerID = "Digi"
    private static let maxBlocks = 200_000

    static func parse(_ file: Data) throws -> HostDocument {
        guard file.count >= 0x40 else { throw ProjectError.corrupt("the session is only \(file.count) bytes long") }
        var b = [UInt8](file)
        guard b[0] == 0x03 else { throw ProjectError.unsupportedFormat("the file does not start like a Pro Tools session") }
        let type = b[0x12], key = b[0x13]
        guard type == 1 || type == 5 else { throw ProjectError.unsupportedFormat("unknown Pro Tools scrambling type \(type)") }
        let delta = unscrambleDelta(key: key, type: type)
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { table[i] = UInt8(truncatingIfNeeded: i * Int(delta)) }
        for i in 0x14..<b.count { b[i] ^= table[type == 1 ? (i & 0xFF) : ((i >> 12) & 0xFF)] }
        let big = b[0x11] != 0

        func u16(_ p: Int) -> Int { big ? Int(b[p]) << 8 | Int(b[p + 1]) : Int(b[p + 1]) << 8 | Int(b[p]) }
        func u32(_ p: Int) -> Int { big ? Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3]) : Int(b[p + 3]) << 24 | Int(b[p + 2]) << 16 | Int(b[p + 1]) << 8 | Int(b[p]) }

        struct Block { var contentType: Int; var offset: Int; var size: Int }
        var blocks: [Block] = []
        var count = 0
        func parseBlock(_ pos: Int, _ end: Int, _ depth: Int) -> Int? {
            guard depth < 24, pos + 9 <= end, b[pos] == 0x5A else { return nil }
            let bt = u16(pos + 1), size = u32(pos + 3), ct = u16(pos + 7), off = pos + 7
            guard bt & 0xFF00 == 0, size >= 2, off + size <= end, count < maxBlocks else { return nil }
            count += 1
            blocks.append(Block(contentType: ct, offset: off, size: size))
            var i = 1
            while i < size, pos + i + 9 <= off + size {
                if let n = parseBlock(pos + i, off + size, depth + 1) { i += n + 7 } else { i += 1 }
            }
            return size
        }
        var p = 0x14
        while p + 9 <= b.count {
            if let n = parseBlock(p, b.count, 0) { p += n + 7 } else { p += 1 }
        }
        guard !blocks.isEmpty else { throw ProjectError.corrupt("no blocks could be read (wrong key or damaged file)") }

        /// Length-prefixed printable strings in a range: (offset after the string, text).
        func strings(_ lo: Int, _ hi: Int) -> [(end: Int, text: String)] {
            var out: [(Int, String)] = []
            var k = lo
            while k + 5 <= hi {
                let len = u32(k)
                if len >= 2, len <= 200, k + 4 + len <= hi, b[(k + 4)..<(k + 4 + len)].allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                    out.append((k + 4 + len, String(decoding: b[(k + 4)..<(k + 4 + len)], as: UTF8.self))); k += 4 + len
                } else { k += 1 }
            }
            return out
        }

        var savedWith: String?, savedVersion: String?
        for blk in blocks where blk.contentType == 0x0003 {
            let s = strings(blk.offset + 2, blk.offset + blk.size)
            if let i = s.firstIndex(where: { $0.text.hasPrefix("Pro Tools") && !$0.text.contains("Session") }),
               let v = s[(i + 1)...].first(where: { SavedVersionExtractor.isDottedVersion($0.text) }) {
                savedWith = "\(s[i].text) \(v.text)"; savedVersion = v.text; break
            }
        }

        var found: [FoundPlugin] = []
        for blk in blocks where blk.contentType == 0x1017 {
            let lo = blk.offset + 2, hi = blk.offset + blk.size
            let s = strings(lo, hi)
            guard let first = s.first, first.end + 12 <= hi else { continue }
            let codes = (0..<3).map { k -> String in
                String(decoding: b[(first.end + 4 * k)..<(first.end + 4 * k + 4)].reversed(), as: UTF8.self)
            }
            guard codes.allSatisfy({ $0.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F } }) else { continue }
            var plugin = FoundPlugin(format: .aax, name: first.text, vendor: nil)
            plugin.ids = codes.joined(separator: ":")
            if codes[0] == ownManufacturerID { plugin.format = .proToolsBuiltIn; plugin.isHostBuiltIn = true }
            found.append(plugin)
        }
        var doc = HostDocument(host: .proTools, savedWith: savedWith, savedVersion: savedVersion, plugins: HostDocument.merged(found))
        if savedWith == nil { doc.warnings.append("The session does not say which Pro Tools version saved it.") }
        return doc
    }

    /// The key-derived step of the scrambling table.
    static func unscrambleDelta(key: UInt8, type: UInt8) -> UInt8 {
        let mul = type == 1 ? 53 : 11
        for i in 0..<256 where (i * mul) & 0xFF == Int(key) { return type == 1 ? UInt8(i) : UInt8(truncatingIfNeeded: -i) }
        return 0
    }
}
