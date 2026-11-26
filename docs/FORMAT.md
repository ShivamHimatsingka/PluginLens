# File formats: Logic Pro `ProjectData` and Ableton Live `.als`

Sample set: 57 `.logicx` packages (113 `ProjectData` files across alternatives), all saved by
**Logic Pro Creator Studio 12.2 (6644)** on macOS 26. I have no samples from older Logic versions.

## Package layout
```
X.logicx/
  Resources/ProjectInformation.plist   binary plist: LastSavedFrom, BundleVersion, VariantNames
  Alternatives/NNN/ProjectData         the project (chunked binary)
  Alternatives/NNN/MetaData.plist      binary plist: tempo, key, track count, audio/sampler file lists, HasARAPlugins
  Alternatives/NNN/DisplayStateArchive NSKeyedArchive (UI state, not plugin data)
  Alternatives/NNN/Project File Backups/NN   NSKeyedArchive bplists, not ProjectData
```
`MetaData.plist` lists sample/IR/audio files and `HasARAPlugins` but **no plugin list**.

## ProjectData container
- Not XML, not a plist, not compressed. No gzip/zlib/bplist header. Plain strings are visible in the raw bytes.
- First 4 bytes: magic `23 47 c0 ab` (identical in all 113 files). The magic appears again at offsets 60 and 760.
- Chunk tags are little-endian fourccs, so they read backwards in a hex dump. `gnoS` at 0x18 is "Song".
- Entropy is mixed: structured records at about 5 bits per byte, and high-entropy plugin state or audio-ish regions.
- I did not recover the full chunk table (chunk length fields are not decoded). The extraction below works by scanning for records.

## Plugin instance records (found, consistent across all 113 files)
Each plugin insert is a record of this shape. Offsets are relative to the start of the 12-byte name field:

| Offset | Size | Meaning |
|---|---|---|
| -4 | 4 | Two small flags/format bytes (`01 01`, `01 02`, `02 02`) preceded by a u16 |
| 0 | 12 | Plugin name, NUL padded, **truncated to 11 characters** (e.g. `Denoiser Cl`, `UADx Pure P`) |
| 12 | 4 | **AU manufacturer**, as a reversed fourcc (`oDin` bytes `6e 69 44 6f` = "oDin") |
| 16 | 4 | **AU type**, reversed (`xfua` = `aufx`, `fmua` = `aumf`, `umua` = `aumu`) |
| 20 | 4 | **AU subtype**, reversed |
| 24 | ~16 | Flags and a u32 that matches the state length (not a version) |
| 40 | n | State: marker `34 36 69 61` ("ai64") then often an embedded XML plist or opaque blob |

Examples decoded: Pro-Q 4 = `aumf/FQ4p/FabF`, ValhallaRoom = `aufx/Ruum/oDin`, Kontakt 8 = `aumu/NiK8/-NI-`, Serum 2 = `aumu/Xf2X/XFER`.
Across the 113 files I saw about 55 distinct third-party triples. The embedded XML plist (when present) has keys
`manufacturer`, `subtype`, `type` (as integers), `name` (the preset name, e.g. "Untitled"), `version` (always 0) and `data`.

### Logic built-in plugins
Same record shape, but the manufacturer slot holds `GAME` (a Logic-internal marker), not `appl`. The name is Logic's internal short name, not the
display name: `St-Delay`, `SmpleDly`, `Space D`, `Compressor`, `Limiter`, `ChromaVerb`, `Bass Amp`, `Phat FX`, `Spread`.
There is no AU type/subtype for these. Mapping them to full names needs a lookup table I would have to build, and it will be incomplete.

## Plugin version information (revised after Phase 3)
Phase 1 concluded that versions were not stored. That was only half right. There is **no universal version field**, but
the project does contain each plugin's saved AU state as an embedded XML plist (`type`, `subtype`, `manufacturer` as integers,
`version`, plus the plugin's own state blobs), and **many plugins write their own version into that state**.

