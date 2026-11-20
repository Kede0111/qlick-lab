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
- [x] R2 Drag and drop, copy/paste, menus (3a9aa24): one drop target for the sidebar's list (`App/SidebarDrop.swift`:
  rows report their frames, `SidebarDropDelegate`, `SidebarDropOverlay` = the row lit in red, the insertion line, the
  label "Move 12 photographs to “Rue”"; `.move`/`.copy`/`.forbidden` proposals give the cursor). What a drop does is
  planned in `Library/BoxMoves.swift` (`ProjectStore.plan` → `DropPlan`, `apply(DropAction)`), done by
  `LabState.perform` (`Library/BoxGestures.swift`), each gesture one ⌘Z (`undoable`: a snapshot of the Boxes and
  Archives, `LibraryEditsUndoTarget`; redo too). Photos from a Box/Roll move, ⌥ copies, from an Archive always copy;
  Archive/Folder rows refuse photos ("The disk is shown as it is…") — settles "Photos → an Archive row". Folder → Box
  makes a Roll (with the folders under it), Folder → Roll adds, Folder → another Archive joins it; Boxes nest (no
  cycles) and reorder, Rolls move/reorder, Archives reorder (`LabProject.order`). Spring-open 0.7 s, auto-scroll at
  the edges. Drag sources: contact sheet (AppKit session, pointer/loupe drag; the pencil's stroke leaving the sheet
  sideways becomes a drag, its marks taken back), Grid, film strip (`onDrag`), sidebar rows; the drag carries only a
  private type (`be.jackfrom.qlicklab.drag`, own process, none outside the app: no file can be moved by a drag).
  ⌘C keeps the selected photos (and copies edits as before); ⌘V in an open Box/Roll adds them when some aren't in it,
  else pastes edits; Paste in Box/Roll context menus. Menus: Add to Box (nested), New Box from Selection…, Remove from
  “…” in sheet/grid/strip/Develop menus and the Photo menu; ⇧⌘B pops the Box list at the pointer. A Finder folder on
  the window opens Import. Fixed: opening a Folder whose top level has no photos (tree not read yet) never shows
  "has no photographs" (it asks the disk); a list matches photos across /tmp vs /private/tmp spellings.
  Automation: `drop <what> ; <row> [; alt show at=]`, `editcopy`, `editpaste`, `boxtree`, `sheetmenu`, `dragimage`.
  Tests: 520 (`BoxMovesTests`). Not done: dragging from Compare's panes (they pan); real mouse drags can't be driven
  off screen, so the cursor and the SwiftUI `onDrag` on the sidebar's buttons were checked by code only.
- [x] R3 Remove… / Remove Rejected Photos… (03f7043): Move to Trash is gone from every menu (sheet, grid/strip,
  Develop, Photo menu; ⌘⌫'s silent delete too). ⌫ / Remove… and Remove Rejected Photos… (Photo menu, and a ⊖ by the
  Rejects count in the filter bar) open one dialog (`RemoveQuestion`, `Library/Remove.swift`): choices drawn as cards
  with a line each (`AppAlert.Button.detail`), Return on the safest: Remove from “Box/Roll” (when one is open),
  Remove from Qlick Lab (`ProjectStore.removed`, `removed.json` in the catalogue; `PhotoFolder.excluded` keeps them out
  of every listing, count and Folder tree; out of every Box; one ⌘Z; Archive menu › Restore Removed Photos (N)),
  Delete from Disk… (asks again: red `AppAlert.warning` "This deletes N photographs from the disk. They go to the
  Trash.", Return = Cancel; files and sidecars to the Trash via the old `delete(plan)`, undoable; a volume without a
  Trash refuses, never deletes outright). Duplicates alone: "Remove the Duplicate" (sidecar only). Removing everything
  listed closes the list; Undo opens it again. Automation: `removeask [rejected]`, `restoreremoved <archive>`,
  `archive addfolder <name>|<path>`. Tests: 524 (`RemoveTests`, the alert test rewritten).
  Note: automation commands aren't events, so two steps can share one undo group off screen (real keys are fine).
