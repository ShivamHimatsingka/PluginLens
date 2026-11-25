import Foundation

// MARK: - Neutral representation

/// A plugin or device as found in some DAW project, before it is matched against what is installed.
struct FoundPlugin: Hashable, Sendable {
    var format: PluginFormat
    var name: String
    var vendor: String?
    /// File or bundle name as the DAW recorded it, e.g. "FabFilter Pro-Q 4.vst3".
    var fileName: String?
    /// AU "Vendor: Name" as recorded by the DAW.
    var auFullName: String?
    var auCodes: AUCodes?
    /// True for devices that ship with the DAW itself.
    var isHostBuiltIn = false
    var states: [Data] = []
    var count = 1
    /// Versions the project states outright (Pro Tools' plug-in listing).
    var knownSaved: [SavedVersion] = []
    /// The project did not record whether this is VST3, VST or AU: try each.
    var formatGuess = false

    struct AUCodes: Hashable, Sendable { var type: String; var subtype: String; var manufacturer: String }

    var key: String {
        if let c = auCodes { return "au:\(c.type)/\(c.subtype)/\(c.manufacturer)" }
        return "\(format.rawValue):\(isHostBuiltIn ? "builtin" : (fileName ?? auFullName ?? "")):\(name)"
    }
    static func == (l: FoundPlugin, r: FoundPlugin) -> Bool { l.key == r.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}

struct HostDocument: Sendable {
    var host: Host
    /// For hosts that share one file format (DAWproject): the exporting application's name.
    var hostLabel: String? = nil
    /// How the project describes the program that saved it, e.g. "REAPER 7.27".
    var savedWith: String?
    /// The dotted version in `savedWith`.
    var savedVersion: String?
    var plugins: [FoundPlugin]
    var warnings: [String] = []

    /// Merges duplicates (same plugin used on several tracks) and keeps first-seen order.
    static func merged(_ list: [FoundPlugin]) -> [FoundPlugin] {
        var order: [String] = [], map: [String: FoundPlugin] = [:]
        for p in list {
            if var m = map[p.key] { m.count += 1; m.states += p.states; map[p.key] = m } else { order.append(p.key); map[p.key] = p }
        }
        return order.compactMap { map[$0] }
    }

    static func dotted(in s: String?) -> String? {
        guard let s, let r = s.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }
}

// MARK: - Matching

enum HostResolver {
    static func resolve(_ p: FoundPlugin, host: Host, hostLabel: String? = nil, savedHostVersion: String?, index: InstalledPluginIndex) -> PluginEntry {
        if p.isHostBuiltIn || p.format == .jsfx { return builtIn(p, host: host, hostLabel: hostLabel, savedHostVersion: savedHostVersion, index: index) }

        var saved: [SavedVersion] = p.knownSaved
        var stateCodes: FoundPlugin.AUCodes?
        for s in p.states {
            let r = SavedVersionExtractor.statePlistCandidates(s)
            for v in r.versions where !saved.contains(v) { saved.append(v) }
            if stateCodes == nil, let c = r.codes { stateCodes = .init(type: c.type, subtype: c.subtype, manufacturer: c.manufacturer) }
        }

        if p.formatGuess {
            // The format was not recorded: use the first format in which the plugin is installed.
            var last: PluginEntry?
            for f in [PluginFormat.vst3, .au, .vst] {
                var q = p; q.formatGuess = false; q.format = f
                var e = resolve(q, host: host, savedHostVersion: savedHostVersion, index: index)
                if e.status != .notInstalled { e.isUncertain = true; if e.status == .installed { e.status = .versionUnknown }; e.note = "The project does not record the plugin format; matched as \(f.rawValue)."; return e }
                last = e
            }
            if var e = last { e.note = "No installed VST3, AU or VST plugin matches \"\(p.name)\"; the project does not record the plugin format."; return e }
        }
        var e: PluginEntry
        switch p.format {
        case .au: e = audioUnit(p, codes: p.auCodes ?? stateCodes, saved: saved, index: index)
        case .vst, .vst3, .clap, .aax: e = bundled(p, index: index)
        default:
            e = PluginEntry(id: p.key, name: p.name, manufacturer: p.vendor ?? "—", format: p.format, installedVersion: nil,
                            status: .versionUnknown, isUncertain: false,
                            note: "\(p.format.rawValue) plugins are not checked against the installed plugins.", otherFormats: [], codes: "", bundlePath: nil)
        }
        if p.format != .au { PluginResolver.applySavedVersion(&e, saved: saved, storedName: p.name) }
        return e
    }

