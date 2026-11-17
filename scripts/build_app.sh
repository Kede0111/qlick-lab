#!/usr/bin/env bash
# Qlick Lab — builds "Qlick Lab.app" for this Mac into dist/qlick-lab/.
#
#   scripts/build_app.sh              this Mac's architecture (fast)
#   scripts/build_app.sh --universal  Apple silicon + Intel
#
# Needs Xcode and Rust (rustup; ~/.cargo/bin is added to PATH here). The app is ad-hoc signed, not notarized.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
version="$(sed -n 's/^QLICK_LAB_VERSION=//p' scripts/version)"
build="$(sed -n 's/^QLICK_LAB_BUILD=//p' scripts/version)"
target_dir="${BUILD_TARGET_DIR:-target}"
dist="${DIST_DIR:-dist/qlick-lab}"
app="$dist/Qlick Lab.app"

if [[ "${1:-}" == "--universal" ]]; then
    rust_targets=(--target aarch64-apple-darwin --target x86_64-apple-darwin)
    swift_archs=(--arch arm64 --arch x86_64)
else
    rust_targets=(); swift_archs=()
fi

command -v cargo >/dev/null || { echo "Rust is missing: install it from https://rustup.rs" >&2; exit 1; }
# The f32 and f64 tools are built apart: Cargo would otherwise unify their features.
cargo build --locked --release -p spektrafilm-native ${rust_targets[@]+"${rust_targets[@]}"} --target-dir "$target_dir"
cargo build --locked --release -p spektrafilm-cli --bin spektrafilm ${rust_targets[@]+"${rust_targets[@]}"} --target-dir "$target_dir"
cargo build --locked --release -p spektrafilm-cli --bin spektrafilm-f64 --features precision-f64 ${rust_targets[@]+"${rust_targets[@]}"} --target-dir "$target_dir"
swift build --package-path macos --scratch-path "$target_dir/swift-release" -c release ${swift_archs[@]+"${swift_archs[@]}"}
swift_bin="$(swift build --package-path macos --scratch-path "$target_dir/swift-release" -c release ${swift_archs[@]+"${swift_archs[@]}"} --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts" "$app/Contents/Frameworks"
cp "$swift_bin/QlickLab" "$app/Contents/MacOS/Qlick Lab"
# The executable looks for Sparkle beside it in a development build, in Frameworks in the app.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Qlick Lab" 2>/dev/null || true
ditto "$swift_bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
for tool in spektrafilm-native spektrafilm spektrafilm-f64; do
    if [[ ${#rust_targets[@]} -gt 0 ]]; then
        lipo -create -output "$app/Contents/MacOS/$tool" "$target_dir/aarch64-apple-darwin/release/$tool" "$target_dir/x86_64-apple-darwin/release/$tool"
    else
        cp "$target_dir/release/$tool" "$app/Contents/MacOS/$tool"
    fi
done
cp -R data "$app/Contents/Resources/data"
cp macos/Fonts/* "$app/Contents/Resources/Fonts/"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp LICENSES.md "$app/Contents/Resources/LICENSES.md"
cp assets/qlick-lab.icns "$app/Contents/Resources/qlick-lab.icns"
# The icon: Icon Composer's file, which macOS 26 and later shape themselves; qlick-lab.icns for older macOS.
# Whole paths: actool's helper keeps running between builds, and reads a relative path from the folder of
# whichever project started it.
whole() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$root/$1" ;; esac; }
xcrun actool "$root/macos/Assets.xcassets" "$root/macos/AppIcon.icon" --compile "$(whole "$app")/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist "$(whole "$target_dir")/qlick-assets.plist" >/dev/null

sed -e 's/\$(EXECUTABLE_NAME)/Qlick Lab/' -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/be.jackfrom.qlicklab/' \
    -e "s/\$(MARKETING_VERSION)/$version/" -e "s/\$(CURRENT_PROJECT_VERSION)/$build/" -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    macos/QlickLab-Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Ad-hoc signatures: the helpers first, then the app. Sparkle keeps its own.
for tool in spektrafilm-native spektrafilm spektrafilm-f64 "Qlick Lab"; do codesign --force --sign - "$app/Contents/MacOS/$tool"; done
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built: $root/$app  (Qlick Lab $version, build $build)"
