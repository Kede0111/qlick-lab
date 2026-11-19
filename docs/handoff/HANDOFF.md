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
  - [x] Group `macos/Sources/QlickLab` by role (commit ba510df): App, Library, Import, ContactSheet, Develop,
    Compare, Recipes, Export, Engine, Files, Design, Diagnostics. `Lab/` is gone.
  - [x] One theme: `Q` folded into `Theme` (Design/Theme.swift); the controls in Design/Controls.swift. The lab rooms
    now use the editor's values where QLab's were near: red sRGB #e5222b (was P3 0.89/0.11/0.14), dim #8a8a8f (was
    50 % grey), surface = panel #141415, hairline = line #28282a. Quentin checks the look in Qlick Lab Dev.
  - [x] Contract, step 1: the command names are typed (`Engine/EngineCommand.swift`) and checked on both sides
    against `crates/spektrafilm-native/commands.txt` (`EngineContractTests`, `commands_match_the_shared_list`).
    Found: `original` and `brightness_reference` are never sent by the app (candidates for wave 3's pruning).
  - [ ] Contract, step 2: `Codable` replies instead of `JSONValue` lookups (render, thumbnail, catalog, balance…),
    best done while splitting EditorModel, which holds 30 of the 34 requests.
- [ ] **Wave 3**: border geometry from Rust only (`Border.swift` duplicates `crates/spektrafilm-io/src/border.rs`);
  Swift 6 strict concurrency module by module; prune CUDA and unused targets, benchmarks out of shipped sources.
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

- Phase: architecture wave 1 done, committed on `refactor/architecture`. Tests: Rust 438 pass; Swift 488 run, 24 skipped, 1 failure that main has too (`QuickFrameLifecycleTests.testRapidFilmSwitchingDoesNotPileUpRenders`, 5 settled renders where it expects fewer): look at it in wave 2.
- Next: 0.1.5 on `feature/import-library` (branched from `refactor/architecture`). Remaining architecture work
  (EditorModel step 2, typed replies, wave 3) can continue on `refactor/architecture` in parallel.

## Build and test

```bash
scripts/build_app.sh --dev
cargo test --locked --release --workspace
cargo build --locked --release -p spektrafilm-native
SPEKTRAFILM_ROOT="$PWD" swift test --package-path macos --scratch-path target/swift-native
scripts/drive.sh start   # off screen, own home; on copies of photographs only
```
