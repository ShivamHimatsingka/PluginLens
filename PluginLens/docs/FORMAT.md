# Phase 1 findings: Logic Pro `ProjectData` format

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

## Plugin version information
**Not stored in the project.** The `version` key inside embedded plists is always 0 (it is the AU state-format version). The
installed ValhallaRoom is 2.0.5 (AudioComponents version 0x00020005) and Pro-Q 4 is 4.01 (0x00040001). Neither value appears in their records.
So the "installed version" can only come from the installed bundle, and we cannot report which version the project was saved with. I will not
claim a "version mismatch" in the UI.

## Not determinable / risks
1. Full chunk grammar (lengths, nesting). Extraction is a record scan with validation, so it can miss records in unusual layouts.
2. Plugin names are truncated to 11 characters. Matching must use the AU type/subtype/manufacturer triple against each installed
   component's `AudioComponents` array in `Info.plist` (an exact match), with name only as a fallback.
3. Raw byte scanning gives false positives inside audio or state blobs (e.g. random `aufx` lookalikes). The parser must check the
   12-byte name field is printable ASCII, the layout bytes match, and the triple is plausible.
4. Built-in display names and per-plugin versions are not available. Their version is effectively Logic's own version.
5. Software instruments in channel strips, and plugins on the master or aux, appear in the same record style. I have not verified which
   slot or track each belongs to, and bypassed or empty slots are not distinguished.
6. Only Logic 12.2 samples were available. Older or newer-format projects are untested.
7. **Logic Pro hosts only Audio Units.** VST and VST3 can never appear as project plugins. The requested "VST/VST3" format column will always
   be AU or Logic built-in unless you want it to mean "a VST3 build of the same plugin is also installed". That is a decision for you.
8. Many Logic projects here have 0 third-party records (e.g. `Band_Live_Performance_2026`, `Final export`), which is plausible but means built-ins only.
