# Qlick Lab: licences and credits

Qlick Lab © 2026 Quentin Descotte is free software under the **GNU General Public License, version 3**
([full text](LICENSE)). That's the licence of spektrafilm, spektrafilm-rs and Negs, whose code it uses. No licence of
a community component has been changed. This file lists what the repository contains, where each part comes from and
what was changed.

> This isn't legal advice.

## Origin and modifications (GPL-3.0, section 5)

Qlick Lab is a **modified version of [Negs](https://github.com/noahhaasis/negs)** by Noah Haasis, version 0.15.0
(commit `34d0116`), itself built on spektrafilm-rs and spektrafilm. Quentin Descotte has modified it since
November 2026. Negs's full development history is in its own repository. This repository starts again at
Qlick Lab 0.1.0.

Main changes from Negs 0.15.0:

- New application around the editor (`macos/Sources/QlickLab/Lab/`): contact sheet, grease-pencil marks, projects,
  catalogues, import, compare, recipes, film library, print, sidebar and Liquid Glass interface, shortcuts.
- Renamed (Qlick Lab, `be.jackfrom.qlicklab`), with its own file formats: `.qlick` sidecars (top-level key `qlick`) and
  `.qlicklab` catalogues.
- Engine (`crates/spektrafilm-native`): RAW proxies, Daylight reads with an As Shot fit, white balance eyedropper,
  regions of a frame at full size, larger previews. These changes are marked "Qlick Lab:" in the source.
- The web, Windows and Linux applications were removed. Qlick Lab is a Mac app.

## Code

| Component | Author · copyright | Licence | Where | Changes |
|---|---|---|---|---|
| **Qlick Lab** | © 2026 Quentin Descotte | GPL-3.0-only | whole repository, notably `macos/Sources/QlickLab/Lab/`, `scripts/` | — |
| **Negs**: the Mac editor, engine work, sidecars | © 2026 Noah Haasis | GPL-3.0-only | `macos/`, `crates/` | modified, see above |
| Prep, camera brightness, waveform | © 2026 yosoyelchris | GPL-3.0-only | `crates/spektrafilm-core/src/prep*`, `macos/Sources/QlickLab/CameraBrightnessReference.swift` | none |
| **spektrafilm-rs**: Rust port | © turbasvin | GPL-3.0 | `crates/` | modified through Negs and Qlick Lab |
| **spektrafilm**: spectral model | © Andrea Volpato | GPL-3.0 | algorithms ported in `crates/` | none |
| Mathematics ported from numpy, scipy, scikit-image, colour-science | their authors | BSD-3-Clause | `crates/spektrafilm-math` | none |
| Lens corrections ported from darktable | darktable contributors | GPL-3.0-or-later | `crates/spektrafilm-io` | none |
| **rawler** 0.8.0 (RAW decoding), patched copy | dnglab | LGPL-2.1 | `vendor/rawler` (`vendor/README.md` lists the patches) | none by Qlick Lab |
| **Sparkle** 2.10.0 (updates) | Sparkle Project | MIT | SwiftPM dependency, copied into the app | none; inactive without a release feed |
| Rust dependencies (wgpu, image, rayon, serde, clap…) | their authors | MIT / Apache-2.0 / BSD mostly | `Cargo.lock` | none; exact list: `cargo tree --format "{p} {l}"` |

## Data

| Data | Author | Licence | Where | Changes |
|---|---|---|---|---|
| spektrafilm film and paper profiles, filters, spectral upsampling tables (Arctic 2026, Mallett 2019) | Andrea Volpato | CC BY-SA 4.0 ([text](data/SPEKTRAFILM_LICENSE.txt)) | `data/profiles`, `data/filters`, `data/luts` | none |
| Default spectral upsampling table (Hanatos 2025) | Johannes Hanika (hanatos, vkdt) | distributed with spektrafilm | `data/luts` | none |
| 29 profiles adapted from Fotufilm | MUAStudio Inc. | CC BY-SA 4.0 ([text](data/FOTUFILM_LICENSE.txt)) | `data/profiles` | none by Qlick Lab |
| Tri-X 400 (D-76) and Ilford Multigrade RC profiles | Negs, from Kodak's and Ilford's data sheets | as Negs | `data/profiles`, `data/profile-sources` | none |
| 35 mm border textures and edge prints | romnn (MIT base) and Negs | MIT ([text](data/borders/LICENSE-film-borders)) | `data/borders` | none |

Qlick Lab **adds no film profile** and doesn't invent any. The film library shows the profiles above, with their own
curves, where each comes from and how far it can be trusted.

## Fonts and artwork

| Resource | Author | Licence | Where |
|---|---|---|---|
| Newsreader (subset) | Production Type | SIL OFL 1.1 ([text](macos/Fonts/OFL-Newsreader.txt)) | `macos/Fonts` |
| Rajdhani Bold | © 2014 Indian Type Foundry | SIL OFL 1.1 ([text](macos/Fonts/Rajdhani-OFL.txt)) | `macos/Fonts` |
| Qlick Lab icon and logo | © 2026 Quentin Descotte | the project's own; not covered by the GPL | `assets/`, `macos/AppIcon.icon`, `macos/Assets.xcassets` |
| Interface symbols | Apple (SF Symbols) | Apple's licence, for use in Apple-platform apps | at run time, not redistributed |

The colour tokens, typography and some components come from QLab, by the same author (GPL-3.0-or-later).

## Trademarks

Kodak, Portra, Ektar, Gold, Tri-X, Vision3, Fujifilm, Velvia, Provia, Ilford, Agfa, CineStill, Lomography, Harman,
Leica and others belong to their owners. The names only identify the emulsions whose published data the profiles
follow. Qlick Lab isn't affiliated with any manufacturer.

"Qlick Lab", its icon and its logo identify this project. Forks are welcome under the GPL. Please give yours another
name and icon so people can tell them apart. "Negs" is the name of Noah Haasis's project: Qlick Lab is derived from it
and never presents itself as Negs.

## How the obligations are met

- **GPL-3.0**: complete source in this repository under the same licence. The origin and the changes are described
  above, and the changed engine source is marked "Qlick Lab:".
- **CC BY-SA 4.0**: profile files unchanged. Credits and licence texts ship inside the app
  (`Contents/Resources/data/*_LICENSE.txt`), and each profile's provenance is shown in the interface.
- **LGPL-2.1** (rawler): source of the patched copy in `vendor/`.
- **OFL**: licence texts ship with the fonts.
- **Credits**: in the About window, in the README and in this file.
