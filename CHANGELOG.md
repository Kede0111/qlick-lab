# Changelog

## 0.1.2 — fixes from users' reports

- **Import, Add in Place**: Add now shows its progress (the film strip or the list, the counter, the time left,
  Stop) and makes the project as the photographs are added, instead of seeming to do nothing. It ends with what was
  added and a button to open the contact sheet. Copy and Move say "Getting ready…" and why they can't start.
- **Thumbnails from a slow disk**: a frame scrolled away no longer keeps the disk busy reading its thumbnail, so the
  import, the contact sheet and the progress show quickly even from a network disk.
- **Quitting never freezes**: the lab no longer waits with Quit greyed. It saves, then quits by itself; after a few
  seconds it says what it's still writing and offers Quit Now.
- **Removing a project** asks first, closes its contact sheet and removes its previews from the cache. Photographs
  and their marks stay where they are.
- **Sidebar**: a project's arrow only folds and unfolds its rolls; it no longer opens the whole project.
- **Previews folder**: the contact sheet's thumbnails now follow the folder chosen for the previews (another disk).
- **Proxies**: Settings › Upkeep › Make proxies offers Never, and says plainly when they're made.
- **Settings**: Remove All App Data and Quit is gone.

## 0.1.1

- **Print Diffusion**: the diffusion filters (Black Pro-Mist, Glimmerglass, Pro-Mist, CineBloom) can now go under the
  enlarger's lens too, in the Print section, as well as on the camera. On the print, the shadows bleed softly into
  the lighter parts, the way a darkroom diffuser works.

## 0.1.0 — first public version

Qlick Lab's first release as an open-source project.

- Develops photographs through spektrafilm's spectral film simulation, on the GPU, with about sixty film stocks and
  papers.
- Contact sheet in 135 film strips, red grease-pencil marks, ratings, filters, light table, loupe and printing to PDF.
- Projects, rolls and catalogues (`.qlicklab`), import from memory cards, compare, recipes, versions.
- Each photograph's edits in a `.qlick` file beside it. Originals are never changed.
- Export to JPEG, TIFF or PNG (8 or 16 bits, ICC profile), one at a time or in batches, and LUT export.
- Liquid Glass interface on macOS 26, with customisable shortcuts.
- Support Qlick Lab… in the menu, and a single coffee question after 50 exported photographs.
