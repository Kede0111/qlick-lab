# Handoff

A snapshot for the next agent, not a log: **rewrite it** at the end of each phase (state, branch, next, gotchas),
under about 120 lines. History lives in `git log`, `CHANGELOG.md` and the docs. Read it, then `CLAUDE.md` and
`docs/architecture.md`.

## State (2026-11-24)

- **0.2.1** (`scripts/version`). On 2026-11-24 Quentin had every waiting branch merged into `main` and pushed, still
  0.2.1 (no new release): Auto White Balance per photograph (PR #8), Import's Type menu, Library on the photograph in
  hand, lighter exports. Installed in /Applications from that `main`.
- **Updates are on** (Sparkle 2.10, EdDSA): every build but the Dev copies carries `SUFeedURL`
  (`releases/latest/download/appcast.xml`) and `SUPublicEDKey`. `scripts/make_dmg.sh` signs with the key in Quentin's
  login Keychain. **Every release attaches both the DMG and `appcast.xml`**, or installed apps see nothing new.
- Talk to Quentin in French; the interface stays in English. Commit, push and release only when he says so.
- Try work in progress in the Dev copy (`scripts/build_app.sh --dev`, bundle id `be.jackfrom.qlicklab.dev`).

## Just done: one engine and shared formats with QLab (merged from `common-recipes`, 2026-11-23)

QLab (iPhone) develops with this repository's engine: a git submodule pinned to a commit, built for iOS (Accelerate on
iOS too, `crates/*/Cargo.toml`). Both apps share `.qrecipe` recipes and `.qsidecar` sidecars, `docs/q-formats.md` (the
same file in QLab: change both together). Here: `Recipes/QRecipe.swift`, `PresetLibrary` (migration of `.json` to
`.qrecipe`, ids in the header), `Files/Sidecar.swift` (`.qsidecar`, `.qlick` still read), `QFormatsTests`. Raising the
engine means raising QLab's submodule too (`vendor/qlick-lab`, then its `scripts/build_qengine.sh`).
`scripts/build_app.sh` writes `QlickEngineRevision` (this commit) into Info.plist.