- [x] R4 Colour labels, keywords, title/caption (fe8d081): `PhotoWords` (label, keywords, title, caption) in each
  sidecar variant (`label`, `keywords`, `title`, `caption`; schema unchanged, unknown label kept) and in a DNG's XMP
  (`xmp:Label`, `dc:subject`, `dc:title`, `dc:description`, only once the lab writes them). `LibrarySummary.words`, so
  the rating machinery saves, undoes and redoes them (`changeLibrary(advancing:)`: words never auto-advance). Labels:
  keys 6–9 are `SheetAction`s (assignable in Settings › Shortcuts), purple in menus; Photo › Colour Label, and in the
  sheet / grid / strip / Develop menus; a round sticker at the top left in every view (sheet's four styles and its
  print, grid, film strip, Compare tag, sheet loupe, frame info, Develop bar menu). Own names in Settings › Colour labels
  (`LabelNames`). Keywords: `KeywordsPanel` over the contact sheet (toolbar tag, ⌘K) and the same `PhotoWordsEditor`
  at the top of Develop's information (⌘I): label dots, title, caption (one photograph), keyword chips (partial
  counts), Add Keyword (commas, ⌘K focuses it), keyword set ⌥1–⌥9 (Photo › Keywords; editable list), the catalogue's
  keywords with counts (`RollStats.keywords`, `ProjectStore.keywordCounts`) to add or filter. Filter bar: label dots
  + "without label", Keyword menu; Sort › Colour Label. **Crop moved from ⌘K to R** (plain key, off while typing; "r"
  reserved). Import's grid has no labels (its own marks only; label keys beep there). Automation: `label`, `keyword
  add|remove|set|ask|editset`, `keywordset`, `words`, `labelfilter`, `keywordfilter`, `title`, `sort`.
  Tests: 531 (`PhotoWordsTests`).
- [x] R5 Finding photographs (3d1d18c): the catalogue's index (`Library/CatalogIndex.swift`): every photograph of every
  Archive (removed ones aside), its file's facts (`FrameFacts`) and sidecar (marks, words, films, recipe, edit date),
  read off the main thread, several at once, cached in Caches/<bundle>/Catalog Index/<hash of the catalogue>.json, read
  again on any change (Archives, FSEvents trees, removed, the marks on screen) but only the files whose date/size
  changed; the marks given are laid over it at once (`adopt`). Sidebar's fixed entries (`FindingSection`): All
  Photographs, Last Import (`last-import.json` in the catalogue, written by both imports; before it, the ledger's last
  run), Picks, By Date (year › month › day with counts, `DateTree`); lists `LabView.all/.lastImport/.picks/.day/.found`
  (`Views/all`, `…/date/2026-09-19`). Field search (`Library/PhotoQuery.swift`, `PhotoQuery.parse` → `RuleGroup`):
  `rating:>=3 pick reject label:red film:portra camera:m11 lens:35 iso:>800 aperture:<2.8 shutter:1/250 date:2026-09
  imported:30d keyword:usa title:… name:… type:dng developed`, plain words, quotes, `-` to leave out, `a..b` ranges,
  several marks = either; a label's own name works. Used by the find bar (`LibraryFindBar`, over the sheet's filter bar
  and the grid's foot: search, Period, Film, Camera, Lens, Save as Smart Roll…; `LibraryFilter.search/period/film/
  camera/lens`, `recordRules`, `asRules`) and the library page (fields show the folders holding matches, "N photographs
  match" → Show on the Contact Sheet / Save as Smart Roll). Smart Rolls: `BoxRoll.rules` in boxes.json, all/any/none,
  nested groups; fields rating, flag, label, keyword, film loaded (card), film developed, recipe, camera, lens, focal,
  aperture, shutter, ISO, capture/import/edit dates, name, type, orientation, developed, title, caption, Archive, Folder,
  any text. Rule editor sheet (`Library/SmartRollEditor.swift`, live count); + › New Smart Roll… on the Boxes heading
  (into the Box “Smart Rolls”, made if needed) and in a Box's + and menu; Edit Rules… on the row; distinct icon. A Smart
  Roll refuses drops/paste/Add to Box, has no Remove from (openHolder is nil), and a Box shows its Smart Rolls'
  photographs. Recipes: the name of the recipe applied last is now kept in the sidecar (`variants[].recipe`). New Rolls
  by Day on Archive / Folder / Box menus (a Box named after it, one Roll per capture day, “Undated” if any). Sorts: Import
  Date (ledger, else when the Folder joined), Edit Date (sidecar's date). Automation: `fixed`, `day`, `unfold date`,
  `search`, `findfilter`, `savesmart`, `libsearch`, `found`, `smartroll new|ask|query|edit|open|done|cancel`,
  `rollsbyday`, `indexinfo`. Tests: 540 (`PhotoQueryTests`).
  Left / risky: an open computed list (Picks, a Smart Roll) follows the index when files change, not each mark given
  (reopen it); a photograph outside every Archive is searched by its file's facts as they're read; the first reading of
  a large catalogue takes a while (counts show once it's done).
- [x] R6 Import (cf9c44e): **Archive required** (`ImportSession.hasArchive`, blocker "Choose an Archive for these
  photographs, or a new one."): the panel's Archive row (`ArchiveChooser`) offers the Archives (most recently added to
  first) or a new one pre-named `suggestedArchiveName` ("R6 Card · 2026-11-20"; a `DCIM` folder takes its parent's name),
  editable; the Archive, Box/Roll and film card are cleared when another source opens (`lastSource`), kept for the same
  one; `importFolders` names the Archive after opening. "To Sort" is only a fallback for a journal from before 0.4.
  **Also in**: a Box or Roll (nested menu, Smart Rolls left out; `ImportOptions.boxID/boxRollID`, `holder`): the
  imported photographs are added there (`fileInHolder`), Open Imported opens it. **Folder Card** (film, camera, notes:
  `ImportOptions.film/camera/notes`, `card`) written on each Folder the import made or filled (`updateRoll` → `Roll.qlickroll`).
  New `ImportOptions` fields are optional so old saved options/journals decode. **Leave in Place** registers one
  Folder: the folder chosen (from a disk/card, the deepest common folder; `ImportSession.placeRoot`), so every
  sub-folder shows in the Archive's tree (checked at depth 4); a folder an Archive's Folder already holds isn't added
  again. **Structure** always visible, greyed in Leave in Place with "The photographs stay where they are: nothing is
  copied or renamed.": `ImportStructure` (By Day / Month / Year / Day and Job / One Folder / Custom) and `ImportNaming`
  (Camera's Names, Date_0001, Job_001, Date-Name, Date_Time, Custom) as radio lists (`ChoiceList`) with examples;
  Custom shows `TemplateEditor` (an AppKit field that keeps its cursor, `TemplateFieldHandle`; tag buttons year, month,
  day, month name, job, camera, lens, card, + seq, name, time for files; `ImportTemplate.insert`, `tags(forFiles:)`) and
  "“{x}” isn’t a tag the lab knows." The example line (`exampleLine`) under File Names, for the current frame or the
  first. Grid: TWICE (same name, size, capture time in the source: `ImportSession.twins`, the second left out while
  "Leave out what's already imported" is on), UNREADABLE (header not readable or empty file: `Facts.readable`), and a
  line under the toolbar (`ImportNotices`, each count toggles its filter: Duplicates / Unreadable). Colour labels at
  Import: `ImportMarks.label`, label keys, the dot in the cell, written with the marks. Automation: `import archive
  <name>|new`, `import box <Box › Roll>`, `import film|camera|notes`, `import label`; `import state` has archive,
  holder, twins, unreadable, example. Tests: 548 (`ImportOptionsTests`).
  Left: an unreadable file is still imported if left checked (on purpose: a damaged file from a card is better copied);
  the template field's cursor is kept from the last edit, a click elsewhere in it without typing isn't noted.
- [x] R7 Finishing (85d4ab3): **Custom Order** (`LibrarySort.Key.custom`, offered only while a Box or Roll is open,
  `Key.offered(manual:)`): Boxes and Rolls have their own sort (`LabState.boxSort`, key `qlick.boxSort`, Custom Order by
  default; `sort` reads/writes it while a Box/Roll is open, `listSort` elsewhere; File Name now really sorts a Box).
  Dragging photographs of the open Box/Roll on its contact sheet (`ContactSheetView` is a dragging destination) or its
  grid (`GridReorderDrop`) shows a red line where they'd go and puts them there (`ManualOrder.slot/bar/reordered`,
  `LabState.reorderOpen`, one ⌘Z; another sort switches to Custom Order): a Roll's own list is reordered, a Box keeps
  `LabBox.order` (everything it shows) in boxes.json. Paths are matched across `/private/tmp` vs `/tmp`
  (`ManualOrder.canonical`). **Stacks** (`Library/PhotoStacks.swift`): `PhotoStack` in `stacks.json` (catalogue,
  `StacksFile`; part of the undo snapshot), Photo › Stack ⌘G / Unstack ⇧⌘G / Open Stack–Close Stack / Stack Bursts
  (capture time < 2 s, same camera: `Stacking.bursts`), the same in every frame menu (`boxItems`, `BoxMenuItems`);
  Import's Safety has "Stack the bursts" (`ImportOptions.stackBursts`). `shownPhotos` collapses closed stacks
  (`LabState.stacked`, `Stacking.collapsed`) so sheet, grid, strip and Develop show the top with a badge (`StackBadge`,
  `ContactSheetRenderer.drawStack`: filled closed, outlined open). **`[` `]`** were already there (Photo › Rating ›
  Raise/Lower, one undo step; checked). **Auto Advance**: "Advance After Rating" renamed Photo › Auto Advance; ⇧ + a
  mark key (pick, reject, unmark, 0–5, label keys) marks then moves on once (`EditorWindowController.markAndAdvance` →
  `LabState.markAndAdvance`, `EditorModel.advanceOnce`) on the sheet, grid, strip and Develop. Import takes colour labels
  by key and menu now. Automation: `stack`, `unstack`, `stackopen`, `stackbursts`, `reorder <i,j> <slot>`,
  `markadvance <key>`, `raise`, `lower`, `autoadvance on|off`; `state` has order, sort, stacks, advance.
  Tests: 555 (`ManualOrderTests`).
  Left / risky: real mouse drags can't be driven off screen, so the drop line was checked by code and the reorder by
  automation; the film strip doesn't take reorder drops (sheet and grid do); rating a closed stack marks its top only;
  a stack's photographs removed or moved outside the lab stay listed in stacks.json (harmless).

- [x] R8 Box view, sidebar, the lab's icons (Quentin, 2026-11-20, after trying Dev: "a sub-Box and a Roll side by side on
  a strip like two photographs doesn't work at all"). **An open Box lists its own photographs only**; its Boxes and
  Rolls are on a **shelf** above them (`Library/BoxShelf.swift`: `BoxShelfItem`, `BoxShelfLayout` on the frames'
  columns, a Box one object wide (≥ 118 pt, several columns when frames are small), a Roll two; `LabState.openShelf`;
  `ContactSheet/BoxShelfView.swift`): a sub-Box is a pen-drawn **archive box** (hatched sides, hand hole) with a paper
  **label** bearing its name by hand (Noteworthy) and a red rule; a Roll is a **35 mm canister** (count printed as
  "N EXP", red band; a Smart Roll's red spark) with its first two photographs on the leader, cut to its tongue (none if
  empty). Names and counts under each. A click opens it; drag one out like a sidebar row; photographs, Boxes, Rolls
  dropped on one are planned and done as on its sidebar row (`ProjectStore.plan` + `perform`, label under it); context
  menu Open / New Box Inside / New Roll / Rename / Delete (Edit Rules for a Smart Roll). Contact sheet (all three
  strip styles and the light table: an NSHostingView in the heading's space, scrolls with the sheet) and Grid
  (`SheetLayout(header:)`). A Box with no photographs of its own says so under the shelf; an empty Box opens on an
  empty state (large archive box, New Box Inside… / New Roll…) instead of an error (`EditorModel.openList(allowEmpty:)`).
  Consequences: `ProjectStore.ownFrames(of:)` (the list shown, Custom Order, paste/add "already in" checks), Remove
  from a Box and a move out of a Box take the photographs out of the Box itself only (its Rolls keep theirs); the
  sidebar's count is still everything in the Box. **Sidebar**: Library is the first row of the list (opens the room;
  its arrow folds All Photographs, Last Import, Picks, By Date under it, `SidebarFold.Row.library`, open by default),
  then Archives and Boxes; the rooms above are Import, Contact Sheet, Develop, Compare, Recipes, Stocks. **Icons**: the
  lab's own glyphs drawn in code (`Design/LabGlyphs.swift`: `LabGlyph`, `LabGlyphView`, `LabSymbol` draws `lab.<name>`,
  else an SF Symbol): card (Import, Import's card sources), card with arrow (Last Import), prints (Library), print (All
  Photographs), torn film strip (Contact Sheet), aperture (Develop), eye with iris (Compare), flask (Recipes), canister
  and film (Stocks), canister (Roll), canister with red spark (Smart Roll), archive box (Archives), three-quarter box
  (Box), calendar (By Date), pencil ring (Picks). Original drawings in the spirit of Quentin's references (not traced;
  the references are not in the repo). Tests: 561 (`BoxShelfTests`: layout, own photographs vs shelf, glyphs inside
  their square; `QLICK_GLYPH_SHEET=<png>` renders every glyph at 14/16/20/48 pt). `ArchiveBoxTests` updated to the new
  rule (own photographs listed, removal from the Box itself).
  Left / risky: drops on the shelf and its hover were checked by code (same plan as the sidebar), not with a real mouse
  (off screen); the Develop film strip and Compare show a Box's own photographs only, with no shelf; the shelf isn't
  printed (Print… prints the photographs).

### Lab structure (branch `feature/lab-structure`, from `feature/import-library`)

Source: `docs/audit-philosophie.md` (sections 2 to 6, decisions in section 7). Quentin validated the six
recommendations on 2026-11-20, with these limits:
- Decision 4 (one recipe format shared with QLab): **postponed to the very end**, to discuss again. Don't start it;
  don't touch the QLab repository.
- Lot H (speed): **excluded**. Don't touch the render engine, the preview pipeline, the caches or the Rust engine.
  RedLamp's ideas come later, in a separate test branch.
- The red dot of the logo is kept (not a deviation).
- Decision 5: the shared red is QLab's, Display P3 (0.89, 0.11, 0.14), with its sRGB equivalent for AppKit.

Rules: local commits only, nothing pushed, `main` untouched; test with `scripts/build_app.sh --dev` only (never
`scripts/install.sh`); photographs on disk never moved or deleted; one commit per lot, tests green before each; what
is added in one view goes in every view that shows the same thing. After each lot: update this file and send Quentin a
short note; ask him first when a choice drifts from the philosophy.

Lots, in order:
- [x] A Housekeeping: Build Thumbnails / Build Previews / Stop All Background Work gone from the Lab menu and from
  every frame menu (sheet, grid/strip: the work happens by itself, the background pill keeps its Stop and Stop All;
  automation `buildthumbnails`/`stopall` kept); the Lab menu's catalogue items gone (File keeps them, with their
  keys); Settings has Photographs · Upkeep · Shortcuts: Speed folded into Upkeep (Previews: "Build previews ahead"
  tick, was Photographs › Viewer's "Previews ahead"; film previews; 12 MP; Export memory; Thumbnails; preview
  storage; Updates last); "Extend to 3:4 portrait" (help and the print note too; the sidecar key `instagram` kept);
  code and test comments no longer cite other apps (Lightroom, Capture One, Photoshop, Instagram), and NEgs only
  where it's a credit (About, CameraBrightnessReference's source, ControlHelp's sources, StockLibrary's profiles).
  The Rust comment in `spektrafilm-io/src/brightness.rs` left alone (lot H rule: no Rust). Tests: 561.
- [x] B Tokens: `macos/design-tokens.json` (colours with a doc line each, radii, motion, capital labels) is the one
  source; `Design/ThemeTokens.swift` (`Theme.Hex`, `Theme.P3`, `Theme.Radius`, `Theme.Motion`, `Theme.Caps`) is
  generated from it by `DesignTokensTests` (`QLICK_UPDATE_GENERATED=1 swift test --filter DesignTokensTests`), which
  also checks the AccentColor set and that the sRGB red is the P3 red converted. The red is QLab's: SwiftUI's
  `Theme.accent` and the sheet's pencil in Display P3 (0.89, 0.11, 0.14), AppKit and contrast checks in sRGB
  `#f8000a`. Surface `panel` #131314 (was #141415). `CapsLabel` 11 pt, tracking 0.11 × size; floating panels 26,
  dialog 22, glass cards 14, icon buttons 7. White on the red is 4.2 : 1 (test floor 4.0 for the main button's
  semibold capitals; told Quentin). Not in the QLab repository (decision 4 later). Tests: 564.