- The plist `version` key is the AU state-format version: 0 in nearly every case. It is not used.
- Version strings found in the state blobs, by convention:
  - `pluginVersion="x.y.z"` in JUCE XML state: Valhalla plugins, Neural DSP Archetype/Mantra/Parallax/Nameless, oeksound soothe2
  - `"productVersion":"x.y.z"` in a JSON header: Serum 2
  - `PlugVersion x.y.z` text line: Toontrack Superior Drummer
  - `Version="x.y.z"` / `PluginVersion="x.y.z"` attributes (dotted, 2-4 parts, preceded by a non-letter)
  - `###NeuralAmpModeler###`, a little-endian u32 length, then the version string at the head of the state: Neural Amp Modeler and derivatives (e.g. 0.7.13)
  - `Pianoteq 9.2.5/20260909` banner in the state: Pianoteq
- Plugins with nothing found, and what the state actually contains (inspected, including decompressing zlib payloads):
  - FabFilter: `FFBS` binary header, no version string.
  - Universal Audio UADx: `uapw_chunk_version` (state-format version) only.
  - iZotope Ozone/Neutron/RX: zlib-compressed JSON; `Major Version`/`Minor Version`/`Param Version` are state-schema versions (RX 11.3 stores 1.1).
  - Native Instruments Kontakt/Massive: opaque `vstdata`. Soundtoys: opaque `soundtoys-data`. Bertom Denoiser: raw parameters.
  - Antares Auto-Tune: `ChunkVersion` attributes list state-compatibility chunks, not a plugin version, so they are ignored.
  - AmpliTube: `Program Version="2"` is the preset format version.
  A version could still exist inside those payloads in a form I could not recognise; "not stored" means "not found", and new conventions are easy to add.
- Validation: across the 55 readable projects in the sample library, every extracted version equals the version installed on this machine
  (0 disagreements), which is the expected result for an up-to-date machine and independent confirmation that these fields hold the plugin's version.
  The disagreement path is covered by unit tests with fake installs, because no real project here was saved with an older plugin.
- Logic built-ins are versioned with Logic itself: the saved version is `LastSavedFrom` in `Resources/ProjectInformation.plist`.

## Not determinable / risks
1. Full chunk grammar (lengths, nesting). Extraction is a record scan with validation, so it can miss records in unusual layouts.
2. Plugin names are truncated to 11 characters. Matching must use the AU type/subtype/manufacturer triple against each installed
   component's `AudioComponents` array in `Info.plist` (an exact match), with name only as a fallback.
3. Raw byte scanning gives false positives inside audio or state blobs (e.g. random `aufx` lookalikes). The parser must check the
   12-byte name field is printable ASCII, the layout bytes match, and the triple is plausible.
4. Built-in display names are not available (small lookup table only). Per-plugin saved versions exist only for plugins that write one into their state.
5. Software instruments in channel strips, and plugins on the master or aux, appear in the same record style. I have not verified which
   slot or track each belongs to, and bypassed or empty slots are not distinguished.
6. Only Logic 12.2 samples were available. Older or newer-format projects are untested.
7. **Logic Pro hosts only Audio Units.** VST and VST3 can never appear as project plugins. The requested "VST/VST3" format column will always
   be AU or Logic built-in unless you want it to mean "a VST3 build of the same plugin is also installed". That is a decision for you.
8. Many Logic projects here have 0 third-party records (e.g. `Band_Live_Performance_2026`, `Final export`), which is plausible but means built-ins only.


## Saved-version discovery, in order of trust (added in v0.1.0)

1. **AU state `version` field.** The embedded plist's `version` is 0 for most plugins, but plugins built on Apple's AU base classes write their
   *component version* there (major<<16 | minor<<8 | bugfix). Verified on two real plugins: Neural Amp Modeler stores 1805 = 0x070D = 0.7.13
   and Gateway stores 65537 = 0x10001 = 1.0.1, both equal to the installed bundles' `AudioComponents` versions. Compared as integers against the installed component.
