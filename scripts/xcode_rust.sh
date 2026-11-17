#!/usr/bin/env bash
# Qlick Lab — Xcode build phase: builds the Rust engine and puts its three tools beside the app's executable,
# where the app looks for them (`EnginePaths.locate`). Cargo rebuilds only what changed.
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v cargo >/dev/null || { echo "error: Rust is missing. Install it from https://rustup.rs, then build again." >&2; exit 1; }
cd "$SRCROOT"
# Cargo's build scripts compile Objective-C (Apple's RAW decoder): they need the macOS SDK and the same floor as the app.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --locked --release -p spektrafilm-native
cargo build --locked --release -p spektrafilm-cli --bin spektrafilm
cargo build --locked --release -p spektrafilm-cli --bin spektrafilm-f64 --features precision-f64
destination="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH"
mkdir -p "$destination"
for tool in spektrafilm-native spektrafilm spektrafilm-f64; do
    cp "target/release/$tool" "$destination/$tool"
    codesign --force --sign - "$destination/$tool"
done
