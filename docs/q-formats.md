# Shared formats of QLab and Qlick Lab: `.qrecipe` and `.qsidecar`

The same file in both repositories (`Kede0111/QLab` `docs/q-formats.md`, `Kede0111/qlick-lab` `docs/q-formats.md`).
Change one, change the other in the same breath.

QLab (iPhone) and Qlick Lab (Mac) share one film engine, the Rust spektrafilm of Qlick Lab (`crates/`), at the same
revision: QLab builds it from a git submodule (`vendor/qlick-lab`) pinned to a Qlick Lab commit. A recipe or a
development made in one app renders the same in the other when both name the same engine revision. Raising the engine
means raising the submodule to the Qlick Lab release that has it.

Both apps keep reading their former files (`.qlabrecipe`, `.qlab.json`; `Presets/*.json`, `.qlick`, a DNG's
`qlick:Sidecar`), and never delete them.

## Common rules

- JSON, UTF-8, pretty-printed with sorted keys, written through a hidden temporary file renamed into place.
  At most 1 MiB. A file may hold Python's `Infinity`/`NaN` (spektrafilm writes them): read it as JSON5.
- **Each app has its own block** at the top level, `"qlab"` and `"qlick"`. An app never changes or drops the other's
  block, nor any key it doesn't know, at any level: it writes back what it found.
- **A newer format number** (`qrecipe.format`, `qsidecar`) is read as far as understood and never written over.
- **Engine** (`engine`): which engine a development or a recipe is authoritative for.
  - `{"name": "spektrafilm-rs", "revision": "<qlick-lab commit>", "defaultsVersion": <n>}`: the shared part (the
    engine's parameters) is what renders. Both apps render it alike.
  - `{"name": "qlab-swift", "version": "1.0.0", "reference": "spektrafilm 0.3.4 (3bb2c2d)"}`: QLab's former engine.
    QLab renders it from its own block exactly as before; the shared part is a translation for Qlick Lab, an
    approximation, and Qlick Lab says so. Only QLab can move a development or a recipe to `spektrafilm-rs` (the
    photographer's choice, "use the new engine"); it never happens by itself.

## `.qrecipe`

A recipe, one per file: `<name>.qrecipe`. The name follows Qlick Lab's rule (`PresetName`: a valid file name on
Windows, macOS and Linux, compared without regard to case or Unicode form; "name 2", "name 3"… when taken).

Where: QLab `Documents/Recipes/` (Files › On My iPhone › QLab › Recipes, and the Mac over the cable); Qlick Lab its
Presets folder (`~/Library/Application Support/be.jackfrom.qlicklab/Presets/`).

The file **is spektrafilm's saved GUI state** (the format Qlick Lab's recipes already have, read by
`spektrafilm-core::presets`), so it still opens in spektrafilm and anywhere a spektrafilm preset opens, plus:

```json
{
  "camera": { "...": "spektrafilm's GUI state, as today" },
  "simulation": { "film_stock": "kodak_portra_400", "print_paper": "kodak_portra_endura", "...": "..." },
  "qrecipe": {
    "format": 1,
    "id": "403683E1-8F10-48DA-A4EE-1A6AAA946B84",
    "name": "Kodak Portra 400 (Quent)",
    "origin": "Qlick Lab",
    "created": "2026-11-22T19:00:00Z",
    "modified": "2026-11-23T10:00:00Z",
    "revision": "sha256:…",
    "engine": { "name": "spektrafilm-rs", "revision": "66aa771", "defaultsVersion": 1 }
  },
  "qlick": { "version": 1, "develop": { "groups": ["tone"], "params": { "prep.shadows": 8 }, "match_brightness": true } },
  "qlab": { "recipe": { "…": "QLab's Recipe, as it encodes it (its finishing and effects included)" }, "enginePart": "sha256:…" }
}
```

| Key | Meaning |
|---|---|
| `qrecipe.format` | 1. |
| `qrecipe.id` | Stable identifier (UUID string). Survives renames; the same recipe on both sides has the same id. |
| `qrecipe.name` | The recipe's name (the file's name may differ by the characters a file name refuses). |
| `qrecipe.origin` | `"QLab"` or `"Qlick Lab"`: where it was made. Informative. |
| `qrecipe.created`, `modified` | ISO 8601, UTC. |
| `qrecipe.revision` | An opaque token the writer sets anew whenever the content changes (each app uses a `sha256:` of its own serialisation). Readers never recompute it: they compare it with the revision they last synced. |
| `qrecipe.engine` | See *Engine* above. |
| `qlick` | Qlick Lab's own block (`RecipeDevelop`: which Develop groups the recipe carries). |
| `qlab.recipe` | QLab's `Recipe` (`id`, `name`, `details`, `settings`, `thumbnail`…), verbatim: what a former `.qlabrecipe` held. For a `qlab-swift` recipe it is what renders, unchanged. |
| `qlab.enginePart` | QLab's fingerprint of the engine's part when it wrote the file. When the engine's part no longer matches (edited in Qlick Lab), QLab takes the engine's part and keeps only its finishing from `qlab.recipe`. |

Applying a recipe keeps the photograph's own geometry, white balance, exposure and grain seed, in both apps (as both
already do).

### Migration (once, at launch, nothing lost)

