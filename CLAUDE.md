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

## What Qlick Lab is (and is not)

In Quentin's words:

> Le logiciel Qlick Lab est un laboratoire de traitement et de développement argentique pour la photographie
> numérique. En d'autres termes, Qlick Lab développe vos photos numériques comme un labo argentique, en leur donnant
> le plus fidèlement possible le rendu des photographies argentiques grâce à la simulation spectrale de véritables
> pellicules. Qlick Lab utilise tous les codes et clins d'œil du développement en laboratoire argentique et gère le
> workflow du début à la fin : la bibliothèque (Library) avec ses rolls, boxes et archives, le développement (Lab),
> l'export (Print). L'expérience doit être agréable, visuellement comme dans les réflexes de labo. C'est un puissant
> logiciel de simulation de pellicule argentique basé sur la simulation spectrale, avec des capacités de retouche
> adaptées à ce type de photographie.
>
> Qlick Lab n'est pas une alternative à Lightroom, Photomator, Capture One, etc. Le but n'est pas d'en faire un
> logiciel de traitement photo alternatif, mais un véritable logiciel de transformation de photos raw numériques en
> argentique, en gardant les codes d'un labo physique.

**Rule:** every change proposed or made is checked against this philosophy first. When a request, a feature or a
fix drifts from it (general-purpose photo editing, a tool that copies another app's habit, clutter that breaks the
minimal Leica-like look), say so to Quentin plainly before doing it, and suggest the lab's way instead.

### Three parts: Library, Lab, Print

The interface is organised in three main parts; everything belongs to one of them, and the sidebar stays simple.

- **Library**: import, the contact sheet, Archives, Boxes, Rolls. Archives and Boxes are reachable at any time,
  from any part.
- **Lab**: development, recipes, film stocks. From Develop, one click or one key switches to the contact sheet
  (a central toggle at the top), which shows what is selected in the Archives and Boxes.
- **Print**: export.

Import sorts what a source holds by kind of file (the "Type:" menu beside "Show:": RAW, JPEG, TIFF…), and each frame
keeps its own check: a menu or a button may check and uncheck many at once, never replace the checks.

From the Lab or Print, going to the Library (⌘1) shows the contact sheet holding the photograph in hand (its Folder,
Box or Archive), that photograph selected and in view: moving between the parts never loses the photograph.

The look: minimal and premium, red / white / greys, in the spirit of Leica (inspiration only, no Leica marks), and
shared with QLab (`Kede0111/QLab`) so the two apps can merge later. The photographs on disk are never moved or
deleted by the app (import may create folders; the one exception is "Remove rejected", behind a clear confirmation).

## Architecture

Two processes: the Swift app (`macos/Sources/QlickLab`, one folder per role: App, Library, Import, ContactSheet, Develop, Compare, Recipes, Print, Export, Engine, Files, Design) and the Rust engine
(`crates/`: math → model → core → gpu, io; `spektrafilm-native` is the helper the app talks to in JSON lines,
`spektrafilm-cli` the export tools). Details in `docs/architecture.md`; the sidecar format in `docs/sidecar-format.md`;
contributors' rules in `CONTRIBUTING.md`. Keep the engine in Rust and the interface in Swift: no rewrite of the app.

## Work in progress

Several agents may work on this repository in turn. **Read `docs/handoff/HANDOFF.md` first**: current phase, branch,
what's next, gotchas. Rewrite it at the end of each phase as a short snapshot, never an accumulating log.

## The interface

- English throughout, in the app's own words. No other app's name in the interface text (Lightroom, Capture One,
  Photomator, Negs…): say what a control does, not whose habit it copies.
- Red is the lab's mark colour; the Develop panel follows QLab (`Kede0111/QLab`): rounded red sliders, the film
  card, tabs as one pill, Liquid Glass panels.

## Disks

A disk under /Volumes is offline only when it isn't mounted or the Mac says a share stopped answering
(`Files/VolumeReach.swift`): never because it's slow. Nothing on the main thread waits on a disk for more than a moment;
off the main thread, work goes at the disk's speed. Try it with `QLICK_SLOW_VOLUME` / `QLICK_GONE_VOLUME` (debug builds).

## Panels

Every open and save panel goes through `LabPanel.begin` (`App/LabPanel.swift`): a sheet on the lab's window, one at a
time, and asking again brings the open one forward. Never `panel.begin` or `runModal` on its own: a free panel can open
behind the window, unseen. What a panel needs from a disk before it shows (the last folder, a photograph's edits) is
asked by the rule above, never waited for.

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
- Releases: raise `scripts/version`, add the entry to `CHANGELOG.md`, `scripts/make_dmg.sh` (it signs the DMG with the
  update key in Quentin's Keychain and writes `dist/appcast.xml`), then attach **both** `dist/Qlick-Lab-<version>.dmg`
  and `dist/appcast.xml` to a GitHub release tagged `v<version>`: the installed apps read the latest release's
  appcast to offer the update. Never put the update feed in a Dev copy.