2. **Known conventions** in the state (see the table in the README), including inside zlib-compressed state (iZotope's payloads are zlib JSON).
3. **Generic search** for `…version…: x.y.z` fields (three parts or more) whose key is not a format/schema/preset/dependency, plus the highest `ChunkVersion`.
   These are shown as "(unverified)" and never produce a warning: e.g. BIAS X's `app_version` is the preset's version (1.0.0), not the plugin's (1.2.3 installed).
4. **Product generation from the plugin's name**: "Ozone 12", "RX 11 De-re", "Pro-Q 4", "AmpliTube 5". Compared with the number in the installed plugin's name.
   This gives the major generation only, labelled "(from name)". Plugins that put no number in their name (Auto-Tune Pro, UADx, Denoiser, EchoBoy) have nothing at this level.

When none of these exist the project file simply does not contain the plugin's version (checked: FabFilter `FFBS`, UADx `uapw_chunk_version`,
iZotope `Major/Minor Version` = state schema 1.1, Soundtoys and Native Instruments opaque data). No code path can recover what is not written.

Record layout was also checked for a version field: the ~40 bytes after the AU codes contain flags and a state size; the component version
integer does not occur at any fixed offset across 900+ records.

## Ableton Live sets (`.als`)

- A set is a gzip-compressed XML document; root `<Ableton MajorVersion="5" MinorVersion="12.0_12117" Creator="Ableton Live 12.1d1">`.
  Schema 5 covers Live 10 to 12. Verified by reading all 26 sets bundled with Live 12.4.6 (419 devices).
- Devices are the children of `<Devices>` elements. Built-in devices are elements such as `Eq8` or `Compressor2`; rack containers
  (`AudioEffectGroupDevice` and friends) are descended into but not listed. `PluginDevice` (VST2 and VST3) and `AuPluginDevice` carry a
  `PluginDesc` with `VstPluginInfo`, `Vst3PluginInfo` or `AuPluginInfo`; Max for Live devices are `MxDevice*`.
- Plugin state is hex text in `Buffer`/`ProcessorState`/`ControllerState`. For AU, the buffer is the same AU state plist as in Logic, so the AU codes and the saved-version
  rules above apply unchanged.
- **Not validated against a set containing third-party plugins**: none was available on the development machine, and the field names inside the plugin
  descriptors (`Name`, `Uid/Fields.0-3`, `Manufacturer`) come from the names present in Live's own binary and from the Live file format as commonly documented.
  The parser captures whatever leaf `Value` attributes the descriptor has, tries both byte orders for VST3 class IDs, and never guesses: an
  unmatched plugin is shown as Not installed or Uncertain.
- Installed versions for VST3/VST2 come from Live's own plugin database (`~/Library/Application Support/Ableton/Live Database/Live-plugins-N.db`, table `plugins`:
  `dev_identifier`, `name`, `vendor`, `version`), read read-only. Without Live installed, VST/VST3 bundles are matched by file name and reported as uncertain.


## Other hosts (v0.2.0): REAPER, Waveform, Ardour, GarageBand and MainStage

None of these could be validated against real files on the development machine. They are implemented from the file formats as documented or widely known, and the
parsers are defensive: anything unrecognised becomes an error or an "uncertain" row, never a confident wrong answer.

- **REAPER `.rpp`**: plain text. `<REAPER_PROJECT 0.1 "7.27/macOS-arm64" ...>` header gives the saving version. Effects are blocks
  `<VST|VSTi|AU|AUi|JS|CLAP|DX|LV2 "Format: Name (Vendor)" "file or Vendor: Name" ...` followed by base64 state lines and a closing `>`.
  AU entries carry the AU's declared "Vendor: Name" (matched exactly against installed components); VST/VST3/CLAP carry the bundle file name (matched to installed bundles).
  Vendor "Cockos" and JSFX are REAPER's own. State is base64-decoded and run through the same saved-version discovery as the other hosts.
- **Waveform `.tracktionedit`**: XML. `<EDIT appVersion="Waveform 12.0.5">`; `<PLUGIN type=vst|vst3|au|... name filename manufacturer uid>`. For AU, `filename` is a JUCE
  identifier `AudioUnit:Category/type,subtype,manufacturer`, which gives exact AU codes. Volume/level/aux plumbing is skipped; other types are listed as built-ins.
  Plugin state is JUCE's custom base64 and is not decoded.
