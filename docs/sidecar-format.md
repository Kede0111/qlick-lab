# The `.qsidecar` sidecar format (formerly `.qlick`)

Since the shared formats with QLab (`docs/q-formats.md`), the file is `IMG_0412.CR3.qsidecar`, its schema number under
the key `qsidecar`; everything below holds as written for `.qlick`. A `.qlick` file is still read (a `.qsidecar` beside
it wins) and never written or removed, except that keeping a DNG's state in its XMP removes both, as it removed the
`.qlick` before; clearing everything while a `.qlick` is there leaves an empty `.qsidecar`. QLab's block (`qlab`, and
`qlab` inside each variant) is kept like any key the lab doesn't know.

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
| `variants[].label` | Colour label: `red`, `yellow`, `green`, `blue` or `purple`; absent without one. A word this version doesn't know reads as none and is kept. |
| `variants[].keywords` | Array of strings, each once (letter case aside); absent when empty. |
| `variants[].title`, `variants[].caption` | Strings; absent when empty. |
| `variants[].recipe` | The name of the recipe applied last (what Smart Rolls and the search's `recipe:` find); absent when none was. |

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

The XMP gets the standard fields other apps read (`xmp:Rating`, `xmpDM:pick`; and, once the lab has written any of
them, `xmp:Label` with the colour's English name, `dc:subject` as a Bag of keywords, `dc:title` and `dc:description`
as x-default Alts: before that, another app's are left as they are), a few readable ones in the lab's
namespace `http://ns.jackfrom.be/qlicklab/1.0/` (`Film`, `Paper`, `WhiteBalance`, `Temperature`, `Tint`,
`Exposure`), and the whole sidecar above, as JSON, in `qlick:Sidecar`. That last field is what Qlick Lab reads back.

## Related files

- `.qlicklab`: a catalogue (a package of small files): one JSON per Archive (`schema` 2: `id`, `name`, `notes`,
  `createdAt`, `rolls` = its Folders, each `{id, name, folder, bookmark, film, camera, notes, addedAt}`; the folders
  under them are read from the disk, not stored); `boxes.json`, the Boxes, `{"qlick": {"schema": 1, "boxes": [...]}}`,
  each Box `{id, name, frames, boxes, rolls, createdAt}` (`frames`: photographs' paths; `boxes`: the Boxes inside it,
  to any depth; `rolls`: `{id, name, frames, createdAt}`, and for a Smart Roll `rules`: `{match: all|any|none, rules:
  [{field, op, value}], groups: [...]}`, its photographs found by them, none kept in `frames`; `Library/PhotoQuery.swift`);
  `last-import.json`, the photographs of the last import, `{"qlick": {"schema": 1, "date", "photos": [paths]}}`
  (Last Import; before it, the ledger's last run of files); `removed.json`, the photographs removed from the lab
  (Remove from Qlick Lab: left out of every listing and Box, their files untouched), `{"qlick": {"schema": 1,
  "photos": [paths]}}`, gone when empty (`Library/Remove.swift`); `saved-settings.json` for the import's Saved Settings under
  the top-level key `qlick`; `import-ledger.jsonl`. `Library/Projects.swift`, `Library/Catalogs.swift`.
  Before 0.4 (`schema` 1) a file could be Arrivals (`kind: "arrivals"`) or a selection (`kind: "selection"` with
  `frames`): read once and converted (Arrivals → the Archive “To Sort”, each selection → a Box on top, its file then
  removed). A newer schema, Archive, `boxes.json` or `removed.json`, is left alone.
- `Roll.qlickroll`: a Folder's card inside the folder (the name kept from when Folders were rolls), `{"qlick": {"schema": 1, "roll": {"name", "film",
  "camera", "notes"}}}`. Unknown keys are kept; a newer schema is left alone. The catalogue keeps a copy; when a
  folder is read the card wins, and a Folder from before 0.3 gets one. `Library/RollCardFile.swift`.