Then (branch `iphone-import`): Import's "iPhone · QLab". `crates/qlick-iphone` (a helper of its own, JSON lines:
watch, probe, pair, list, pull, request-delete, put-recipe, remove-recipe), `Import/PhoneTransport.swift` (the
interface and `IdeviceTransport`), `Import/PhoneImport.swift` (devices, transit folder chosen in Settings or the
caches, deletion request), `ImportRunner.copyCompanion` (a photograph's `.qsidecar` or `.qlab.json` travels with it),
`ImportSession.developments`/`developed` (QLab's developments shown before the import), `Recipes/PhoneRecipes.swift`
and `PhoneRecipesPanel.swift` (the Recipes room's iPhone section; the last exchanged revisions per iPhone in
`PhoneRecipeSync`; `PresetLibrary.overwrite`). `scripts/build_app.sh` builds and bundles the helper. Automation:
`import phone [udid]`, `import recipes read|bring|send|both|delete <name>|state <file>`.
Edit Recipe, Auto White Balance / Auto Exposure and Apply Recipe's Develop groups are on main (`Recipes/RecipeParts.swift`,
`EditorModel.labAuto`, `PresetLibrary.replace` stamps a new revision). Not done: combining two recipes.
Next: show which engine revision a file names when it differs from the lab's own.

## Merged: Import's Type menu (2026-11-24)

Beside "Show:", a "Type:" menu appears when the source holds more than one kind of file (`ImportFileType`:
RAW, JPEG, HEIF, TIFF, PNG, Other; a RAW + JPEG pair counts in both). Show narrows the grid to one kind on top of
the Show filter (`ImportSession.fileType`); Import › "RAW Only" checks every frame holding that kind and unchecks the
rest (`importOnly`), and with pairs also sets the panel's RAW + JPEG choice (RAW only / JPEG only; Every Type: both).
The per-frame checks stay as they are. Automation: `import type raw|all`, `import only raw|all`.
Tried in the Dev copy. HEIF isn't read by the lab yet (`PhotoFolder.extensions`), so it never appears today.

## Merged: Library opens on the photograph in hand (2026-11-24)

From Develop or Print, Library (⌘1, the title band's selector) opens the contact sheet of the Folder, Box or Archive
the photograph was opened from, the photograph ringed and scrolled into view, instead of the room the Library was
left in (its overview, Import): `LabState.choose`. Tried off screen with `drive.sh` (a Roll, a Box, from Print) and
built as Qlick Lab Dev in the worktree's `dist/`.

## Merged: lighter exports (2026-11-24)

From the export audit (deck https://claude.ai/artifact/RjgD4g4SMuC6oGH9MZPTqi; his HEIF at quality 100 weighed 140 MB
for a 72 MB M11 DNG). Measured on that DNG, grain on: HEIF 90 38 MB, JPEG 92 23 MB, TIFF 8-bit 113 MB, 16-bit 317 MB.
- Engine (`spektrafilm-io/src/save.rs`, `metadata.rs`): TIFF is Deflate + horizontal predictor (lossless, parallel
  strips); every file carries a print resolution (`SaveOptions.ppi`, 300 by default: TIFF/EXIF XResolution, JPEG JFIF,
  PNG pHYs) and `Software` "Qlick Lab <version>" (`SaveOptions.software`; QLab can pass its own). CLI `--ppi`, `--software`.
- App: `SaveSettings` holds `heifQuality` (90, at most 95: Apple's encoder goes near lossless above) apart from
  `jpegQuality` (92), `ppi`, and is Codable (a batch journal keeps all of it in `BatchOptions.saveSettings`: batches
  used to drop sharpening and metadata). First format JPEG, TIFF starts at 8 bits.
- Pipeline (`ExportFinisher.deliver`): the engine writes in the scratch folder (local disk), then finishing (HEIF,
  sharpening, metadata) and the lab's XMP, written once to a hidden file beside the destination, renamed onto it.
  Fast exports of HEIF or sharpened files now use the preview too (6 s for a 60 MP HEIF).
- `LabXMP`: inside the file only (no sidecar): `qlick:Film`, `qlick:Paper`, `qlick:Recipe`, `xmp:Rating`,
  CreatorTool, keywords/title/caption, and creator/rights from the photograph's import `.xmp`; Metadata › None keeps
  only the lab's fields. ImageIO copies the image bytes (PNG gets an iTXt chunk). `ExportRating.embed` uses it.
- Print: File › Order (`Print/LabOrder.swift`: Proof JPEG 90 2048 px sRGB screen-sharpened; Scan HEIF 90 full P3;
  Print TIFF 8-bit full sRGB 300 ppi glossy), per-format Quality lists, Sharpen for; Image Size › Resolution and
  "Prints at" (cm). The line over Export and the save panel end with the estimated weight (`ExportEstimate`: table
  measured on the M11 file, then learned from this Mac's exports).
- Measured, not done: a better JPEG encoder (optimised Huffman gains 2 % on grain; mozjpeg would add a C dependency).
- Known: a sharpened JPEG goes through Core Image, which writes 4:2:0 (the engine's own JPEG is 4:4:4).
- Automation: `exportas <path> [fast]` (Print's choices), `order proof|scan|print`.

## Next, after that (none started)

- Swift 6: strict concurrency is `complete` as warnings; one left (`stillWanted` in
  `EditorModel+CameraBrightness.swift`), then the test target, then `SWIFT_VERSION = 6`.
- `EditorModel` split, step 2: lift thumbnails, batch export, print balance, camera brightness into their own
  `@Observable` models (one careful commit each).
- Engine contract, step 2: typed replies for the catalog, balance_print, place_exposure, prepare_balance,
  tone_curve, save; typed requests.
- Import's grid on the contact sheet's own view (needs a data source other than the library).
- Small, known: a roll's card isn't copied by an import that copies a folder; a selection keeps paths (a folder moved
  outside the lab drops its frames); Locate Folder doesn't search a whole disk; the sheet's toolbar icons have no
  word beside them; `solveBatchMatch` still re-reads a sidecar on the main thread.

## Gotchas

- **Disks** (`Files/VolumeReach.swift`, rule in `CLAUDE.md`): offline = not in the mount list (`getfsstat`
  `MNT_NOWAIT`, kept by `EVFILT_FS`) or a share the Mac says stopped answering (`VQ_NOTRESP`/`VQ_DEAD`). Slow is
  never offline. A catalogue opens on the main thread only if its disk answers within 5 s. FSEvents streams run on
  their own queue, never the main one (a version on the main queue froze the Mac on a slow NAS). Debug:
  `QLICK_SLOW_VOLUME`, `QLICK_GONE_VOLUME`.
- **After a commit on the Data SSD, run `sync`**: a forced restart once lost unflushed commits.
- **A Qlick Lab stuck quitting**: a process can stay in the kernel's exit for ever (state `E` in `ps -p <pid>`,
  `kill -9` does nothing; seen 2026-11-23 after a night with the NAS). Then the Dock relaunches onto that dead pid
  (the icon bounces, nothing opens), and `ps -ax`/`pgrep` hang. `open -n "/Applications/Qlick Lab.app"` starts a
  fresh one; only a restart of the Mac clears the dead one. Use `lsappinfo`, never `pgrep`, in scripts
  (`install.sh` does). Cause not yet known: a `sudo spindump <pid>` before restarting would show the kernel's wait.
- Measure speed under a bundle id of its own: `CFFIXED_USER_HOME` doesn't separate preferences.
- The whole Swift suite runs together now (the donation question no longer touches a missing `NSApp`);
  `testBatchExportsEachPhotographWithItsOwnEdits` needs the `spektrafilm-f64` helper built
  (`cargo build --release -p spektrafilm-cli --features precision-f64 --bin spektrafilm-f64`).
- Generated Swift from Rust: `Develop/BorderGeometry.swift` (`QLICK_UPDATE_GENERATED=1 cargo test -p spektrafilm-io
  border_geometry`); command names are checked against `crates/spektrafilm-native/commands.txt`.
- Not to do: rewrite the app in Rust.

## Build and test

```bash
scripts/build_app.sh --dev
cargo test --locked --release --workspace
cargo build --locked --release -p spektrafilm-native
SPEKTRAFILM_ROOT="$PWD" swift test --package-path macos --scratch-path target/swift-native
scripts/drive.sh start   # off screen, own home; on copies of photographs only
```