- **Ardour `.ardour`**: XML. `<Processor type=lv2|vst3|audiounit|... name unique-id>` inside routes; other processor types (amp, trim, meter, ...) are Ardour's own and ignored.
  AU `unique-id` as `type-subtype-manufacturer` decimal numbers is used when present; otherwise AU and VST3 are matched by name and marked uncertain.
- **GarageBand `.band` / MainStage `.concert`**: packages are assumed to hold a Logic-style `ProjectData` (found at any depth up to 3, any capitalisation) and are read with the Logic parser,
  with an explicit "experimental" warning. Untested.

Matching and versions for all of these go through `HostResolver`: AU by codes (or exact "Vendor: Name"), VST/VST3/CLAP by bundle file name, saved versions by the
same four-step discovery as for Logic, built-ins versioned with the host app (installed host version found by bundle identifier or app name).


## FL Studio, Pro Tools and the unreadable ones (v0.3.0)

- **FL Studio `.flp`**: `FLhd` (len 6: format, channels, PPQ) then `FLdt` (size) and a stream of events. Event id < 64: 1 data byte; < 128: 2; < 192: 4; otherwise a
  7-bit little-endian varint size followed by that many bytes. Text events are ASCII or UTF-16LE with a NUL terminator. Used: 199 = FL version, 201 = a plugin's internal name,
  203 = its display name, 212/213 = plugin state. FL's own plugins appear as their internal names ("Sytrus", "Fruity Limiter"); channel types ("Sampler", "Audio Clip", "Layer") are ignored.
  Third-party VST/AU plugins are all "Fruity Wrapper": the plugin is named by event 203 and located by scanning the wrapper state for a path ending in `.vst3`, `.component`, `.vst`, `.clap` or `.dll`
  (ASCII or UTF-16LE). If no path is found the format is unknown and the app tries VST3, AU, then VST and marks the result uncertain. The wrapper's internal layout was **not** decoded.
- **Pro Tools `.ptx`** (v0.7.0): see the section at the end of this file. The text export below is also supported. Pro Tools' own "Export Session Info as Text" produces a tab-separated report starting `SESSION NAME:`. With the plug-in
  option it contains a "P L U G - I N S  L I S T I N G" table (MANUFACTURER, PLUG-IN NAME, VERSION, FORMAT, STEMS, NUMBER OF PLUG-INS) and every track has a `PLUG-INS:` line of `Name (stems)` entries.
  The listing's version is used as the "saved with" version. Installed AAX plugins are found in `/Library/Application Support/Avid/Audio/Plug-Ins` (and the per-user folder) by bundle name,
  trying "Manufacturer Name" first. A real small export (no plug-in listing) was available; the listing table is implemented from the known layout and tested synthetically.
- **Cubase `.cpr`, Nuendo `.npr`, Bitwig `.bwproject`, Cakewalk `.cwp`, Reason**: not parsed. The files are recognised so they can be listed with an explanation instead of silently ignored.
  Guessing at proprietary binary files would produce plausible but wrong plugin lists, which is worse than none.


## What was checked on real files (v0.4.0)

Public sample projects were used to check the parsers; they are not shipped in this repository (their licences differ), only tiny derived or hand-made fixtures are.

- **FL Studio 20.8.4 project**: confirmed event ids 199 (version), 201 (internal name), 203 (display name), 212/213 (plugin state). A third-party plugin is an event 201 `Fruity Wrapper`; its event-213 payload is
  `u32 type (8 or 10)` followed by chunks `{u32 id, u64 size, bytes}` with 51 = VST2 four-character ID, 53 = plugin state, 54 = plugin name, 55 = plugin path, 56 = vendor. The display name in event 203 can be generic
  ("VST2") or carry a suffix ("OTT (failed to load)"), so the chunk-54 name is preferred. Paths are as saved by the originating machine (Windows paths without extension for VST2).
- **REAPER 7.28 (macOS)**: FX blocks are `<VST "VST3: Name (Vendor)" File.vst3 0 "" id{CLASSID} ""` followed by base64 state. The state is written as several base64 segments, each closed by a `=`-padded line,
  so every segment is decoded separately. The plugin's own version is found in the state (Neural Amp Modeler: 0.7.12).
