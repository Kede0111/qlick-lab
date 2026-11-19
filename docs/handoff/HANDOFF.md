# Handoff: the work in progress

Read this first, then `CLAUDE.md` and `docs/architecture.md`. Update it at the end of every phase (keep it short).

## Ground rules (Quentin, 2026-11-19)

- **Local only.** Nothing is pushed to GitHub until Quentin says so. `main` is never changed.
- Work happens on local branches: `refactor/architecture` (from `main` at `fc6cb1e`, 0.1.4), then
  `feature/import-library` branched from it. One local commit per phase.
- **Never overwrite the installed app.** Don't run `scripts/install.sh` during this work. Test builds:
  `scripts/build_app.sh --dev` → `dist/qlick-lab-dev/Qlick Lab Dev.app` (bundle id `be.jackfrom.qlicklab.dev`: its
  own preferences and Application Support). Tell Quentin to open that one.
- Talk to Quentin in French; the app's interface stays in English.
- To go back: `git checkout main`.

## Sources

- Architecture audit (slides): https://claude.ai/artifact/Ue5xMa8gbrKiJi8km2FQ1F
- Import and library audit (slides): https://claude.ai/artifact/TtjpR4WXPKeewLDVHPG3To

## Plan

### Architecture (branch `refactor/architecture`)

- [x] **Wave 1**: dead references fixed (`package_macos_app.sh` → `build_app.sh`; upstream design notes listed in
  `docs/README.md`), `docs/sidecar-format.md`, `docs/architecture.md`, `CONTRIBUTING.md`, CI workflow
  (`.github/workflows/ci.yml`, local, not pushed), `--dev` build, this file.
