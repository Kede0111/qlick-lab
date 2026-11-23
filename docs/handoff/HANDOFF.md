# Handoff

A snapshot for the next agent, not a log: **rewrite it** at the end of each phase (state, branch, next, gotchas),
under about 120 lines. History lives in `git log`, `CHANGELOG.md` and the docs. Read it, then `CLAUDE.md` and
`docs/architecture.md`.

## State (2026-11-23)

- **0.2.0 is released** (tag `v0.2.0`, rebuilt once on e3af094 with the panels' fix, same version). `main` holds
  everything; the old development branches are gone. Installed in /Applications from `main` (build 6).
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

Next for this: the cable transport (AFC, its own module behind an interface, so an iCloud container can replace it for
a Mac App Store build): import a plugged iPhone's photographs with their `.qsidecar` and its `Documents/Recipes`, write
recipes back. Then show the lab which engine revision a file names when it differs from its own.

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
- Tests known to fail together, not alone: the export tests crash xctest in `Support.swift:61` (`NSApp` nil when the
  donation timer fires); `testBatchExportsEachPhotographWithItsOwnEdits` needs the `spektrafilm-f64` helper built.
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