- **Waveform**: `<PLUGIN type=...>` with `vst` entries carrying `filename`, `name`, `manufacturer`, `uid`; built-in plugins are other `type` values (`8bandEq`, `comp`, `naturalReverb`), and `rack`/`volume`/`level` are structure.
- **Ardour**: `<Processor type="lv2" name=... unique-id=...>`; Ardour's own processors have types `amp`, `trim`, `meter`, `main-outs`.
- **LMMS**: `.mmpz` = 4-byte big-endian length + zlib stream; `<instrument name=...>`, `<effect name="ladspaeffect">` with the LADSPA plugin named in a `<key>` element.
- **Ableton**: sets from Live 9 (schema 4), 11 and 12 (schema 5); some are stored as plain XML rather than gzip, which is accepted.
- **DAWproject**: `project.xml` in a ZIP archive, validated with `xmllint --schema Project.xsd`. `Vst2Plugin`/`Vst3Plugin`/`ClapPlugin`/`AuPlugin` carry `deviceName`, `deviceVendor` and `pluginVersion`
  (the version the exporting DAW recorded, used as the saved version); built-ins are `BuiltinDevice`, `Equalizer`, `Compressor`, `NoiseGate`, `Limiter`.
- **Bitwig `.bwproject`** was looked at (`BtWg` header, hex-text fields, then typed binary records) but the plugin records could not be identified with confidence, so it is not read.


## Cubase, Nuendo and Bitwig (v0.5.0)

Checked on one real Cubase 10.5.20 project and one real Bitwig Studio 5.3 project from public repositories; neither is shipped here.

- **Cubase / Nuendo `.cpr`, `.npr`**: a `RIFF` file with form type `NUND` and a `ROOT` chunk holding a tree of named values. A key is a big-endian u32 length plus text and NUL; a string value is the
  2-byte type `00 08`, a u32 length covering the text, its NUL and a UTF-8 BOM, then the text. The saving application is in an `AppVersion` object ("Cubase" / "Nuendo" and "Version 10.5.20").
  Every plugin instance has a `Plugin UID` object (a `GUID` string: the VST3 class ID) followed by a `Plugin Name` value. Mixer plumbing (`Standard Panner`, `Input Filter`) is skipped; plugins named like
  Steinberg's bundled ones (Mystic, Prologue, Spector, MultiScope, MixConvert V6, the channel EQ, ...) are reported as built-ins. The class ID is not matched against installed plugins yet (names are).
- **Bitwig `.bwproject`**: `BtWg` + a hex-text header, then typed fields `00 00 <id> <type>`; strings have a u32 length. A VST3 device has field `0x0CE4` (class ID), `0x0C5E` (the plugin version that saved it) and
  `0x0199` (device name). The project ends with a ZIP archive of `plugin-states/<uuid>.vstpreset` files whose headers (`VST3`, version, 32-digit class ID) tie each state to its device.
  The saving version is the `application_version_name` entry of the `meta` object.
- **Reason `.reason`** (looked at, not read): an IFF-style header (`X15_FILE`, `FORM`/`CAT` chunks with the program version and the ReFill list) followed by a large region that is mostly `0xFE` bytes and
  high-entropy data; the devices live there and the encoding was not worked out. **Studio One and Cakewalk**: no sample project could be found, so nothing was attempted.


## Cubase, Bitwig, Studio One and Reason (v0.6.0)

- **Cubase / Nuendo, checked on 11 projects (SX 3 to 14)**: the layout is the same throughout. After the key `PAppVersion\0` (9 bytes on, 13 for a `RIF2` file) come one-byte-length tokens: application, `Version x.y.z`, release date, architecture
  (absent before 4.5). Each plugin is `Plugin UID\0`, 22 bytes, the 32-digit class ID token, `Plugin Name` and its value; for a renamed instrument track that value is the track title and the real name follows under `Original Plugin Name`.
  VST2 plugins appear as a wrapper class ID `"VST" + 4-character VST2 ID + 9 characters of the name` (`VSTsyl1sylenth1` for Sylenth1). The lists match the known contents of the public test projects of github.com/fgimian/cubase-project-plugins (MIT).