- [ ] **Wave 2**, one commit each, behaviour unchanged:
  - [x] Split `EditorModel.swift`, step 1: one file per concern in `Develop/EditorModel/EditorModel+<Concern>.swift`
    (22 files); `Develop/EditorModel.swift` keeps the stored state (867 lines, was 6 144). Save and export settings
    moved to `Export/ExportSettings.swift`. Cost: `private` members of EditorModel became internal so the files see
    each other. Behaviour unchanged, same tests.
  - [ ] Split, step 2: lift the concerns with their own state into their own `@Observable` models owned by
    EditorModel (thumbnails, batch export, print balance, camera brightness first), which brings `private` back.
    Not started (wave 3 stopped before it): batch export already keeps its state in `BatchRun`, but its 360 lines
    reach into the editor's engine, settings and sidecars, and the thumbnails' into rendering and the match; each
    lift wants its own careful commit and a look at what SwiftUI observes.
  - [x] Group `macos/Sources/QlickLab` by role (commit ba510df): App, Library, Import, ContactSheet, Develop,
    Compare, Recipes, Export, Engine, Files, Design, Diagnostics. `Lab/` is gone.
  - [x] One theme: `Q` folded into `Theme` (Design/Theme.swift); the controls in Design/Controls.swift. The lab rooms
    now use the editor's values where QLab's were near: red sRGB #e5222b (was P3 0.89/0.11/0.14), dim #8a8a8f (was
    50 % grey), surface = panel #141415, hairline = line #28282a. Quentin checks the look in Qlick Lab Dev.
  - [x] Contract, step 1: the command names are typed (`Engine/EngineCommand.swift`) and checked on both sides
    against `crates/spektrafilm-native/commands.txt` (`EngineContractTests`, `commands_match_the_shared_list`).
    Found: `original` and `brightness_reference` are never sent by the app (candidates for wave 3's pruning).
  - [~] Contract, step 2 (9c1e2d7): `RenderReply` and `ThumbnailReply` (`Engine/EngineReplies.swift`) for the
    render and thumbnail/decode replies; read leniently at run time as before, decoded strictly against the real
    helper in `EngineContractTests`. Left: the catalog (read in many shapes), balance_print, place_exposure,
    prepare_balance, tone_curve, save, and typed *requests*.
- [x] **Wave 3** (2026-11-19, one commit each):
  - 23c38a7 The known failing test, `testRapidFilmSwitchingDoesNotPileUpRenders`, was timing-bound, not a bug: on an
    M4 Max a quick frame takes 16 ms and the settled 6 MP frame 98 ms, so with clicks 150 ms apart every film settled
    (correct). Each next film is now chosen while the previous quick frame is with the helper (`willRender`).
  - 8a56917 Border geometry from Rust alone: `spektrafilm-io::border::geometry` holds the numbers; the test
    `border_geometry_swift_is_current` writes/checks `Develop/BorderGeometry.swift`
    (`QLICK_UPDATE_GENERATED=1 cargo test -p spektrafilm-io border_geometry` after changing them). The 35mm strip
    already shared `data/borders/35mm/frames.json`.
  - c3cc80b Pruned: CUDA backend and kernels, unused Metal shader sources, the wasm32 browser presentation
    (`ChainOutput::Present`, `display_present.wgsl`, canvas/view types), `data_fs`'s registered files, Windows-only
    BLAS fallbacks/cache folder/example; Linux Vulkan kept. Commands `original` and `brightness_reference` removed
    (Rust, commands.txt, `EngineCommand`). Benchmarks compile in debug builds and with -DSPEKTRAFILM_BENCHMARK,
    never in release. Still browser-shaped but inert natively: `ImagePool` (pools nothing outside wasm),
    `release()`/`transient()` no-ops, `MaybeSendSync`, the `web-time` crate and vendor/rawler's web_time patch
    (dropping them means un-patching rawler).
  - 8662eb6 The workspace version follows `scripts/version` (0.1.4; exported EXIF Software now says
    "spektrafilm 0.1.4"); `build_app.sh` keeps it in step (not with --dev), a test fails if they differ.
  - b91ffa1 Strict concurrency `complete` for the app target (Package.swift and project.yml), as warnings in the
    Swift 5 language mode: 47 of 48 warnings fixed. Left: `stillWanted` in `EditorModel+CameraBrightness.swift`
    (a main-actor local function capturing `weak self` passed to the nonisolated `solveBrightnessMatch`; making it
    `@Sendable` isn't allowed for a main-actor local function — restructure as a small `@MainActor` check object
    or pass the ids and re-check on the main actor). Then: the test target (a few warnings, e.g. SidecarTests),
    then `swift-tools-version: 6.0` / `SWIFT_VERSION = 6` and fix what the language mode adds (Sparkle callbacks,
    `@preconcurrency` imports to revisit, the `nonisolated(unsafe)` observer properties could become isolated
    deinit once the deployment target allows).
  - 9c1e2d7 Typed replies (see Contract, step 2).
- Not to do: rewrite the app in Rust.

### Import and library (branch `feature/import-library`, after wave 1 at least)

Quentin's answers to the audit's four questions: **yes to all.** Names Binder, Arrivals, Selection, Lab Order,
Stocks are kept for now (to revisit once the result is in place); a `.qlickroll` card in each roll folder is fine;
the pencil replaces the checkbox at Import (crossed = not imported); start with 0.1.5. Keep the analog darkroom theme.

- [ ] **0.1.5**: view switcher fixed in place for Classic / Compact / Detail / Grid (Grid uses the contact sheet's
  bar); "File Names: Off / On the edge / Under the frame" in every view; Arrivals (catalogue box for rolls imported
  without a project, fixes the lost-roll bug in `ImportRun.addRolls`); "Recipe" everywhere (no "Preset"); Films and
  Papers as one "Stocks" room; rename and move a roll from the sidebar.
- [ ] **0.2**: one Import counter (Copy to my disk / Move / Leave where they are), every entry point opens it
  (`LabState.importFolders` goes through `ImportSession`); project kept by UUID not name; Lab Orders in the catalogue;
  the pencil instead of checkboxes; breadcrumb in the title bar with Back/Forward ⌘[ ⌘].
- [ ] **0.3**: Binder (disk roots, live tree); living projects (move rolls, `.qlickroll` card); Selections; the contact
  sheet reads a list of photos (no symlink folder); Import reuses the contact sheet's grid, loupe and compare.

## Current state

- Phase: architecture waves 1–3 committed on `refactor/architecture` (local, not pushed; `feature/import-library`
  doesn't have wave 3 yet). Tests at 9c1e2d7: Rust 440 pass (`cargo test --locked --release --workspace`);
  `cargo build --locked --release -p spektrafilm-native` builds; Swift 491 run, 24 skipped, 0 failures.
- Next: EditorModel step 2 and the rest of the typed replies; the last concurrency warning, then Swift 6 mode.
  0.1.5 continues on `feature/import-library` (rebase or merge wave 3 into it when convenient).

## Build and test

```bash
scripts/build_app.sh --dev
cargo test --locked --release --workspace
cargo build --locked --release -p spektrafilm-native
SPEKTRAFILM_ROOT="$PWD" swift test --package-path macos --scratch-path target/swift-native
scripts/drive.sh start   # off screen, own home; on copies of photographs only
```
