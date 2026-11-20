# Speed, RedLamp's ideas: measures (2026-11-21)

Branch `feature/speed-redlamp` (from `feature/lab-structure` at bda405c), compared with bda405c itself. Both built in
release with the same benchmark (`Diagnostics/SpeedBenchmark.swift`, copied into the reference build to measure it the
same way): `scripts/build_app.sh --dev|--speed --benchmark`, each under its own bundle identifier so their preferences
never meet, a fresh home each run, on 12 copies of one Leica M11 DNG (60 MP), M4 Max, off screen.

What changed (Swift only; the Rust engine is untouched):

- **Read ahead in the direction of travel** (`Develop/RenderAhead.swift`): the kept develops (2560 px) of the next two
  photographs in the direction the photographs are walked through, and one behind, are decoded into memory; the
  photograph just left is held too, before its file is written. Opening one of them shows it developed in the very
  first frame. A few photographs at most (~17 MB each), dropped when macOS asks for memory.
- **The work done ahead leans the same way**: proxies, thumbnails and previews are made in walking order (ahead first,
  behind counted three times as far) when a photograph is open in Develop; nearest first in the grid as before.
- **Energy and heat** (`App/MachineState.swift`): in Low Power Mode or when the Mac runs hot (thermal state serious or
  critical), the thumbnails keep to the screen in one helper, one proxy at a time, and previews are built ahead only
  for the next photographs in the direction of travel.
- **The launch frame** (`RenderedPreviewCache`) is written once the lab rests on a frame for 3 s, or at quit, not for
  every frame settled.

Not done: cancelling a render in the Rust engine (audit P2). Measured first, as the audit asked: a quick run of film
changes settles 55 to 140 ms after the last one, and a step's develop takes ~275 ms, so there's little to gain there
for a lot of work in the engine.

## Results (medians; 3 runs each with the lab's default settings, 2 with Quentin's Dev settings)

| Measure | Reference | Speed | |
|---|---|---|---|
| Step to the next photograph, shown developed (resting pace) | 46 ms | **4.7 ms** | 16 of 16 steps in the first frame (0 before) |
| Same, settled at full quality | 271 ms | 278 ms | engine-bound, unchanged |
| Key held (a step every 100 ms): settled after the last | 24 ms / 10 ms | **5 ms / 4 ms** | |
| Main thread, longest pass during a step | 38 ms | 41 ms | same |
| Six film changes 150 ms apart, settled after the last | 139 / 56 / 59 ms | 132 / 55 / 60 ms | same |
| Slider drag | 27 fps, release 32 ms | 27.7 fps, release 33 ms | same |
| First photograph opened and developed | 4.07 s | 4.12 s | same (RAW read) |
| Work ahead done (12 proxies, thumbnails, previews) | 12.5 s | 12.4 s | same |
| App memory, peak | 557 MB | **398 MB** | −29 % (all 5 runs) |
| App + helpers memory, peak | 7.16 GB | 7.00 GB | the proxy helpers' RAW reads; same |
| Written to disk by the helpers | 1413 MB | 1294 MB | −8 % |
| Caches on disk after the run | 118 MB | 118 MB | same (proxies 104 MB, previews 14 MB) |
| Export, Fast (GPU), JPEG full size | 5.05 s | 5.19 s | same engine |
| Export, Reference (CPU 64-bit) | 27.1 s | 26.1 s | same engine |

With Quentin's Dev settings (proxies never, previews ahead off), nothing is kept ahead of a photograph never opened, so
stepping forward is unchanged (~1.35 s to show it developed, a RAW read); stepping back over photographs already seen
is now immediate (8 of 16 steps in the first frame, 0 before). Disk is the same (7 MB).

Raw numbers: the benchmark's `speed:` lines; scripts kept outside the repository (the scratch `bench/` folder of the
session that measured).
