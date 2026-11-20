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

- [x] **0.1.5** (branch `feature/import-library`, commits d951dfd → this one):
  - Arrivals: `LabProject.kind == .arrivals` (optional key, old catalogues read unchanged); `ImportRun.addRolls`
    files rolls there when no project is named, Add in Place too (it no longer asks for a name). Sidebar row on top
    with its count in red; `ProjectStore.moveRoll`, "Move to Project" in the sidebar and the library.
  - Sidebar rolls: "Rename, Film, Camera and Notes…" (the library's `RollEditor`), Move to Project.
  - "Recipe" in every interface text, menus and the engine's messages. Kept "Preset" where it isn't a look: white
    balance, chromatic aberration, section (grain/halation) presets. The on-disk folder is still `Presets`.
  - Stocks: one sidebar row and menu item for films and papers (`Workspace.ordered` drops `.papers`), a
    Films/Papers switch in `StockLibrary`; ⌥⌘6/⌥⌘7 kept.
  - Grid in the contact sheet room has the sheet's own bar (`SheetToolbar`), so the view switcher never moves.
  - File Names: Off / On the Edge / Under the Frame (`SheetOptions.fileNames`, menu in the sheet's bar): classic,
    compact, detail and Develop's film strip. Not yet: Compare, the Import grid, the editor's Grid cells.
- [x] **0.2** (on `feature/import-library`):
  - One counter: a segmented switch "The Photographs: Copy / Move / Leave in Place" heads the Import panel
    (`ImportModeChoice`; a card offers only Copy). `LabState.importFolders` opens the Import room on a single folder
    with Leave in Place and the project chosen (several folders at once are still added directly).
    `ImportOptions.projectID` keeps the project by identity (`ImportSession.chosenProject`, `choose(project:)`).
  - Import profiles are called "Saved Settings" in the interface (code: `profiles`, key `qlick.importProfiles`).
  - Back / Forward ⌘[ ⌘] in the Lab menu: `LabState.Place` (room + folder), noted by `show`, `open(folder:)`,
    `follow(mode:)`. The window title is the trail Project › Roll › file. Not yet: clickable crumbs.
  - The per-photo checkbox at Import STAYS (Quentin, 2026-11-19: he wants it back; the pencil-only commit 827b387
    was reverted in 44ae4be). Crossed frames are still left out by the "Leave out the frames crossed out" toggle.

### Quentin's feedback on 0.1.5 / 0.2 (2026-11-19, testing Qlick Lab Dev)

- Everything works. Keep the checkbox per photo at Import (done).
- "Lab Order" was unclear → renamed "Saved Settings" (done). Avoid lab metaphors where the plain word is clearer.
- The three big import cards looked worse than the old switch → replaced by one segmented switch with a line of
  help under it (done). He cares about polish: take care over looks, check screenshots with `scripts/drive.sh shot`.
- Merging into `main` and pushing to GitHub happen only when he says so, after everything is done and tested.

- [x] **0.3** (2026-11-19, on `feature/import-library`, one local commit each):
  - caf1b21 Clickable title trail: the earlier words are links (project → whole project, roll → its sheet), grey,
    white at the pointer; the last word stays and drags the window. `EditorWindow.sendEvent` hands a click on a
    link past the title bar (which keeps its clicks). `LabState.crumbs`, `TitleBand.crumbs`, `CrumbWord`.
    Automation: `crumb <i>`, `clickat <x> <y>`.
  - 89f379e Saved Settings in the catalogue: `saved-settings.json` (key `qlick`), `SavedImportSettings`; read when a
    catalogue opens, copied by Save Catalog As; the old preference `qlick.importProfiles` moves into the first one.
  - a90ecb1 Roll card `Roll.qlickroll` in the roll's folder (`RollCardFile`): name, film, camera, notes; unknown keys
    kept, newer schema left alone. Written 0.4 s after the last change, off the main thread; read when a folder
    becomes a roll and at each count (the card wins); rolls from before get one.
  - 2966441 Binder (`Library/Binder.swift`, `App/BinderSidebar.swift`): roots chosen with + (this Mac's, in
    preferences `qlick.binderRoots`), read off the main thread (folders with photographs or leading to some, depth 5,
    3000 folders at most, hidden folders and packages skipped), followed by FSEvents. Amber dot: folder of photographs
    in no project; amber ring: folded folder holding one. Click opens it on the sheet; menu: Import…, Add to
    Project, Show in Finder, Remove from the Binder. Import's "Recent" list is gone: the Binder's roots are listed
    there; the old Recent folders seeded the Binder once.
  - f1da86c Selections: `LabProject.kind == .selection` with `frames` (paths). Add to Selection / Remove from it in
    every frame menu (sheet, grid, strip, Develop), a Selections section in the sidebar, naming sheet in selection
    mode. A whole project and a selection are *lists* (`PhotoFolder.register(list:sources:)`, named
    `<catalogue>/Views/<id>`, never made on disk); the library lists each source folder once and watches each
    (`PhotoFolder.folders(of:)`); `EditorModel.openList`. The old `Views/` folders of links are deleted at load.
  - fba08a4 `FrameCanvas` (Compare/FrameCanvas.swift): the Compare room's canvas in the sheet's loupe and Import's
    loupe (camera | recipe as the canvas's split) and comparison: wheel, pinch, Fit, 100 %, linked panes.
    `ImportKeys` take NSEvents too. `CGImage.turned(_:)` for Import's rotations. Not done: Import's *grid* is still
    its own (SwiftUI cells with the checkbox); moving it onto the contact sheet's view needs the sheet to read
    something other than the library (a data source), a large change left for later.
  - 1a4a002 File Names in the Grid (along the picture's foot: the grid packs rows edge to edge), Import's grid and
    comparison, the Compare room's panes; File Names menu in Import's and Compare's bars.

### Left for later (0.3 follow-ups)

- Import's grid on the contact sheet's own view (see above).
- A roll's card isn't copied by an import that copies a folder (Copy/Move write new folders).
- A selection keeps paths: a frame whose folder is moved or renamed outside the lab drops out (no bookmark per frame).
- Binder: no rename/move of folders from the sidebar; roots aren't per catalogue.
- Names Binder, Arrivals, Selection, Stocks to review with Quentin once he has tried them.

### Library redesign, 0.4 (validated by Quentin 2026-11-20; proposal: https://claude.ai/artifact/5hWWwsb6vN6pvNfq56qxUa)

Quentin found 0.3's Binder / Arrivals / Selection confusing and wants one organisation, sorted by drag and drop.
**These decisions are his; follow them exactly.**

THE DISK RULE (his "point d'honneur"): the app never moves, renames or deletes an image, except (1) the import,
which creates folders and copies (Move mode: originals of the card to the Trash after verification, kept), and
(2) the explicit Remove dialog below. Writing metadata IS allowed: XMP inside DNG ("Inside DNG files" stays), `.qlick`
sidecars, import `.xmp`, `Roll.qlickroll` cards.

Structure (sidebar, top to bottom; corrected by Quentin 2026-11-20 during R1: Boxes are their own section, not inside
Archives, and they nest):
- Fixed entries: **All Photographs**, **Last Import**, **Picks**, **By Date** (year › month › day).
- **Archives** (was "Project"; name decided: Archive). One per import subject ("Leica M11", "Voyage en Espagne"),
  renamable. An Archive holds only its **Folders**: the imported disk locations, shown as a READ-ONLY tree with every
  sub-folder at every depth, live (FSEvents), with counts. A folder keeps its card (film, camera, notes,
  `Roll.qlickroll`). Dropping photos on a Folder is refused (row stays dark, a line says the disk is shown as it is).
  One can work directly in an Archive or a Folder without any Box.
- **Boxes**: a second, separate top-level section (like Projects and Binder were): one list of Boxes for the whole
  catalogue. A Box holds photos directly, **sub-Boxes to any depth** (like collection sets: "Espagne" › "Madrid" ›
  …), and **Rolls** (a Roll is a leaf holding photos). Opening a Box lists its own photos plus everything under it.
  A photo can be in any number of Boxes/Rolls, from any Archive (references, never copies). **Smart Rolls**: a Roll
  filled by rules. Sub-Box from a Box's context menu and its +.
- Gone: Binder (and its amber dot), Arrivals, Selections, Import's Recent list (replaced by recent Archives' locations).
- Conversion of old catalogues (once, automatic, nothing on disk moves): Project → Archive; its rolls → Folders;
  Arrivals → an Archive "To Sort"; each Selection → a top-level Box of the same name; Binder roots preference dropped.

Gestures (every one undoable with one ⌘Z, a label during the drag says what will happen, e.g. "Move 12 photos to
Rue" / "Copy 12 photos to Rue"):
- Photos → Box or Roll: added (no duplicates).
- Photos from a Roll/Box → another Roll/Box: **MOVED** (leave the first); with **⌥ held: COPIED** (in both). The
  cursor/badge must show which (copy = the green "+" drag cursor and the label "Copy"; move = plain arrow, "Move").
- **⌘C / ⌘V** between Rolls/Boxes: paste ADDS (never moves).
- Photos → an Archive row: was "into its Box To Sort"; since Boxes are no longer inside Archives, to settle with
  Quentin in R2. Photos in a Box/Roll grid: reorder by
  hand (manual order).
- Archive Folder → a Box: creates a Roll in that Box holding the folder's photos (virtual; `createRoll(frames:)`).
- Roll → another Box: moves the Roll; Box → another Box: nests it. Boxes, Rolls, Archives reorder in the sidebar by drag.
- Folder → another Archive: the folder joins that Archive (nothing moves on disk).
- Finder folder → Archive or window: opens Import on it.
- Closed rows spring open after 0.7 s while dragging; the sidebar auto-scrolls near its edges.
- Menus too: Add to Box (⌘⇧B), New Box from Selection, Remove from Box.

Removing (the only deletes besides the import's Move):
- "Move to Trash…" disappears everywhere. In its place: **Remove…** (⌫, for the selection) and **Remove Rejected
  Photos…** (Photo menu, and a button by the rejected filter). Both open ONE clear, visible dialog that names the count
  and offers: **Remove from Qlick Lab** (out of the catalogue: its Archive listing and every Box; files untouched;
  catalogue exclusion list, undoable) or **Delete from Disk** (files to the Trash) — the latter with a second, explicit
  confirmation in red words: "This deletes N photographs from the disk." Never a silent delete.

Sorting tools to add: colour labels (red, yellow, green, blue = keys 6–9, purple; nameable), keywords (panel with list
and counts, ⌘K, keyword sets ⌥1–9) stored in XMP/sidecar, editable title/caption, `[` `]` rating steps, Shift+key =
mark and advance (auto advance), sort by import date / edit date / label / manual order, filters for label, keyword,
film, camera, lens, period + "Save as Smart Roll", field search (`rating:>=3 pick film:portra camera:m11 lens:35
iso:>800 date:2026-09 keyword:usa label:red`), Smart Rolls (all/any/none rules over rating, flag, label, keyword,
film loaded, film developed, recipe, camera, lens, focal, aperture, shutter, ISO, dates, name, type, orientation,
developed), **New Rolls by Day** (a Box with one Roll per capture day, virtual), burst stacks.

Import: **Archive required** (existing, or new pre-named "M11 · 2026-11-19"), optional destination Box/Roll, film card
fields (film, camera, notes → each created Folder's card), the source tree kept at every depth, structure options
always visible (greyed with a line in Leave in Place: "The photographs stay where they are: nothing is copied or
renamed"): By Day (2026/2026-09-19), By Month (2026/2026-09), By Year (2026), By Day and Job, One Folder, Custom with
buttons inserting tags (year, month, day, month name, job, camera, lens, card; unknown tag flagged); file names: camera's,
Date_0001, Job_001, Date-Name, Date_Time, Custom with the same buttons; an example line
(`L1004394.DNG → Photos/2026/2026-09-19/20260919_0001.DNG`); flag duplicates inside the source and unreadable files.

Steps (one local commit each, tests, `scripts/drive.sh` screenshots checked, Dev rebuilt, this file updated):
- [x] R1 Structure (0a245de): Archives › Folders (read-only tree at every depth, `FolderTrees`, FSEvents, counts) and
  Boxes as their own section (`boxes.json`, `BoxesFile`; Boxes nest to any depth, each holding photos and Rolls),
  conversion at load, new sidebar (`App/ArchiveSidebar.swift`, `SidebarFold`), naming sheet (`NamingSheet`), Add to
  Box / Remove in every frame menu (`Library/Boxes.swift`), crumbs Archive › Folder › file and Box › … › Roll › file,
  Import's source column lists the recent Archives' folders. Code types kept: `LabProject` = Archive, `LabRoll` = a
  Folder entry (an imported location, or a folder under one once its card is written), `ProjectStore`. Lists:
  `LabView` (archive / folder / box / roll) named under `<catalogue>/Views/…`. A folder added is added whole (no more
  split into one roll per folder of photographs). Archive files are schema 2 (an older app leaves them alone).
  Automation: `archive`, `box`, `boxroll`, `folder`, `unfold`. Tests: 510.
  Left: the tree's + on hover isn't drivable off screen (checked by code only); a folder in two Archives belongs, for
  crumbs, to the one with the deepest Folder; "Photos → an Archive row" (gesture list) to settle in R2; the README's
  screenshots still show projects.
- [ ] R2 Drag and drop, move vs ⌥ copy with visible cursor, ⌘C/⌘V paste-adds, menus, reorder, spring-open.
- [ ] R3 Remove… / Remove Rejected Photos… dialog; Move to Trash removed.
- [ ] R4 Colour labels, keywords panel, editable title/caption.
- [ ] R5 All Photographs, Last Import, Picks, By Date, field search, Smart Rolls, New Rolls by Day, filters, sorts.
- [ ] R6 Import options above.
- [ ] R7 Manual order polish, burst stacks, `[` `]`, auto advance.

## Current state

- Phase: `feature/import-library` holds architecture waves 1–3, 0.1.5, 0.2, 0.3 and 0.4's R1 (local, nothing pushed,
  `main` untouched). Swift tests: 510 (24 skipped), all pass; the Rust side wasn't changed. Qlick Lab Dev is built
  from it (`dist/qlick-lab-dev/Qlick Lab Dev.app`).
- Next: the library redesign 0.4 above, R2 → R7, on `feature/import-library`. Merge into `main` and push only when
  he says so.

## Build and test

```bash
scripts/build_app.sh --dev
cargo test --locked --release --workspace
cargo build --locked --release -p spektrafilm-native
SPEKTRAFILM_ROOT="$PWD" swift test --package-path macos --scratch-path target/swift-native
scripts/drive.sh start   # off screen, own home; on copies of photographs only
```
