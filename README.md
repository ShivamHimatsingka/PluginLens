# Plugin Lens

**See every plugin a Logic Pro project uses, which version it was saved with, and what you have installed now.**

Plugin Lens is a small native macOS app (Swift + SwiftUI, no dependencies). Point it at a `.logicx` project, or a folder full of them, and it lists
each plugin with its manufacturer, format, the version the project was saved with (when the plugin records one), the version installed on
this Mac, and whether they match. It is read-only: it never modifies a project and makes no network requests.

![Plugin Lens showing a project's plugins](docs/screenshot.jpg)

## Why

Before you open a project on another machine, hand it to a collaborator, or update your plugins, you want to know what it needs.
Logic only tells you after it fails to load something. Plugin Lens answers up front: what's missing, what's changed since the project was saved, and what
Logic itself will substitute.

## Features

- Open a project, or a folder (scanned recursively for `.logicx` packages and extracted project folders).
- Sidebar of projects; one bad project never blocks the others, its error is shown in its own pane.
- Table: **Plugin, Manufacturer, Format, Saved with, Installed version, Version check, Status**. Sortable and searchable.
- Missing plugins and version changes are flagged (red/orange).
- **Copy as Markdown** and **Export CSV** per project.
- Scanning and parsing run in the background with a progress bar.
- Works for any plugin from any manufacturer: plugins are matched to installed bundles by their Audio Unit codes (type, subtype, manufacturer), not by name.

## Install

1. Download `PluginLens-0.0.1-macOS.zip` from the [Releases](../../releases) page and unzip it. It is a universal build (Apple Silicon and Intel), macOS 14 or later.
2. The app is ad-hoc signed and **not notarized**, so macOS will block the first launch. Right-click the app, choose **Open**, then **Open** again; or run:

   ```bash
   xattr -dr com.apple.quarantine PluginLens.app
   ```

Or build it yourself (below).

## Build

Requires macOS 14+ and Xcode 15 or later. No other setup.

```bash
open PluginLens.xcodeproj        # then Run (⌘R)
```

```bash
xcodebuild -project PluginLens.xcodeproj -scheme PluginLens -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project PluginLens.xcodeproj -scheme PluginLens -destination 'platform=macOS' test
```

`PluginLens.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, so XcodeGen is only needed
if you change targets or settings. The app is not sandboxed because it must read arbitrary project folders and the system plugin folders.
For scripting, `--open <path>` loads a project or folder at launch.

## What the columns mean

| Column | Meaning |
|---|---|
| Plugin / Manufacturer | From the installed bundle when found; otherwise Logic's (truncated) name and the 4-character manufacturer code. |
| Format | `AU`, or `Logic built-in`. `(+VST3 installed)` means a same-named VST/VST3 is also installed (Logic can't load it, so it's informational). |
| Saved with | The plugin version recorded in the project, if the plugin records one. Built-ins show the Logic version that saved the project. |
| Installed version | `CFBundleShortVersionString`, falling back to `CFBundleVersion`, of the matching bundle. |
| Version check | Same / Installed is newer / Installed is older / Can't compare / Not stored. |
| Status | Installed / Not installed / Version unknown. A match that isn't certain is labelled *uncertain* and never reported as a confident version. |

## How it works

Logic's `ProjectData` file is undocumented. Plugin Lens was built by inspecting real projects and does not decode the whole file; it finds
plugin records and validates each one. Details and evidence are in [docs/FORMAT.md](docs/FORMAT.md). In short:

- Each plugin instance is a record holding a truncated 11-character name and the AU manufacturer, type and subtype codes (byte-reversed).
  Logic's own built-in plugins use the same record with a marker instead of AU codes.
- **Installed lookup** reads `AudioComponents` from bundles in `~/Library/Audio/Plug-ins/Components`, `/Library/Audio/Plug-ins/Components`,
  `/System/Library/Components`, and Audio Unit v3 app extensions in `/Applications` and `~/Applications`. VST/VST3 folders are checked for the informational note.
- **Saved version.** Logic stores each plugin's saved state in the project, but has no version field of its own. Some plugins write their version into
  that state, and Plugin Lens reads the conventions it has seen:

  | Convention | Seen in |
  |---|---|
  | `pluginVersion="x.y.z"` (JUCE XML state) | Valhalla, Neural DSP, oeksound soothe2 |
  | `"productVersion":"x.y.z"` | Serum 2 |
  | `PlugVersion x.y.z` | Toontrack |
  | `###NeuralAmpModeler###` header + version | Neural Amp Modeler and derivatives |
  | `Pianoteq x.y.z/…` banner | Pianoteq |

  Many plugins store state in a binary, compressed or vendor-specific form with no version in it (checked, for example: FabFilter, Universal Audio UADx,
  iZotope, Native Instruments, Soundtoys, Bertom). For those the column shows "—" and the check says **Not stored**. That is a limit of the project file, not of the app.
  Version-like numbers that describe the *state format* (XML declarations, `ChunkVersion`, preset schema versions) are deliberately ignored.

## Supported Logic versions

Developed and validated against projects saved by **Logic Pro Creator Studio 12.2** (about 60 real projects). Other versions are untested: projects saved by a newer major
version open with a warning, and older `.logic` (pre-`.logicx`) projects are listed as unsupported. If a project doesn't read correctly, please open an issue with the
Logic version and, if you can share it, the output of `xxd` on the first 128 bytes of `Alternatives/000/ProjectData`.

## Known limitations

- Logic hosts only Audio Units, so VST and VST3 never appear as a project's format.
- Names inside a project are truncated to 11 characters; plugins that aren't installed are shown by that name and the manufacturer code.
- Logic built-ins have no AU codes: only a few have friendly display names, the rest show Logic's internal short name, and their version is Logic's.
- Plugins are found by scanning for records, not by fully parsing the project, so the app doesn't know which track or slot a plugin is on, or whether it is bypassed. Duplicates are merged.
- When a project has several alternatives, the most recently modified one is read.
- Never-saved "Untitled" projects contain only undo data and are reported as having no project file.

## Tests

54 unit tests: parser (real-record fixtures plus synthetic, truncated, garbage and corrupt input), saved-version extraction, version lookup against fake plugin
bundles in a temp folder (so results don't depend on your machine), discovery, per-project failure isolation, and exports.
Fixtures in `Tests/Fixtures` are built by `Tools/make_fixtures.py`: only about 40 bytes per plugin record are kept; track names, text, plugin state and everything else
are dropped (ProjectData never contains audio). `mixed_missing` has one manufacturer code rewritten so it is guaranteed not to be installed.

An opt-in check runs against your own library: set `PLUGINLENS_PROJECTS` to a folder and run the `RealProjectsCheckTests` test.
It prints a summary and fails if any project fails unexpectedly.

## Contributing

Issues and pull requests are welcome. The most useful contribution is a new saved-version convention for a plugin you use:
add a pattern to `SavedVersionExtractor`, a test, and a line in the table above. Please only describe plugin state you have inspected yourself.

## Disclaimer

Plugin Lens is an independent project, not affiliated with or endorsed by Apple. "Logic Pro" and "Audio Units" are trademarks of Apple Inc.
The project file format is reverse-engineered and may change in any Logic update.

## License

[MIT](LICENSE)
