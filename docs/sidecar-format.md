# The `.qlick` sidecar format

Every photograph Qlick Lab marks, rates or develops gets its state saved beside it. Nothing inside the original
image is ever changed, except a DNG's XMP when the user keeps its edits inside the DNG (see below).

Code: `macos/Sources/QlickLab/Sidecar.swift` (format, reading, writing), `DNGMetadata.swift` (the DNG variant),
`scripts/sidecar_defaults.py` (frozen defaults tables). Tests: `SidecarTests`, `SidecarDefaultsTests`.

## Where it lives

- `IMG_0412.CR3` → `IMG_0412.CR3.qlick`, in the same folder. The name keeps the photograph's whole file name, so
  `IMG_0412.CR3` and `IMG_0412.JPG` never share one.
- Writes go through a hidden `.IMG_0412.CR3.qlick.tmp` and are renamed into place; folder scans skip those.
- A DNG can instead keep everything in its own XMP (Settings, `SidecarStorage`: "Inside DNG files", the default,
  or ".qlick files"). Reading always looks in both places.

## The file

JSON, UTF-8, pretty-printed with sorted keys (a file written twice with the same content is byte-identical, which
keeps sync services quiet). At most 1 MiB; a larger file is not a Qlick Lab sidecar and is left alone.

```json
{
  "app" : "Qlick Lab 0.1.4",
  "defaultsVersion" : 1,
  "qlick" : 1,
  "variants" : [
    {
      "edits" : {
        "film" : "kodak_portra_400",
        "paper" : "kodak_portra_endura",
        "params" : { "prep" : { "exposure_ev" : 0.3 } },
        "crop" : { "angle" : 1.2 },
        "border" : { "enabled" : true }
      },
      "flag" : "pick",
      "id" : "…",
      "rating" : 4
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `qlick` | Schema number (today 1). A file with a higher number was written by a newer Qlick Lab: it is read as defaults and **never written over**. |
| `defaultsVersion` | The frozen defaults table the edits are stored against (`data/sidecar-defaults/v<n>.json`). |
| `app` | The version that last wrote the file. Informative only. |
| `variants` | One entry per version of the photograph (Develop's versions). The first is the primary one. |
| `variants[].id` | Unique, non-empty. |
| `variants[].rating` | 0 (absent) to 5. |
| `variants[].flag` | `pick` (circled in red pencil) or `reject` (crossed out); absent when unmarked. |
| `variants[].edits` | Absent when the photograph is undeveloped. |

`edits` holds `film` and `paper` always, then **only what differs from the defaults table**: `params` (the engine's
parameters, nested as the engine names them), `crop`, `border`, and `brightnessMatch` (`ev`, `highlightLimited`,
`solved: false` when the exposure was not solved for these edits).

## Rules that keep files safe

- **Unknown keys are kept.** A key this version doesn't know, at any level, is written back as found, so an older
  Qlick Lab never erases what a newer one wrote.
- **Writes are patches.** A change is laid over the file as it is on disk when written (`SidecarPatch`), so a rating
  set meanwhile by another Mac stays.
- **A file with nothing left is removed**: one variant holding only its `id`, nothing else in the file.
- **Defaults tables are frozen.** A diff only means something against the table it was saved with. When a default
  changes, write the next table with `scripts/sidecar_defaults.py --version <n+1>` and raise
  `SidecarDefaults.latest`; never edit a released table. The tests hash every table and fail if an old one changes.
- An unreadable file opens the photograph with the defaults and is left untouched; the user is told why.

## Inside a DNG

The XMP gets the standard fields other apps read (`xmp:Rating`, `xmpDM:pick`), a few readable ones in the lab's
namespace `http://ns.jackfrom.be/qlicklab/1.0/` (`Film`, `Paper`, `WhiteBalance`, `Temperature`, `Tint`,
`Exposure`), and the whole sidecar above, as JSON, in `qlick:Sidecar`. That last field is what Qlick Lab reads back.

## Related files

- `.qlicklab`: a catalogue (a package of small files: one JSON per project or selection (`kind: "selection"` with
  `frames`, the photographs' paths), `saved-settings.json` for the import's
  Saved Settings under the top-level key `qlick`, `import-ledger.jsonl`). `Library/Catalogs.swift`.
- `Roll.qlickroll`: a roll's card inside the roll's folder, `{"qlick": {"schema": 1, "roll": {"name", "film",
  "camera", "notes"}}}`. Unknown keys are kept; a newer schema is left alone. The catalogue keeps a copy; when a
  folder is read the card wins, and a roll from before 0.3 gets one. `Library/RollCardFile.swift`.
