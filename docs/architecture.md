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
| `spektrafilm-gpu` | The same pipeline on the GPU (wgpu: Metal on the Mac, Vulkan on Linux); WGSL in `spektrafilm-shaders` |
| `spektrafilm-io` | Reading and writing images: RAW (with `vendor/rawler`), colour spaces, ICC, XMP, borders (their numbers in `border::geometry`, written to `Develop/BorderGeometry.swift` for the preview), lens |
| `spektrafilm-native` | The app's helper: the JSON-lines protocol (`enum Command` in `src/main.rs`) |
| `spektrafilm-cli` | `spektrafilm` (GPU, f32) and `spektrafilm-f64` (CPU reference) for exports |

The GPU export is measured against the 64-bit CPU reference in the tests (ΔE00 under 0.25).

## The app (`macos/Sources/QlickLab`)

One folder per role. AppKit and SwiftUI live side by side inside them (the editor came first in AppKit; what the lab
added is mostly SwiftUI).

| Folder | What's in it |
|---|---|
| `App/` | Start, menus, windows, the rooms and navigation (`LabState`, `LabShell`, `Sidebar`, `TitleBar`), settings, shortcuts, updates, automation for `scripts/drive.sh`, background work |
| `Library/` | Folders, catalogues (`Catalogs`, `.qlicklab`), projects, the library grid and film strip, marks and ratings, thumbnails, previews and proxies, deleting |
| `Import/` | The Import room: `ImportSession`, plan, copier, journal, `ImportRun` (adds rolls) |
| `ContactSheet/` | The contact sheet: layout, renderer, view, loupe, print, grease pencil |
| `Develop/` | Editing state (`EditorModel.swift` holds the state, `EditorModel/EditorModel+<Concern>.swift` the work, one file per concern), parameters, the inspector and ink sliders, preview canvas, crop, borders, tone graph, histogram |
| `Compare/` | The Compare room |
| `Recipes/` | Recipes (presets), section presets, films and papers |
| `Export/` | Batch export and its finishing |
| `Engine/` | The helper process and its JSON lines (`Engine.swift`, `JSONValue`), the command names (`EngineCommand`) and typed replies (`EngineReplies`) |
| `Files/` | Sidecars (`Sidecar.swift`) and the DNG's XMP (`DNGMetadata.swift`): [sidecar-format.md](sidecar-format.md) |
| `Design/` | `Theme` (Theme.swift), the one set of colours, type and sizes; `Controls.swift`, the controls shared with QLab |
| `Diagnostics/` | Benchmarks run by environment variables; compiled in debug builds and with -DSPEKTRAFILM_BENCHMARK, never in release |

## The Swift ↔ Rust contract

The Rust side is typed (`enum Command`, serde). The command names are listed once in
`crates/spektrafilm-native/commands.txt`, which a test on each side checks (`commands_match_the_shared_list`,
`EngineContractTests`). The render and thumbnail replies are typed in Swift (`RenderReply`, `ThumbnailReply`):
read leniently at run time, decoded strictly against the real helper in `EngineContractTests`. Other replies (the
catalog first) are still read as `JSONValue` with string keys. Requests are still built as `JSONValue` objects.

The app target is checked for concurrency at the complete level, as warnings (Swift 5 language mode).

## Data (`data/`)

Film and paper profiles (`profiles/`, with where each comes from), spectral tables, recipes shipped with the app
(`presets/`), borders, and the frozen sidecar defaults (`sidecar-defaults/v<n>.json`, never edited once released).

## Files the lab writes

`.qlick` beside each photograph, or the DNG's XMP; `.qlicklab` catalogues; previews and proxies in Application
Support under the bundle identifier. XMP namespace `http://ns.jackfrom.be/qlicklab/1.0/`.