- [x] C Central selector: `LabPart` (library, lab, print; `rooms`, `firstRoom`, `of(room)`: the contact sheet is the
  Library's and the Lab's), `LabState.part`, `choose(_:)` (each part comes back to the room it was left in; Lab again
  switches Develop ↔ contact sheet), `toggleSheet()`, `show(_:in:)`. `PartSelector` / `PartSegment` (TitleBar.swift):
  a capsule in the middle of the window (a long trail pushes it right before its words give way), the chosen part
  white on the red, capitals; acts on mouseDown, no animation; the band hands its clicks over
  (`EditorWindow.sendEvent`, as for the crumbs). ⌘1/⌘2/⌘3 (Lab menu, top); Actual Size moved to ⇧⌘1. G is the one
  key between Develop and the contact sheet (View › Show Contact Sheet / Show Develop; Esc and E/Return as before).
  Sidebar: the part's rooms on top (Library: Import, Contact Sheet; Lab: Develop, Compare, Recipes, Stocks; Print:
  Print), then always the Library's fixed entries, Archives, Boxes. A provisional Print room (`Print/PrintWorkspace`,
  ⌥⌘8): count, Export…, Print Contact Sheet… (lot F fills it). Automation: `part <name>` (a press through the window),
  `togglesheet`; `state` has `part=`. Tests: 567 (`LabPartTests`).
  Found, not mine and left alone (lot H rule): after Develop → contact sheet, the open photograph's thumbnail on the
  sheet stays empty (also on the code before C: `room contactSheet`, `room develop`, `room contactSheet`).