    private static func builtIn(_ p: FoundPlugin, host: Host, hostLabel: String?, savedHostVersion: String?, index: InstalledPluginIndex) -> PluginEntry {
        let label = hostLabel ?? host.displayName
        let installedHost = hostLabel != nil ? index.appVersion(namePrefix: hostLabel!) : index.installedVersion(of: host)
        let now = installedHost.map { "\($0) (\(label))" }
        var e = PluginEntry(id: p.key, name: p.name, manufacturer: p.vendor ?? label, format: p.format,
                            installedVersion: now, status: p.format == .jsfx ? .installed : (now == nil ? .versionUnknown : .installed),
                            isUncertain: false,
                            note: now == nil ? "\(label) is not installed, so its built-in version can't be read."
                                             : "Built-in devices are versioned with \(label) itself.",
                            otherFormats: [], codes: "", bundlePath: nil)
        if let k = p.knownSaved.first {   // e.g. Pro Tools' plug-in listing: a version, but not Pro Tools' own
            e.savedVersion = k.version; e.savedVersionSource = k.source; e.versionCheck = .cannotCompare
        } else if let v = savedHostVersion {
            e.savedVersion = "\(v) (\(label))"
            e.savedVersionSource = "the project's own header"
            e.versionCheck = PluginResolver.compare(saved: [v], installed: installedHost)
        }
        return e
    }

    private static func audioUnit(_ p: FoundPlugin, codes: FoundPlugin.AUCodes?, saved: [SavedVersion], index: InstalledPluginIndex) -> PluginEntry {
        func raw(_ c: (String, String, String)) -> RawPluginRecord {
            RawPluginRecord(kind: .audioUnit, name: p.name, manufacturer: c.2, type: c.0, subtype: c.1, count: p.count, firstOffset: 0, saved: saved)
        }
        if let c = codes { return PluginResolver.resolve(raw((c.type, c.subtype, c.manufacturer)), index: index) }

        // No codes: a plugin file name the DAW recorded ("Name.component") identifies the bundle.
        if let f = p.fileName, let c = index.components.first(where: { $0.bundleURL.lastPathComponent == (f as NSString).lastPathComponent }) {
            return PluginResolver.resolve(raw((c.type, c.subtype, c.manufacturer)), index: index)
        }
        // The DAW's "Vendor: Name" is exactly the name an installed component declares.
        let wantedFull = p.auFullName.map(InstalledPluginIndex.normalize)
        let wantedName = InstalledPluginIndex.normalize(p.name)
        let byFull = wantedFull.map { w in index.components.filter { InstalledPluginIndex.normalize($0.fullName) == w } } ?? []
        let byName = index.components.filter { InstalledPluginIndex.normalize($0.pluginName) == wantedName }
        let hits = !byFull.isEmpty ? byFull : byName
        if let c = hits.first, Set(hits.map(\.bundleURL)).count == 1 {
            var e = PluginResolver.resolve(raw((c.type, c.subtype, c.manufacturer)), index: index)
            if byFull.isEmpty {   // name-only match: never certain
                e.isUncertain = true; e.status = .versionUnknown; e.versionCheck = .cannotCompare
                e.note = "Matched by plugin name only: the project does not record this plugin's AU codes."
            }
            return e
        }
        return PluginEntry(id: p.key, name: p.name, manufacturer: p.vendor ?? "—", format: .au, installedVersion: nil, status: .notInstalled,
                           isUncertain: false, note: "No installed Audio Unit matches \"\(p.auFullName ?? p.name)\".", otherFormats: [], codes: "", bundlePath: nil)
    }