- QLab: each `Library/Recipes/<UUID>.qlabrecipe` becomes `Documents/Recipes/<name>.qrecipe` with
  `engine: qlab-swift`, `qlab.recipe` = the former file verbatim, `qrecipe.id` = its `id`, and the shared part
  translated from its settings. The former folder stays as it was (the backup); a recipe already migrated (same id in
  `Documents/Recipes`) is skipped. Its renders do not change: QLab renders a `qlab-swift` recipe with the Swift engine.
- Qlick Lab: each `Presets/<name>.json` becomes `Presets/<name>.qrecipe`, the same content plus `qrecipe` (its id
  from `.ids.json`, `origin: "Qlick Lab"`, `engine: spektrafilm-rs` at the app's revision). The former files move to
  `Presets/Before qrecipe/`. A `.json` dropped in later (a spektrafilm preset from elsewhere) is imported as before
  and saved as `.qrecipe`; a `.qrecipe` imported keeps its id (the same recipe on every device).

Writing a file that may hold `Infinity`/`NaN`: those numbers are carried through the JSON writer as the strings
`"\u0001Infinity"`, `"\u0001-Infinity"`, `"\u0001NaN"` and put back as bare words in the text (as the engine does).

## `.qsidecar`

A photograph's state, beside it: `QLB_0001.DNG` → `QLB_0001.DNG.qsidecar` (the whole file name, so a DNG and a JPEG of
the same name never share one). The same name in both apps, so plugging the iPhone in brings every photograph with its
developments in one pass. In QLab: the library keeps it (`Sidecars/<photo-id>.qsidecar`) and the shared folder has a copy
beside each published original (`Documents/<day>/QLB_0001.DNG.qsidecar`). Qlick Lab can keep it in a DNG's XMP instead
(`qlick:Sidecar`, holding the same JSON), as today.

It is Qlick Lab's `.qlick` format (`docs/sidecar-format.md` in Qlick Lab) under a new number and name, plus the blocks:

```json
{
  "qsidecar": 1,
  "app": "QLab 1.4",
  "defaultsVersion": 1,
  "variants": [
    {
      "id": "8C1B…",
      "name": "Portra",
      "engine": { "name": "spektrafilm-rs", "revision": "66aa771", "defaultsVersion": 1 },
      "edits": { "film": "kodak_portra_400", "paper": "kodak_portra_endura", "params": { "camera": { "exposure_compensation_ev": 0.3 } } },
      "recipe": "Kodak Portra 400 (Quent)",
      "recipeRef": { "id": "403683E1-…", "revision": "sha256:…" },
      "rating": 4, "flag": "pick", "caption": "Bruxelles",
      "qlab": { "version": { "…": "QLab's DevelopmentVersion, verbatim" } }
    }
  ],
  "qlab": { "record": { "…": "QLab's PhotoRecord without its versions" } }
}
```

| Key | Meaning |
|---|---|
| `qsidecar` | Schema number, 1. Replaces `.qlick`'s `qlick` number; everything else of `.qlick` keeps its meaning (`defaultsVersion`, `app`, `variants[].id/rating/flag/label/keywords/title/caption/recipe`, `edits` stored as the difference from the frozen defaults table, unknown keys kept, writes as patches). |
| `variants[].name` | The development's name (QLab's version name). |
| `variants[].engine` | See *Engine*. Absent in a file converted from `.qlick`: `spektrafilm-rs` at the revision that wrote it. |
| `variants[].edits` | The engine's parameters, as `.qlick` stores them. Authoritative for `spektrafilm-rs`; for `qlab-swift`, a translation. |
| `variants[].recipeRef` | The recipe applied last, by id and revision (beside `recipe`, its name, which Qlick Lab's search reads). |
| `variants[].qlab.version` | QLab's `DevelopmentVersion` verbatim (`settings`, `history`, `recipeID`, `renderedFile`…; for `spektrafilm-rs`, its finishing layer). |
| `qlab.record` | QLab's `PhotoRecord` without `versions`: id, original's names, capture information, albums, notes, favourite… |
| `qlab.order` | QLab's order of its developments (the file lists the primary one first). |

Shared meanings: QLab's notes are the primary variant's `caption`; QLab's favourite is `flag: "pick"` on the primary
variant only when QLab set it (QLab keeps its own value in `qlab.record`). The primary variant is QLab's active version.

Reading: `.qsidecar` first, then the former files (`.qlab.json` for QLab, `.qlick` and the DNG's XMP for Qlick Lab).
Writing: `.qsidecar` only; a former file is left as it is (when everything is cleared, an empty `.qsidecar` stays so
the former file's state doesn't come back). Qlick Lab keeping a DNG's state in its XMP removes the photograph's
`.qsidecar` and `.qlick`, as it removed `.qlick` before.

## Syncing over the cable (Qlick Lab, iPhone plugged in)

The transport is its own module in Qlick Lab, behind an interface, so another one (an iCloud container shared by the
two apps, for a Mac App Store build) can take its place. It is not part of this step.

- Photographs: `Documents/<day>/<name>` with its `.qsidecar` → imported with its developments.
- Recipes: `Documents/Recipes/*.qrecipe` ⇄ Presets. By id: same revision, nothing to do; one side changed since the
  last sync (Qlick Lab keeps the last synced revision of each id, per iPhone), it wins; both changed, both are kept, the
  incoming one with a new id and " (iPhone)" or " (Mac)" after its name. A deletion is not carried over.