- [x] D The Lab's shelf: `LabShelf` (Recipes/LabShelf.swift, `model.shelf`, `lab.shelf`): one system of favourites
  (ordered keys `film:<id>`, `paper:<id>`, `recipe:<shelfID>`) and hidden ones, in `<Application Support>/Shelf.json`
  (key `qlick`; tests: `.memory` or a defaults key). The tray's `favoriteFilms`/`favoritePapers`, the Stocks room's
  `qlick.favouriteStocks`, the recipes' `qlick.favouriteRecipes` (by name) and Settings' Fotufilm films come in once
  (`adoptFormer`, then `adopt(stocks:)`/`adopt(recipes:)` sort out kinds and names; Fotufilm "From datasheets"/"None"
  become hidden films). `Previews` reads and stars through the shelf. Recipes have an identifier: `PresetFile.shelfID`,
  kept by name in the Presets folder's `.ids.json` (follows a rename, new for a file copied in by hand, `setID` for
  bundles); a deleted recipe's marks go (`forget`). Hidden films, papers and recipes leave the trays and their tiles,
  menus (`listedFilms`, `listedPapers`, `listedPresets`), Develop's recipes, the frame menus, Compare, Import; the one
  in use stays listed. Recipes room: All / Favourites / Hidden N, search (name and film), Sort (Custom Order, Name,
  Film, Date Changed; `qlick.recipeSort`), Hide/Show in the menu and the detail, hidden cards dimmed. Stocks room:
  Hidden row, Sort (Maker, Name, Speed; `qlick.stockSort`), context menu, Hide/Show in the detail. Settings' Fotufilm
  films row gone. Automation: `hide|unhide <stock>`, `hide|unhide recipe <name>`, `favouriterecipe <name>`; `state`
  has `shelf=<favourites>/<hidden>`. Tests: 572 (`LabShelfTests`).
  Not done (lot G): Recipes and Stocks are still rooms of the Lab, not a drawer; the Develop recipes panel (⌥⌘P)
  stays until G decides the doors.
