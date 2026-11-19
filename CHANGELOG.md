# Changelog

## 0.1.4

- **Halation from the highlights**: only bright lights feed it now, leaving a red rim on the darker side of their
  edges, as on film; the rest of the frame is untouched. Develop › Halation gains Highlight gain (gives clipped
  lights back their strength), Threshold and Softness, and Amount goes to 5. Grain's Amount goes to 600%.
- **Background work**: the status pill counts photographs, each proxy made once and never more than the cache
  keeps. Clicking it opens the list of the work under way, each with its progress and a stop button; Stop All (also
  in the Lab menu) stops everything. Build Thumbnails puts the chosen photographs first.
- **Thumbnails from another computer**: the pictures read from the photographs are kept on this Mac, so a folder on
  the network is read once, not again at every scroll. Build Thumbnails reads them first ("Reading thumbnails"),
  then makes proxies and develops.

## 0.1.3

- **Grain and Halation presets**: each section has its own list of presets, holding only the ones you save. Picking
  one changes only that section, on every selected photograph at once; the contact sheet's menu has them too.
- **Monochrome grain**: Grain can be colourless on a colour film.
- **Halation › Show mask**: shows the halation alone, to see what it does and where. Never saved or exported.
- **No film**: develops with no film. With a paper, the photograph is read as a scanned negative and printed; with
  no paper, the image stays as it is and only the effects (grain, halation, diffusion) are added.
- **Recipes and Develop**: a recipe can also keep chosen Develop settings (white balance, brightness, tone…), and one
  tick box says whether applying it applies them too.
- **Imports with a recipe are there at once**: the photographs join their project straight away; their edits are
  written, their proxies made and their own white balance found in the background ("Saving edits" and "Making
  proxies" in the sidebar).
- **Thumbnails**: proxies are made first, at import and when a folder opens, and thumbnails develop from them in a
  fraction of a second, also after a preset on many photographs. A recipe on thousands of frames applies at once,
  shows its progress and can be stopped; a new one replaces the one still running.
- **Before / After zoomed in**: the original is as sharp as the developed photograph at 100%.
- **Develop panel**: a module's arrow opens all its controls; "Hide" folds it back to the few that matter most.
- **One language**: menus and dialogs provided by macOS no longer appear in French on an English Mac; the app is in
  English throughout.

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