- **Bitwig, checked on 11 projects (Bitwig 2.4 to 5.3)**: besides the VST3 device records (fields 0x0CE4 class ID, 0x0C5E plugin version such as `2.0.5.0`, 0x0199 name), plugins are referenced by file path:
  `...\VST3\RapturePro_64.vst3`, `...\VSTPlugins 64 bit\Kontakt 5.dll` (VST2), and `...\library\devices\EQ-2.bwdevice` for Bitwig's own devices. Windows projects leave the name field empty and put the path just before the record.
- **DAWproject (official reference)**: `deviceID` is the VST3 class ID as a canonical UUID, the VST2 unique ID in decimal, or the CLAP plugin ID verbatim (AU has no defined form); `pluginVersion` is the plugin version; `<State path=...>` names the saved state
  inside the archive (`.vstpreset`, `.clap-preset`, FXB/FXP). Built-in devices are `BuiltinDevice`, `Equalizer`, `Compressor`, `NoiseGate`, `Limiter`.
- **Studio One native songs**: a ZIP whose plugin information is in `Song/song.xml`, `Song/mediapool.xml` and `Devices/audiomixer.xml` (see the reader's comments). Taken from a public community tool's source; no real song was available.
- **Reason**: an official Reason Studios example is the same song in four formats (`.reason`, Ableton `.als`, Logic `.logicx`, Pro Tools `.ptx`). In the `.reason` file a plain IFF-style header (`X15_FILE`, `FORM`/`CAT` chunks, program version, ReFill list) is followed by
  a `VS_V` / `BODY` / `RS1100` block: a constant header (`e7 1f de 31 00 00 40 00`) and then a high-entropy stream. The same block is what the Reason Rack Plugin stores as its plugin state inside the Ableton and Logic projects.
  Identical racks produce identical bytes (so it is compression, not per-save encryption), but none of zlib, raw deflate, gzip, bzip2, xz, LZMA (several parameter sets), simple XOR/rotation transforms, or searching for the
  stream's bytes in the other formats reproduces anything readable. The device list was therefore not recovered. The Reason Rack Plugin itself is listed correctly when it is used inside another DAW.


## Pro Tools sessions and auto-detected built-ins (v0.7.0)

- **Pro Tools `.ptx`, `.ptf`, `.pts`**: the file is lightly scrambled, not encrypted. Byte 0x12 holds the scrambling type (1 or 5) and byte 0x13 a key; the rest of the file is
  XORed with a 256-byte table derived from the key (the table differs by type). After unscrambling, the content is a tree of blocks: marker `5A`, a block type, a size and a content type,
  followed by child blocks. Content type 0x0003 holds the product and version that saved the session; content type 0x1017 holds one plug-in entry (name, manufacturer, AAX ID). Plug-in entries are read
  with bounds checks, so a damaged block gives a readable error rather than a wrong list. Avid's own plug-ins are recognised structurally: their AAX manufacturer ID is the
  host's own (`Digi`), and they are versioned with Pro Tools itself. Non-Avid AAX plug-ins are matched to installed `.aaxplugin` bundles by name.
- **No lists of plug-in names.** Built-in devices are never recognised from a hard-coded list, so a host update cannot make the app wrong:
  - Logic: the record's built-in marker (`GAME`) identifies the plug-in; its display name is read at run time from the `Plug-In Settings` folders inside the installed Logic app.
  - Ableton Live: any element in a track's device chain that is not a plug-in descriptor is built-in; its display name is read from the installed Live preset library.
  - Cubase / Nuendo: the slot's class (`Plugin isA`) says whether it is a VST plug-in or an internal one.
  - Waveform: built-ins are the plug-ins without a plug-in format attribute (last two per track, racks excluded); FL Studio: a plug-in is any event 213 entry; REAPER, Pro Tools: the host's own vendor.
  - DAWproject: any device element in `Devices` that is not a VST2/VST3/CLAP/AU element.
  If the host is not installed, the app still shows the name Logic or Live stored and says its version cannot be read.
