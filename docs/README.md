# Qlick Lab documentation

| Document | For |
|---|---|
| [architecture.md](architecture.md) | How the app and the engine fit together, where each thing lives |
| [sidecar-format.md](sidecar-format.md) | The `.qlick` sidecar and the DNG XMP the lab writes |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Building, testing, proposing a change |
| [handoff/HANDOFF.md](handoff/HANDOFF.md) | The work in progress: phase, branch, what's next |
| `screenshots/` | The pictures in the README |

## Upstream notes

Qlick Lab began as a modified Negs 0.15.0, whose code carries the spektrafilm-rs engine. Some comments in that
code, and some data files, name design notes from those projects that were not carried over into this repository.
They are kept as names, so the history stays traceable, but the files are not here. What each one covered, and where
the knowledge lives now:

| Note | Covered | Now |
|---|---|---|
| `prep.md` | Preparing a RAW for the film model: exposure placement, guided prep | Comments in `crates/spektrafilm-core/src/prep.rs`, `prep/guided.rs`, `exposure_placement.rs` |
| `presets-design.md` | The preset (recipe) file format | `crates/spektrafilm-core/src/presets.rs`, `Presets.swift` |
| `gpu-vs-cpu-quality.md` | How the GPU export is measured against the 64-bit CPU reference | `Engine.swift`, the comparison tests in `crates/spektrafilm-gpu` |
| `memory-scratch-reuse.md` | GPU scratch buffer lifetimes | `crates/spektrafilm-gpu/src/wgpu_backend.rs` |
| `colour-management.md` | Working and output colour spaces | `crates/spektrafilm-io/src/colour/mod.rs` |
| `raw-white-balance.md` | White balance of RAW files | `crates/spektrafilm-io/src/white_balance.rs` |
| `lens-corrections-plan.md` | Lens corrections from DNG opcodes | `crates/spektrafilm-io/src/lens/mod.rs` |
| `35mm-scan-sources.md` | Sources for the 35 mm border geometry | `crates/spektrafilm-io/src/film35.rs` |
| `native-macos-ui.md` | Startup and interaction timing of the Mac app | `Main.swift`, `InteractionBenchmark.swift` |
| `handoff-fotufilm-grain.md` | Grain settings ported from Fotufilm | `data/presets/grain.toml` |
| `bw-expansion-review.md` | Visual review of the black-and-white preparations | `data/profile-sources/bw-expansion/` |
| `print-frame-model.md` | Edge printing on film profiles (named in `data/profiles/*.json`) | The profiles' `edgePrinting.sources` |

`data/FOTUFILM_LICENSE.txt` names `docs/layered-transport.md` "in the source repository": Fotufilm's, not this one.
