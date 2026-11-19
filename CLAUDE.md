# Qlick Lab

Qlick Lab is its own application, open source under the GPL-3.0 (`Kede0111/qlick-lab`). It started as a modified
version of Negs 0.15.0; Negs is credited (README, LICENSES.md, About) but is no longer a reference to stay close to.

- Change any file whenever the app needs it. A feature the lab does its own way is brought in line everywhere it
  shows. When something is added in one view (contact sheet, grid, film strip, Develop, Compare), check that every
  other view showing the same thing gets it too.
- New code and comments say "the lab" or "Qlick Lab".
- File formats: `.qlick` sidecars (top-level key `qlick`), `.qlicklab` catalogues, XMP namespace
  `http://ns.jackfrom.be/qlicklab/1.0/`. Bundle identifier `be.jackfrom.qlicklab`.
- Donations: `Support.swift` (PayPal link, the single question after 50 exported photographs). Keep it discreet.

## Architecture

Two processes: the Swift app (`macos/Sources/QlickLab`, AppKit at the root, SwiftUI in `Lab/`) and the Rust engine
(`crates/`: math → model → core → gpu, io; `spektrafilm-native` is the helper the app talks to in JSON lines,
`spektrafilm-cli` the export tools). Details in `docs/architecture.md`; the sidecar format in `docs/sidecar-format.md`;
contributors' rules in `CONTRIBUTING.md`. Keep the engine in Rust and the interface in Swift: no rewrite of the app.

## Work in progress

Several agents may work on this repository in turn. **Read `docs/handoff/HANDOFF.md` first**: current phase, branch,
what's done and next, decisions. Update it at the end of each phase.

## The interface

- English throughout, in the app's own words. No other app's name in the interface text (Lightroom, Capture One,
  Photomator, Negs…): say what a control does, not whose habit it copies.
- Red is the lab's mark colour; the Develop panel follows QLab (`Kede0111/QLab`): rounded red sliders, the film
  card, tabs as one pill, Liquid Glass panels.

## Building and testing

- `scripts/build_app.sh` builds `dist/qlick-lab/Qlick Lab.app` and regenerates `QlickLab.xcodeproj` from `project.yml`
  (XcodeGen), with the version from `scripts/version`: commit the project with the change that added or removed files; `scripts/make_icon.sh` makes the icon
  from `assets/icon.png` (Icon Composer's `macos/AppIcon.icon` for macOS 26 and later, `assets/qlick-lab.icns` before).
- Test with `scripts/drive.sh` (off-screen, its own home folder, captures only the app's window), on copies of
  the photographs in a scratch folder: the app writes `.qlick` sidecars beside the photographs it edits.
- Photographs (`Photos/`) are never committed or pushed.
- `scripts/build_app.sh --dev` builds a test copy, `dist/qlick-lab-dev/Qlick Lab Dev.app` (bundle id
  `be.jackfrom.qlicklab.dev`, its own settings and data), which never touches the installed app.
- Commit or push only when the user says so. After each finished change that is committed, install it for the user to
  try (except during work tracked in `docs/handoff/HANDOFF.md`, which says to use the Dev copy): `scripts/install.sh` builds, puts `/Applications/Qlick Lab.app` in place (an open one is quit first and
  reopened behind) and links it as `Qlick Lab.app` in the working folder.
- Releases: raise `scripts/version`, add the entry to `CHANGELOG.md`, `scripts/make_dmg.sh`, then attach
  `dist/Qlick-Lab-<version>.dmg` to a GitHub release tagged `v<version>`.
