import Foundation

/// Turns devices found in an Ableton Live set into rows, using the same matching and saved-version machinery as Logic projects.
///
/// Matching:
/// - Audio Units: by AU codes (from the descriptor, or from the AU state plist stored in the set), exactly as for Logic.
/// - VST3: by class ID against Ableton Live's own plugin database (which also holds the scanned version); if Live isn't installed,
///   by bundle file name, reported as uncertain.
/// - VST2: by name against the same database, then bundle file name.
enum AbletonResolver {
    /// Live's internal element names that are not what the UI calls the device. Unknown names are split on capitals.
    static let builtInNames: [String: String] = [
        "Eq8": "EQ Eight", "FilterEQ3": "EQ Three", "Compressor2": "Compressor", "GlueCompressor": "Glue Compressor",
        "MultibandDynamics": "Multiband Dynamics", "Reverb": "Reverb", "Hybrid": "Hybrid Reverb", "StereoGain": "Utility",
        "AutoFilter": "Auto Filter", "AutoPan": "Auto Pan", "Delay": "Simple Delay", "PingPongDelay": "Ping Pong Delay",
        "FilterDelay": "Filter Delay", "Echo": "Echo", "Limiter": "Limiter", "Saturator": "Saturator", "Redux": "Redux",
        "Tuner": "Tuner", "Spectrum": "Spectrum", "Chorus2": "Chorus-Ensemble", "Phaser": "Phaser", "PhaserNew": "Phaser-Flanger",
        "Flanger": "Flanger", "Gate": "Gate", "DrumBuss": "Drum Buss", "Pedal": "Pedal", "AmpDevice": "Amp", "Cabinet": "Cabinet",
        "OriginalSimpler": "Simpler", "MultiSampler": "Sampler", "InstrumentVector": "Wavetable", "UltraAnalog": "Analog",
        "LoungeLizard": "Electric", "StringStudio": "Tension", "Operator": "Operator", "DrumRack": "Drum Rack", "Looper": "Looper",
        "Vocoder": "Vocoder", "Corpus": "Corpus", "Resonator": "Resonators", "Erosion": "Erosion", "FrequencyShifter": "Frequency Shifter",
        "Overdrive": "Overdrive", "Roar": "Roar", "Shifter": "Shifter", "Beat Repeat": "Beat Repeat", "BeatRepeat": "Beat Repeat",
        "Arpeggiator": "Arpeggiator", "Scale": "Scale", "Chord": "Chord", "Pitch": "Pitch", "Velocity": "Velocity", "Random": "Random",
        "DynamicTube": "Dynamic Tube", "GrainDelay": "Grain Delay", "Transmute": "Transmute", "Emit": "Emit", "Drift": "Drift",
        "Meld": "Meld", "Bass": "Bass", "Collision": "Collision", "Impulse": "Impulse", "Sampler": "Sampler", "Simpler": "Simpler",
    ]

    static func displayName(forBuiltIn element: String) -> String {
        if let n = builtInNames[element] { return n }
        var out = "", prev: Character = " "
        for c in element {
            if c.isUppercase, prev.isLowercase { out.append(" ") }
            out.append(c); prev = c
        }
        return out.trimmingCharacters(in: .decimalDigits)
    }

    static func resolve(_ d: AbletonDevice, index: InstalledPluginIndex, setLiveVersion: String?) -> PluginEntry {
        switch d.kind {
        case .builtIn: return builtIn(d, index: index, setLiveVersion: setLiveVersion)
        case .maxForLive:
            return PluginEntry(id: d.key, name: d.name, manufacturer: "Max for Live", format: .maxForLive, installedVersion: nil,
                               status: .versionUnknown, isUncertain: false,
                               note: "Max for Live devices live in the set or your User Library; their versions are not checked.",
                               otherFormats: [], codes: "", bundlePath: nil)
        default: break
        }

        // Saved versions from the plugin's own state buffers.
        var saved: [SavedVersion] = []
        var stateCodes: (type: String, subtype: String, manufacturer: String)?
        for s in d.states {
            let r = SavedVersionExtractor.statePlistCandidates(s)
            for v in r.versions where !saved.contains(v) { saved.append(v) }
            if stateCodes == nil { stateCodes = r.codes }
        }

        var e: PluginEntry
        switch d.kind {
        case .audioUnit: e = audioUnit(d, codes: d.auCodes ?? stateCodes, saved: saved, index: index)
        case .vst3: e = vst3(d, index: index)
        default: e = vst2(d, index: index)
        }
        if d.kind != .audioUnit { PluginResolver.applySavedVersion(&e, saved: saved, storedName: d.name) }
        return e
    }

    // MARK: Kinds

    private static func builtIn(_ d: AbletonDevice, index: InstalledPluginIndex, setLiveVersion: String?) -> PluginEntry {
        let now = index.abletonVersion.map { "\($0) (Live)" }
        var e = PluginEntry(id: d.key, name: displayName(forBuiltIn: d.name), manufacturer: "Ableton", format: .abletonBuiltIn,
                            installedVersion: now, status: now == nil ? .versionUnknown : .installed, isUncertain: false,
                            note: now == nil ? "Ableton Live is not installed, so its built-in device version can't be read."
                                             : "Built-in devices are versioned with Live itself.",
                            otherFormats: [], codes: "", bundlePath: nil)
        if let v = setLiveVersion {
            e.savedVersion = "\(v) (Live)"
            e.savedVersionSource = "the set's Creator attribute"
            e.versionCheck = PluginResolver.compare(saved: [v], installed: index.abletonVersion)
        }
        return e
    }