    /// VST, VST3, CLAP: match the bundle file name the DAW recorded, then fall back to the plugin's name.
    private static func bundled(_ p: FoundPlugin, index: InstalledPluginIndex) -> PluginEntry {
        let stem = p.fileName.map { ($0 as NSString).lastPathComponent }.map { ($0 as NSString).deletingPathExtension }
        func entry(_ b: (name: String, version: String), uncertain: Bool, note: String) -> PluginEntry {
            let v = b.version.isEmpty ? nil : b.version
            return PluginEntry(id: p.key, name: p.name, manufacturer: p.vendor ?? "—", format: p.format, installedVersion: v,
                               status: (v == nil || uncertain) ? .versionUnknown : .installed, isUncertain: uncertain, note: note,
                               otherFormats: [], codes: "", bundlePath: nil, installedProductName: p.name)
        }
        if let stem, let b = index.bundle(format: p.format, named: stem) {
            return entry(b, uncertain: false, note: "Matched by the plugin's file name; version from its Info.plist.")
        }
        let combined = [p.vendor, p.name].compactMap { $0 }.joined(separator: " ")
        if p.vendor != nil, let b = index.bundle(format: p.format, named: combined) {
            return entry(b, uncertain: false, note: "Matched by manufacturer and plugin name.")
        }
        if let b = index.bundle(format: p.format, named: p.name) ?? index.bundle(format: p.format, nameContaining: p.name) {
            return entry(b, uncertain: true, note: "Matched by plugin name only.")
        }
        return PluginEntry(id: p.key, name: p.name, manufacturer: p.vendor ?? "—", format: p.format, installedVersion: nil, status: .notInstalled,
                           isUncertain: false, note: "No installed \(p.format.rawValue) plugin matches \"\(p.fileName ?? p.name)\".",
                           otherFormats: [], codes: "", bundlePath: nil)
    }
}

// MARK: - REAPER

/// REAPER projects (`.rpp`) are plain text. Each effect is a block such as
///
///     <VST "VST3: Pro-Q 4 (FabFilter)" "FabFilter Pro-Q 4.vst3" 0 "" 1181...{...} ""
///       <base64 state lines>
///     >
///
/// The first quoted string is the name REAPER's FX browser shows ("Format: Name (Vendor)"); the second is the plugin file
/// (VST/VST3/CLAP) or the Audio Unit's full "Vendor: Name".
enum ReaperParser {
    private static let fxElements: Set<String> = ["VST", "VSTi", "AU", "AUi", "JS", "CLAP", "CLAPi", "DX", "DXi", "LV2", "LV2i"]

    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 16 else { throw ProjectError.corrupt("the project is only \(data.count) bytes long") }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let first = lines.next()?.trimmingCharacters(in: .whitespaces), first.hasPrefix("<REAPER_PROJECT") else {
            throw ProjectError.unsupportedFormat("the file does not start with <REAPER_PROJECT")
        }
        let header = tokenize(first)
        let savedWith = header.count > 2 ? header[2] : nil           // "7.27/macOS-arm64"
        let version = HostDocument.dotted(in: savedWith)

