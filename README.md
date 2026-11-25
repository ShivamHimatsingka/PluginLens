# Plugin Lens

**See every plugin a DAW project uses, which version it was saved with, and what you have installed now.** Logic Pro, Ableton Live, REAPER, FL Studio, Pro Tools (via its text export), Waveform, Ardour, LMMS and DAWproject (Bitwig, Studio One, Cubase, Nuendo exports).

Plugin Lens is a small native macOS app (Swift + SwiftUI, no dependencies). Point it at a project, or a folder full of them, and it lists
each plugin with its manufacturer, format, the version the project was saved with (when the plugin records one), the version installed on
this Mac, and whether they match. It is read-only: it never modifies a project and makes no network requests.

![Plugin Lens showing a project's plugins](docs/screenshot.jpg)

## Why

Before you open a project on another machine, hand it to a collaborator, or update your plugins, you want to know what it needs.
Your DAW only tells you after it fails to load something. Plugin Lens answers up front: what's missing, and what has changed since the project was saved.

## Features

- Open a project, or a folder (scanned recursively for `.logicx` packages, extracted project folders and `.als` sets; Live's `Backup` folders are skipped).
- Sidebar of projects; one bad project never blocks the others, its error is shown in its own pane.
- Table: **Plugin, Manufacturer, Format, Saved with, Installed version, Version check, Status**. Sortable and searchable.
- Missing plugins and version changes are flagged (red/orange).
- **Copy as Markdown** and **Export CSV** per project.
- Scanning and parsing run in the background with a progress bar.
- Works for any plugin from any manufacturer: plugins are matched to installed bundles by their Audio Unit codes (type, subtype, manufacturer), not by name.
- Finds the saved version by itself, using several independent methods (below), and says how sure it is.

## Supported DAWs

| DAW | Files | Checked against |
|---|---|---|
| Logic Pro | `.logicx` | About 60 real projects saved by Logic Pro Creator Studio 12.2. |
| Ableton Live 9-12 | `.als` | The 26 sets bundled with Live 12.4.6 and three public sets (Live 9, 11, 12). Third-party plugin entries were checked only through Live's own plugin database, not on a real set that contains them. |
| REAPER | `.rpp` | A real REAPER 7.28 (macOS) project with a VST3 plugin, and one more public project. Plugin state and saved versions are read from it. |
| FL Studio | `.flp` | A real FL Studio 20.8.4 project with native plugins and wrapped VST2 and VST3 plugins. |
| Waveform (Tracktion) | `.tracktionedit` | Three public edits (built-in plugins, VST plugin entries, racks). |
| Ardour, Mixbus | `.ardour` | Two public sessions (LV2 and built-in processors). AU and VST3 processors, as saved on macOS, were not seen. |
| LMMS | `.mmp`, `.mmpz` | Four public demo projects. |
| DAWproject (Bitwig Studio, Studio One, Cubase, Nuendo and others export it) | `.dawproject` | The official schema (`Project.xsd`); no real exported file was available, only a schema-valid sample. |
| Pro Tools | `.txt` from File > Export > Session Info as Text | A small real export. The plug-in listing table (manufacturer, name, **version**, format) is covered by hand-written examples only. |
| GarageBand, MainStage | `.band`, `.concert` | **Experimental.** Read with the Logic parser on the assumption that they share its project format; no real file was available. |

Where a row says something wasn't checked, the support follows the format as documented and is covered by unit tests, and unrecognised content gives an error
or an *uncertain* row, not a confident wrong answer. If a project is read wrongly, please open an issue (the DAW version and the first lines of the file are enough).

**Listed but not readable.** These are shown in the sidebar with an explanation so you can see they were skipped: Pro Tools sessions (`.ptx`: export Session Info as Text instead),
Cubase (`.cpr`), Nuendo (`.npr`), Bitwig (`.bwproject`), Studio One (`.song`), Cakewalk (`.cwp`) and Reason. For Bitwig, Studio One, Cubase and Nuendo the simplest route is to
export the project as a **DAWproject** file and open that.

## Install

1. Download `PluginLens-0.4.0-macOS.zip` from the [Releases](../../releases) page and unzip it. It is a universal build (Apple Silicon and Intel), macOS 14 or later.
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
- **Saved version.** No DAW writes one universal "plugin version" field, so Plugin Lens looks in several places, most trustworthy first,
  and reports where it found each value and how reliable it is:

  | # | Source | Shown as | Check |
  |---|---|---|---|
  | 1 | The AU state's own `version` field. AU plugins built on Apple's base classes store their component version there (Neural Amp Modeler, Gateway) | `0.7.13` | compared exactly with the installed component |
  | 2 | A version the plugin writes into its saved state under a known convention: `pluginVersion="x.y.z"` (Valhalla, Neural DSP, soothe2), `"productVersion"` (Serum 2), `PlugVersion` (Toontrack), `Pianoteq x.y.z/…`, plus any of these inside zlib-compressed state | `2.0.5` | Same / Installed is newer / Installed is older |
  | 3 | A generic search of the state for `…version…: x.y.z` fields (excluding format, schema, preset and dependency versions) and the highest Antares `ChunkVersion` | `1.0.0 (unverified)` | **Unverified**: shown, never judged |
  | 4 | The product generation in the plugin's name: "Ozone 12", "RX 11", "Pro-Q 4", "AmpliTube 5" | `12 (from name)` | **Same major** / Different |

  If none of these exist the project does not contain the plugin's version (this was checked by decompressing and inspecting the state of
  FabFilter, Universal Audio UADx, iZotope, Native Instruments, Soundtoys and others), the column shows "—" and the check says **Not stored**.
  Nothing can recover a value that was never written.

## Supported versions

**Logic Pro**: developed and validated against projects saved by **Logic Pro Creator Studio 12.2** (about 60 real projects). Other versions are untested: projects saved by a newer major
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

109 unit tests: Logic parser (real-record fixtures plus synthetic, truncated, garbage and corrupt input), Ableton sets (gzip, XML, racks, VST3 class IDs, the Live database), REAPER/Waveform/Ardour projects, saved-version discovery, version lookup against fake plugin
bundles in a temp folder (so results don't depend on your machine), discovery, per-project failure isolation, and exports.
Fixtures in `Tests/Fixtures` are built by `Tools/make_fixtures.py`: only about 40 bytes per plugin record are kept; track names, text, plugin state and everything else
are dropped (ProjectData never contains audio). `mixed_missing` has one manufacturer code rewritten so it is guaranteed not to be installed.

An opt-in check runs against your own library: set `PLUGINLENS_PROJECTS` to a folder and run the `RealProjectsCheckTests` test.
It prints a summary and fails if any project fails unexpectedly.

## Contributing

Issues and pull requests are welcome. Another DAW is a good first contribution: write a parser that returns a `HostDocument` of `FoundPlugin`s (see `HostFormats.swift`; REAPER's is about 80 lines), and `HostResolver` does the matching, versions and checks. Or add a saved-version convention for a plugin you use:
add a pattern to `SavedVersionExtractor`, a test, and a line in the table above. Please only describe plugin state you have inspected yourself.

## Disclaimer

Plugin Lens is an independent project, not affiliated with or endorsed by Apple or Ableton. "Logic Pro" and "Audio Units" are trademarks of Apple Inc.; "Ableton Live" is a trademark of Ableton AG.
The Logic project format is undocumented and may change in any Logic update.

## License

[MIT](LICENSE)
