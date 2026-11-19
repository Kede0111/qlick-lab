# How Qlick Lab is built

Two processes that talk in JSON lines: a native Mac app in Swift, and an engine in Rust.

```
┌──────────────────────────────┐   JSON, one line per message    ┌──────────────────────────────┐
│ Qlick Lab.app (Swift)        │ ──────── stdin / stdout ──────▶ │ spektrafilm-native (Rust)    │
│ AppKit: Develop, editor,     │ ◀──── replies + preview files ─ │ render, thumbnails, proxies, │
│   library grid, export       │                                 │ balance, tone curve, save…   │
│ SwiftUI (Lab/): contact      │                                 │ started once, one command at │
│   sheet, import, compare,    │                                 │ a time                       │
│   recipes, catalogues        │   at each export                ├──────────────────────────────┤
│                              │ ──────── a new process ───────▶ │ spektrafilm / spektrafilm-f64│
└──────────────────────────────┘                                 │ GPU 32-bit or CPU 64-bit     │
                                                                 └──────────────────────────────┘
```

The engine runs apart so a GPU failure never closes the app, and closing its stdin frees its memory.

## The Rust workspace (`crates/`)

Layers, each depending only on those above it:

| Crate | Role |
|---|---|
| `spektrafilm-math` | Numerics: interpolation, spectra, colour maths |
| `spektrafilm-model` | Film and paper profiles, the spectral model's data types |
| `spektrafilm-core` | The simulation: exposure, development, print, scan, grain, halation; presets (recipes); RAW prep |
| `spektrafilm-gpu` | The same pipeline on the GPU (wgpu/Metal); WGSL in `spektrafilm-shaders` |
| `spektrafilm-io` | Reading and writing images: RAW (with `vendor/rawler`), colour spaces, ICC, XMP, borders, lens |
| `spektrafilm-native` | The app's helper: the JSON-lines protocol (`enum Command` in `src/main.rs`) |
| `spektrafilm-cli` | `spektrafilm` (GPU, f32) and `spektrafilm-f64` (CPU reference) for exports |

The GPU export is measured against the 64-bit CPU reference in the tests (ΔE00 under 0.25).

## The app (`macos/Sources/QlickLab`)

Today the files are grouped by where they came from, not by role: the root holds the inherited editor (AppKit),
`Lab/` what the lab added (SwiftUI), `Lab/Import/` the import. The plan is to group them by role (App, Develop,
Library, Export, Engine, Design); see [handoff/HANDOFF.md](handoff/HANDOFF.md).

| Concern | Where |
|---|---|
| Start, menus, windows | `Main.swift`, `MainMenu.swift`, `EditorWindowController.swift`, `Lab/LabMenu.swift` |
| The rooms and navigation | `Lab/LabState.swift` (`Workspace`, open, show), `Lab/LabShell.swift`, `Lab/Sidebar.swift`, `TitleBar.swift` |
| Editing state | `EditorModel.swift` (6 000+ lines, to be split), `Edits.swift`, `Parameters.swift`, `Session.swift` |
| Develop panel | `Inspector.swift`, `InkSlider.swift`, `InkControls.swift`, `Lab/Develop*.swift` |
| Preview and canvas | `PreviewCanvas.swift`, `Previews.swift`, `RenderedPreviewCache.swift`, `Crop.swift`, `Border.swift` |
| Contact sheet and library | `Lab/ContactSheet*.swift`, `Lab/LibraryHome.swift`, `LibraryGrid.swift`, `Library.swift`, `PhotoBrowser.swift` |
| Marks and ratings | `PhotoMarks.swift`, `Lab/GreasePencil.swift`, `RejectCross.swift`, `Selection.swift` |
| Catalogues and projects | `Lab/Catalogs.swift` (`.qlicklab`), `Lab/Projects.swift` |
| Import | `Lab/Import/` (`ImportSession` is the import room; `ImportRun` adds rolls; journal, copier, plan) |
| Recipes, films, papers | `Presets.swift`, `PresetInspector.swift`, `Lab/RecipesWorkspace.swift`, `Lab/StockLibrary.swift` |
| Export | `BatchExport.swift`, `Lab/ExportFinisher.swift`, `Engine.swift` (export processes) |
| Talking to the engine | `Engine.swift` (helper process, JSON lines, `JSONValue`) |
| Sidecars | `Sidecar.swift`, `DNGMetadata.swift`: [sidecar-format.md](sidecar-format.md) |
| Look | `Theme.swift` (`Theme`, the editor's tokens) and `Lab/QTheme.swift` (`Q`, QLab's tokens): two themes, to merge |
| Background work | `Lab/BackgroundWork.swift`, `Lab/ProxyMaker.swift`, `Lab/PreviewBuilder.swift` |
| Testing hooks | `Lab/Automation.swift` (driven by `scripts/drive.sh`) |

## The Swift ↔ Rust contract

The Rust side is typed (`enum Command`, serde). The Swift side reads replies as `JSONValue` with string keys, so a
renamed key only fails at run time. Planned: Swift `Codable` types for each command and reply, and a contract test
that runs both sides.

## Data (`data/`)

Film and paper profiles (`profiles/`, with where each comes from), spectral tables, recipes shipped with the app
(`presets/`), borders, and the frozen sidecar defaults (`sidecar-defaults/v<n>.json`, never edited once released).

## Files the lab writes

`.qlick` beside each photograph, or the DNG's XMP; `.qlicklab` catalogues; previews and proxies in Application
Support under the bundle identifier. XMP namespace `http://ns.jackfrom.be/qlicklab/1.0/`.