        var found: [FoundPlugin] = []
        var depth = 1
        var capture: (element: String, tokens: [String], depth: Int, state: Data, pending: String)?
        while let raw = lines.next() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("<") {
                depth += 1
                let tokens = tokenize(String(line.dropFirst()))
                if capture == nil, let el = tokens.first, fxElements.contains(el) { capture = (el, Array(tokens.dropFirst()), depth, Data(), "") }
            } else if line == ">" {
                if var c = capture, c.depth == depth { Self.flush(&c.state, &c.pending); found.append(plugin(element: c.element, tokens: c.tokens, state: c.state)); capture = nil }
                depth -= 1
            } else if capture != nil, capture!.depth == depth, capture!.state.count < 64 * 1024 * 1024 {
                // REAPER writes state as several base64 segments; a line ending in "=" closes a segment, so decode segment by segment.
                var c = capture!
                c.pending += line
                if line.hasSuffix("=") { Self.flush(&c.state, &c.pending) }
                capture = c
            }
        }
        var warnings: [String] = []
        if version == nil { warnings.append("The project header has no program version.") }
        return HostDocument(host: .reaper, savedWith: savedWith.map { "REAPER \($0)" }, savedVersion: version,
                            plugins: HostDocument.merged(found), warnings: warnings)
    }

    private static func flush(_ state: inout Data, _ pending: inout String) {
        if !pending.isEmpty, let d = Data(base64Encoded: pending, options: .ignoreUnknownCharacters) { state.append(d) }
        pending = ""
    }

    static func plugin(element: String, tokens: [String], state: Data) -> FoundPlugin {
        let display = tokens.first ?? element
        let file = tokens.count > 1 ? tokens[1] : nil
        // "VST3: Pro-Q 4 (FabFilter)" -> prefix, name, vendor
        var prefix: String?, name = display, vendor: String?
        if let r = display.range(of: ": ") { prefix = String(display[..<r.lowerBound]); name = String(display[r.upperBound...]) }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            vendor = String(name[open.upperBound...].dropLast()); name = String(name[..<open.lowerBound])
        }
        var p = FoundPlugin(format: .vst, name: name, vendor: vendor, fileName: file, states: state.isEmpty ? [] : [state])
        let tag = (prefix ?? element).uppercased()
        switch true {
        case tag.hasPrefix("VST3") || (file?.lowercased().hasSuffix(".vst3") ?? false): p.format = .vst3
        case tag.hasPrefix("VST"): p.format = .vst
        case tag.hasPrefix("AU"): p.format = .au; p.auFullName = file; p.fileName = nil
        case tag.hasPrefix("CLAP"): p.format = .clap
        case tag.hasPrefix("LV2"): p.format = .lv2
        case tag.hasPrefix("JS"):
            p.format = .jsfx; p.vendor = "REAPER"; p.name = (display as NSString).lastPathComponent; p.isHostBuiltIn = true
        default: p.format = .vst
        }
        if vendor == "Cockos", p.format != .jsfx { p.isHostBuiltIn = true; p.format = .reaperBuiltIn }
        return p
    }

    /// Splits a REAPER line into tokens, honouring "double", 'single' and `backtick` quotes.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        var started = false
        for c in s {
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "\"" || c == "'" || c == "`" { quote = c; started = true }
            else if c == " " || c == "\t" { if started || !cur.isEmpty { out.append(cur); cur = ""; started = false } }
            else { cur.append(c); started = true }
        }
        if started || !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - Tracktion Waveform