    private static func audioUnit(_ d: AbletonDevice, codes: (type: String, subtype: String, manufacturer: String)?,
                                  saved: [SavedVersion], index: InstalledPluginIndex) -> PluginEntry {
        if let c = codes {
            let raw = RawPluginRecord(kind: .audioUnit, name: d.name, manufacturer: c.manufacturer, type: c.type, subtype: c.subtype,
                                      count: d.count, firstOffset: 0, saved: saved)
            var e = PluginResolver.resolve(raw, index: index)
            if let m = d.fields["Manufacturer"], e.status == .notInstalled { e.manufacturer = m }
            if e.status == .notInstalled { e.name = d.name }
            return e
        }
        // No codes anywhere: match on the full name only, and never call that certain.
        let wanted = InstalledPluginIndex.normalize(d.name)
        let hits = index.components.filter { InstalledPluginIndex.normalize($0.pluginName) == wanted || InstalledPluginIndex.normalize($0.fullName) == wanted }
        let bundles = Set(hits.map(\.bundleURL))
        guard let c = hits.first, bundles.count == 1 else {
            return PluginEntry(id: d.key, name: d.name, manufacturer: d.fields["Manufacturer"] ?? "—", format: .au, installedVersion: nil,
                               status: .notInstalled, isUncertain: false,
                               note: "No installed Audio Unit is named \"\(d.name)\", and the set does not record its AU codes.",
                               otherFormats: [], codes: "", bundlePath: nil)
        }
        var e = PluginEntry(id: d.key, name: c.pluginName, manufacturer: c.manufacturerName.isEmpty ? (d.fields["Manufacturer"] ?? "—") : c.manufacturerName,
                            format: .au, installedVersion: c.version, status: .versionUnknown, isUncertain: true,
                            note: "Matched by name only: the set does not record this plugin's AU codes.",
                            otherFormats: [], codes: "\(c.type)/\(c.subtype)/\(c.manufacturer)", bundlePath: c.bundleURL.path,
                            installedComponentVersion: c.componentVersion, installedProductName: c.pluginName)
        PluginResolver.applySavedVersion(&e, saved: saved, storedName: d.name)
        return e
    }

    private static func vst3(_ d: AbletonDevice, index: InstalledPluginIndex) -> PluginEntry {
        let db = index.liveDatabase
        let byID = db.record(classIDs: d.vst3ClassIDs)
        let byName = db.records(named: d.name).filter { $0.identifier.hasPrefix("device:vst3:") }
        if let r = byID ?? (byName.count == 1 ? byName.first : nil) {
            let exact = byID != nil
            return PluginEntry(id: d.key, name: r.name, manufacturer: r.vendor.isEmpty ? "—" : r.vendor, format: .vst3,
                               installedVersion: r.version.isEmpty ? nil : r.version,
                               status: r.version.isEmpty || !exact ? .versionUnknown : .installed, isUncertain: !exact,
                               note: exact ? "Version from Ableton Live's plugin database." : "Matched by name only; version from Ableton Live's plugin database.",
                               otherFormats: [], codes: d.vst3ClassIDs.first ?? "", bundlePath: nil, installedProductName: r.name)
        }
        return viaBundle(d, format: .vst3, index: index)
    }

    private static func vst2(_ d: AbletonDevice, index: InstalledPluginIndex) -> PluginEntry {
        let hits = index.liveDatabase.records(named: d.name).filter { !$0.identifier.hasPrefix("device:vst3:") && !$0.identifier.hasPrefix("device:au:") }
        if hits.count == 1, let r = hits.first {
            return PluginEntry(id: d.key, name: r.name, manufacturer: r.vendor.isEmpty ? "—" : r.vendor, format: .vst,
                               installedVersion: r.version.isEmpty ? nil : r.version, status: r.version.isEmpty ? .versionUnknown : .installed,
                               isUncertain: false, note: "Version from Ableton Live's plugin database.", otherFormats: [], codes: "",
                               bundlePath: nil, installedProductName: r.name)
        }
        return viaBundle(d, format: .vst, index: index)
    }

    /// Without Live's database: match the plugin's name to a VST/VST3 bundle's file name. Never certain.
    private static func viaBundle(_ d: AbletonDevice, format: PluginFormat, index: InstalledPluginIndex) -> PluginEntry {
        if let b = index.bundle(format: format, named: d.name) {
            return PluginEntry(id: d.key, name: d.name, manufacturer: d.fields["Vendor"] ?? d.fields["Manufacturer"] ?? "—", format: format,
                               installedVersion: b.version.isEmpty ? nil : b.version, status: .versionUnknown, isUncertain: true,
                               note: "Matched to a \(format.rawValue) bundle by file name only (Ableton Live's plugin database was not available).",
                               otherFormats: [], codes: d.vst3ClassIDs.first ?? "", bundlePath: nil, installedProductName: d.name)
        }
        return PluginEntry(id: d.key, name: d.name, manufacturer: d.fields["Vendor"] ?? d.fields["Manufacturer"] ?? "—", format: format,
                           installedVersion: nil, status: .notInstalled, isUncertain: false,
                           note: "No installed \(format.rawValue) plugin named \"\(d.name)\" was found.", otherFormats: [],
                           codes: d.vst3ClassIDs.first ?? "", bundlePath: nil)
    }
}
