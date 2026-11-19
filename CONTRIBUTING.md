# Contributing to Qlick Lab

Thank you for looking. Bugs and ideas go to [Issues](https://github.com/Kede0111/qlick-lab/issues); questions and
photographs to [Discussions](https://github.com/Kede0111/qlick-lab/discussions).

## Before you start

- Read [docs/architecture.md](docs/architecture.md): two processes (Swift app, Rust engine) and where each thing lives.
- The film engine (`crates/`) is shared with spektrafilm-rs and checked against a reference. Changes there need a
  test showing the result didn't move, or why it should.
- Sidecars (`.qlick`) are a file format other people's photographs depend on: read
  [docs/sidecar-format.md](docs/sidecar-format.md) before touching `Sidecar.swift`.

## Build

You need Xcode 26 (the macOS 26 SDK) and Rust stable 1.89 or later; XcodeGen if you add or remove Swift files.

```bash
scripts/build_app.sh          # dist/qlick-lab/Qlick Lab.app
scripts/build_app.sh --dev    # dist/qlick-lab-dev/Qlick Lab Dev.app: its own settings and data, safe beside the real one
open QlickLab.xcodeproj       # or Xcode; regenerate it with `xcodegen generate` after adding or removing files
```

## Test

```bash
cargo test --locked --release --workspace
cargo build --locked --release -p spektrafilm-native
SPEKTRAFILM_ROOT="$PWD" swift test --package-path macos --scratch-path target/swift-native
```

The same runs on every pull request (`.github/workflows/ci.yml`).

To see a change in the real app without touching your own settings, drive it off screen with `scripts/drive.sh`
(its own home folder). Work on **copies** of photographs in a scratch folder: the app writes `.qlick` files beside
what it edits. Never commit photographs.

## Writing the change

- The interface is in English, in the app's own words. Don't name other apps in it; say what a control does.
- Red is the lab's mark colour. Panels follow QLab's look (rounded red sliders, Liquid Glass).
- Something added to one view (contact sheet, grid, film strip, Develop, Compare) goes to every view that shows the
  same thing.
- Comments say *why*, above the code. New code and comments say "the lab" or "Qlick Lab".
- One concern per pull request. Moving files and changing behaviour go in separate pull requests.

## Licence

Qlick Lab is GPL-3.0. By contributing you agree your work is published under it. See [LICENSES.md](LICENSES.md) for
what Qlick Lab includes from others.