/// Waveform / Tracktion edits (`.tracktionedit`) are XML. Plugins are `<PLUGIN type="vst|vst3|au|volume|..." name=... filename=... uid=... manufacturer=...>`.
/// For Audio Units `filename` is a JUCE identifier such as `AudioUnit:Effects/aufx,Ruum,oDin` (type, subtype, manufacturer).
enum WaveformParser {
    /// Plumbing every track has; not user-chosen plugins.
    private static let plumbing: Set<String> = ["volume", "level", "aux", "insert", "rackinstance", "rack", "meter"]
    private static let builtInNames: [String: String] = ["8bandEq": "8-Band EQ", "comp": "Compressor", "naturalReverb": "Natural Reverb", "eq": "4-Band EQ", "reverb": "Reverb",
        "lowpass": "Low-pass Filter", "phaser": "Phaser", "chorus": "Chorus", "delay": "Delay", "pitchShift": "Pitch Shift", "limiter": "Limiter", "gate": "Noise Gate",
        "tone": "Tone Generator", "fourOsc": "4OSC", "sampler": "Sampler", "impulseResponse": "Impulse Response", "midiModifier": "MIDI Modifier"]
    static func builtInName(forType t: String) -> String {
        if let n = builtInNames[t] { return n }
        var out = "", prev: Character = " "
        for c in t { if c.isUppercase, prev.isLowercase { out.append(" ") }; out.append(c); prev = c }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 16 else { throw ProjectError.corrupt("the edit is only \(data.count) bytes long") }
        let d = Delegate()
        let parser = XMLParser(data: data); parser.delegate = d
        guard parser.parse() || !d.plugins.isEmpty else {
            throw ProjectError.corrupt("the edit's XML could not be read: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }
        guard d.sawEdit else { throw ProjectError.unsupportedFormat("the document is not a Tracktion/Waveform edit") }
        return HostDocument(host: .waveform, savedWith: d.appVersion, savedVersion: HostDocument.dotted(in: d.appVersion),
                            plugins: HostDocument.merged(d.plugins))
    }

    static func auCodes(fromIdentifier id: String) -> FoundPlugin.AUCodes? {
        guard id.hasPrefix("AudioUnit:"), let slash = id.lastIndex(of: "/") else { return nil }
        let parts = id[id.index(after: slash)...].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts.allSatisfy({ $0.utf8.count == 4 }) ? .init(type: parts[0], subtype: parts[1], manufacturer: parts[2]) : nil
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var plugins: [FoundPlugin] = []
        var appVersion: String?
        var sawEdit = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "EDIT" { sawEdit = true; appVersion = a["appVersion"] }
            guard name == "PLUGIN", let type = a["type"] else { return }
            let t = type.lowercased()
            if plumbing.contains(t) { return }
            let n = a["name"] ?? WaveformParser.builtInName(forType: type)
            switch t {
            case "vst", "vst3", "au", "audiounit":
                var p = FoundPlugin(format: t == "vst3" ? .vst3 : (t == "vst" ? .vst : .au), name: n, vendor: a["manufacturer"])
                if let f = a["filename"] {
                    if t.hasPrefix("au") || t == "au" { p.auCodes = WaveformParser.auCodes(fromIdentifier: f); if p.auCodes == nil { p.auFullName = [a["manufacturer"], a["name"]].compactMap { $0 }.joined(separator: ": ") } }
                    else { p.fileName = f }
                }
                if p.format == .vst, p.fileName?.lowercased().hasSuffix(".vst3") == true { p.format = .vst3 }
                plugins.append(p)
            default:
                plugins.append(FoundPlugin(format: .waveformBuiltIn, name: n, vendor: "Tracktion", isHostBuiltIn: true))
            }
        }
    }
}

// MARK: - Ardour

/// Ardour sessions (`.ardour`) are XML. Plugins are `<Processor type="lv2|vst3|audiounit|..." name=...>` inside routes; Ardour's own
/// processors (amp, trim, meter, main-outs ...) have other types and are ignored.
/// Audio Unit processors carry `unique-id` as three decimal numbers (type-subtype-manufacturer) when present.
enum ArdourParser {
    private static let pluginTypes: Set<String> = ["lv2", "ladspa", "luaproc", "vst", "vst3", "audiounit", "lxvst", "mac-vst", "windows-vst"]

    static func parse(_ data: Data) throws -> HostDocument {
        guard data.count >= 16 else { throw ProjectError.corrupt("the session is only \(data.count) bytes long") }
        let d = Delegate()
        let parser = XMLParser(data: data); parser.delegate = d
        guard parser.parse() || !d.plugins.isEmpty else {
            throw ProjectError.corrupt("the session's XML could not be read: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }
        guard d.sawSession else { throw ProjectError.unsupportedFormat("the document is not an Ardour session") }
        var doc = HostDocument(host: .ardour, savedWith: d.version.map { "Ardour session format \($0)" }, savedVersion: nil, plugins: HostDocument.merged(d.plugins))
        if d.plugins.isEmpty == false, d.plugins.allSatisfy({ $0.format == .lv2 }) { doc.warnings.append("LV2 plugins are listed but not checked against what is installed.") }
        return doc
    }

    static func codes(fromUniqueID id: String) -> FoundPlugin.AUCodes? {
        let n = id.split(separator: "-").compactMap { UInt32($0) }
        guard n.count == 3, id.split(separator: "-").count == 3 else { return nil }
        return .init(type: SavedVersionExtractor.fourCC(Int(n[0])), subtype: SavedVersionExtractor.fourCC(Int(n[1])), manufacturer: SavedVersionExtractor.fourCC(Int(n[2])))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var plugins: [FoundPlugin] = []
        var version: String?
        var sawSession = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "Session" { sawSession = true; version = a["version"] }
            guard name == "Processor", let type = a["type"]?.lowercased(), pluginTypes.contains(type), let n = a["name"] else { return }
            var p = FoundPlugin(format: .vst, name: n)
            switch type {
            case "audiounit": p.format = .au; p.auCodes = a["unique-id"].flatMap(ArdourParser.codes)
            case "vst3": p.format = .vst3
            case "lv2", "ladspa", "luaproc": p.format = .lv2
            default: p.format = .vst
            }
            plugins.append(p)
        }
    }
}
