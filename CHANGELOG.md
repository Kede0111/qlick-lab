# Changelog

## Unreleased — one recipe format and one sidecar with QLab

QLab, the iPhone camera, now develops with this lab's engine (the same code, at one commit), and the two apps share
their files (`docs/q-formats.md`).

- **Recipes are `.qrecipe` files**: still spektrafilm's format (they open in spektrafilm), plus a small header with a
  stable identifier, so the same recipe is the same on the Mac and on the iPhone. Your recipes are converted once with
  their identifiers; the former `.json` files are kept in `Presets/Before qrecipe/`. Export, bundles and imports
  write `.qrecipe`; a `.qrecipe` from QLab keeps its identifier.
- **Sidecars are `.qsidecar` files** (`IMG_0412.CR3.qsidecar`), the name QLab writes beside its photographs. Your
  `.qlick` files are still read and left as they are; the first change to a photograph writes its `.qsidecar`.
- Leica Monopan 50 has its 35mm edge print.

## 0.2.0 — the lab in three parts

A new version of the whole lab. Your `.qlick` sidecars and catalogues from 0.1.x are read and converted once, with
nothing moved on the disk.

- **Library · Lab · Print**: a switch at the top of the window (⌘1, ⌘2, ⌘3) chooses the part; the sidebar shows only
  what it needs. G goes from Develop to the contact sheet and back.
- **Catalogues, one at a time**: File › New, Open and Close Catalog (⌥⇧⌘W). Opening another closes everything of the
  one before; closing leaves the lab empty without quitting.
- **Archives**: your folders exactly as they are on the disk, at every depth, kept up to date. Nothing is sorted
  there and nothing is ever moved. Locate Folder… finds a folder that moved; a disk unplugged or a network share
  that stops answering is set aside without freezing the lab.
- **Boxes and Rolls**: Boxes gather photographs from any Archive and nest to any depth; Rolls hold frames in your own
  order and can carry a film or a recipe; Smart Rolls fill themselves from rules. Sorted by drag and drop (⌥ copies),
  every gesture undone with ⌘Z. A Box shows its Boxes and Rolls on a shelf, as archive boxes and film cartridges.
- **Import**: Copy, Move or Leave in Place; always into an Archive, optionally a Box or a Roll; folders and file names
  by pattern, with an example; duplicates and unreadable files flagged; a folder card (film, camera, notes).
- **Finding photographs**: All Photographs, Last Import, Picks, By Date; search by field (`film:portra iso:>800`),
  filters, keywords, title and caption, burst stacks, Auto Advance.
- **Remove…**: one dialog to take photographs out of a Box or of the catalogue. Deleting files from the disk is a
  separate choice that asks twice. Move to Trash is gone.
- **Develop**: the film card (film, paper, recipe) folds to one line; Develop and Emulsion tabs, sections that fold;
  Auto Straighten in the engine (plumb lines, then the horizon).
- **Recipes and Stocks**: favourites and hidden films, papers and recipes; several recipes shared as one
  `.qlickrecipes` file.
- **Print**: the photograph as it will be printed, the output colour space with a soft proof, out-of-gamut marks and a
  gamut diagram, image size and border. The printable contact sheet keeps your red pencil marks.
- **The look**: the lab's own fine-line pictograms, QLab's red, Liquid Glass panels, or Settings › Interface ›
  Solid surfaces for solid black. Every selected frame wears the red pencil; View › Pencil Marks hides them.
- **Speed**: the next frames are developed ahead as you step through a roll (a frame shows in 5 ms instead of 46 ms),
  and less memory is used.

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
