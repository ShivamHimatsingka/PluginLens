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
    private static let channelTypes: Set<String> = ["Sampler", "Audio Clip", "Layer", "Automation Clip", "MIDI Out", ""]
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
        var groups: [(internal: String, name: String?, states: [Data])] = []
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
            case 201: groups.append((text(payload), nil, []))
            case 203: if !groups.isEmpty, groups[groups.count - 1].name == nil { groups[groups.count - 1].name = text(payload) }
            case 212, 213: if !groups.isEmpty, payload.count <= maxState { groups[groups.count - 1].states.append(Data(payload)) }
            default: break
            }
        }

        var found: [FoundPlugin] = []
        for g in groups {
            if g.internal == "Fruity Wrapper" {
                let paths = g.states.flatMap { pluginPaths(in: $0) }
                let path = paths.first
                var p = FoundPlugin(format: .vst, name: g.name ?? (path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "Wrapped plugin"),
                                    vendor: nil, fileName: path.map { ($0 as NSString).lastPathComponent }, states: g.states)
                switch (path as NSString?)?.pathExtension.lowercased() {
                case "vst3": p.format = .vst3
                case "component": p.format = .au
                case "clap": p.format = .clap
                case "vst", "dll": p.format = .vst
                default: p.formatGuess = true
                }
                found.append(p)
            } else if !channelTypes.contains(g.internal) {
                found.append(FoundPlugin(format: .flBuiltIn, name: g.internal, vendor: "Image-Line", isHostBuiltIn: true))
            }
        }
        guard version != nil || !groups.isEmpty || b.count > 40 else { throw ProjectError.corrupt("no events could be read") }
        return HostDocument(host: .flStudio, savedWith: version.map { "FL Studio \($0)" }, savedVersion: HostDocument.dotted(in: version),
                            plugins: HostDocument.merged(found), warnings: warnings)
    }

    // MARK: Helpers

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
                if vendor?.caseInsensitiveCompare("Avid") == .orderedSame { p.format = .proToolsBuiltIn; p.isHostBuiltIn = true }
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