- [ ] E Export and import of recipes in a bundle (no shared QLab format).
- [ ] F The Print room.
- [ ] G Simplifications: Effects folded into Emulsion; one door per function; keywords and caption in the info
  card; Smart Rolls on one level; a sort bar at the foot of the sheet (All, Picks, Rejects, Unmarked, stars, Sort;
  audit 4.4).
- [ ] I Fine-line glyphs in `LabGlyph`, a word with each; for Rolls a provisional cartridge until Quentin's SVG.

## Current state

- Phase: **0.4 is done** (R1–R8; R8 from Quentin's first try of Dev). `feature/import-library` holds architecture waves 1–3, 0.1.5, 0.2, 0.3 and 0.4
  (local, nothing pushed, `main` untouched). Swift tests: 555 (24 skipped), all pass (561 after R8); the Rust side wasn't changed.
  Qlick Lab Dev is built from it (`dist/qlick-lab-dev/Qlick Lab Dev.app`).
- Phase: **lab structure** on `feature/lab-structure` (from `feature/import-library`, local). Lots A to D done; next is lot E.

## Build and test

```bash
scripts/build_app.sh --dev
cargo test --locked --release --workspace
cargo build --locked --release -p spektrafilm-native
SPEKTRAFILM_ROOT="$PWD" swift test --package-path macos --scratch-path target/swift-native
scripts/drive.sh start   # off screen, own home; on copies of photographs only
```
