# Plugin Lens

A native macOS app (Swift, SwiftUI, no third-party dependencies) that opens a Logic Pro project and lists every plugin it uses,
with the version installed on this Mac.

- Open a `.logicx` package, or a folder: it is scanned recursively for `.logicx` packages and extracted project folders.
- The sidebar lists projects. The detail pane shows name, path, last-modified date, and a sortable, searchable table:
  **Plugin, Manufacturer, Format, Saved with, Installed version, Version check, Status** (Installed / Not installed / Version unknown).
- **Saved with** is the plugin version the project was saved with; **Version check** compares it to what is installed (Same / Installed is newer / Installed is older).
- Missing and unknown-version rows are flagged with an icon and colour.
- **Copy as Markdown** and **Export CSV** for the selected project.
- A corrupt, unreadable or unsupported project shows its error in its own detail pane; other projects keep working.
- Scanning and parsing run off the main thread, with a progress bar.

## Build and run

Requirements: macOS 14+, Xcode 15 or later. No setup beyond opening the project.

```bash
open PluginLens.xcodeproj      # then Run (⌘R)
```

Or from the command line:

```bash
xcodebuild -project PluginLens.xcodeproj -scheme PluginLens -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project PluginLens.xcodeproj -scheme PluginLens -destination 'platform=macOS' test
```

Release builds are universal (arm64 + x86_64) and target macOS 14. The app is ad-hoc signed and **not sandboxed**, because it
must read arbitrary project folders and `/Library/Audio/Plug-ins`. Debug builds are active-architecture only.

`PluginLens.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, so you do
not need XcodeGen to build. To change targets or settings, edit `project.yml` and run `xcodegen generate`.

For scripted runs, the app accepts `--open <path>` to load a project or folder at launch.

## How it works

`ProjectData` is an undocumented, chunked binary format. The parser does not decode the whole file; it scans for plugin instance records
and validates each one. See [docs/FORMAT.md](docs/FORMAT.md) for the evidence and layout. In short, each record holds a
12-byte truncated name plus the plugin's AU manufacturer, type and subtype codes (stored byte-reversed). Logic built-ins use the same
layout with a `GAME` marker in place of the AU codes.

**Version lookup** reads installed bundles in `~/Library/Audio/Plug-ins/Components`, `/Library/Audio/Plug-ins/Components` and
`/System/Library/Components`, and uses `CFBundleShortVersionString`, falling back to `CFBundleVersion`.

Matching, in order:
1. **Exact** on the AU type + subtype + manufacturer codes declared in the bundle's `AudioComponents`. Names are not used because Logic truncates them to 11 characters.
2. **Uncertain**: same manufacturer code and exactly one component whose name starts with the stored name. Shown as "(uncertain)" and with status Version unknown.
3. **Not installed** otherwise.

If several installed bundles share the same codes but have different versions, the match is marked uncertain and no version is shown.

## Supported Logic versions

- Validated: **Logic Pro Creator Studio 12.2 (6644)** (57 projects, 113 ProjectData files).
- Anything saved by a newer major version opens with a warning. Older versions were not available to test; they may work if the record layout is unchanged.
- Legacy `.logic` projects are listed but reported as unsupported.
- When a package has several alternatives, the most recently modified one is read.

## Known limitations

- **Logic only hosts Audio Units**, so every third-party plugin in a project is AU. VST and VST3 can never appear as a project's format. The
  Format column shows `AU (+VST3 installed)` when a VST/VST3 bundle with the same name is also installed, and the row's tooltip lists its version (read from the bundle's Info.plist, including vendor sub-folders). That is informational only: a VST-only install does not count as installed, since Logic can't load it.
- **Saved versions exist only for plugins that record one.** Logic has no version field of its own; the app reads the version a plugin writes into its saved state (`pluginVersion`, `productVersion`, `PlugVersion`, `Version` conventions, see docs/FORMAT.md). Valhalla, Neural DSP, oeksound soothe2, Serum 2 and Superior Drummer do; FabFilter, UAD, iZotope, Native Instruments and others do not, and show "Not stored". Built-ins use the Logic version that saved the project.
- **Logic built-in plugins** have no AU codes in the project. They are listed with Logic's own version, and display names come from a small
  table (`BuiltInNames`); unknown ones show Logic's internal 11-character name.
- Plugin names are truncated to 11 characters in the project. Plugins that are not installed are shown by that truncated name and the four-character manufacturer code.
- The scan is a record scan, not a full parse. It does not know which track or slot a plugin is on, or whether it is bypassed. Duplicates are merged.
- AUv3 app-extension plugins are not found by bundle scanning, so they show as Not installed.

## Tests

Run `xcodebuild ... test` (52 tests). One extra check is opt-in and reads real projects: set `PLUGINLENS_PROJECTS` to a folder, or write its path to
`/tmp/pluginlens_projects_path`, and it loads every project and prints a `REALCHECK` summary (counts, failures, missing and unknown plugins).
On the author's library: 59 packages found, 55 loaded, 683 plugin records, 0 failures; the other 4 are never-saved "Untitled" stubs that contain only undo data
and are reported as such.

`Tests/PluginLensTests` covers the parser (real-record fixtures plus synthetic, truncated, garbage and corrupt input), version lookup
(against fake plugin bundles in a temp folder, so results don't depend on this machine), discovery, per-project failure isolation, and exports.

Fixtures in `Tests/Fixtures` are built by `Tools/make_fixtures.py` from real projects. Only the ~40 bytes of each plugin record are kept; track names,
text, plugin state and everything else are dropped (ProjectData never contains audio). `mixed_missing` has one plugin's manufacturer code rewritten
to `Zzzz` so it is guaranteed not to be installed.
