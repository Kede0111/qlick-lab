#!/usr/bin/env bash
# Qlick Lab — builds "Qlick Lab.app" for this Mac into dist/qlick-lab/.
#
#   scripts/build_app.sh              this Mac's architecture (fast)
#   scripts/build_app.sh --universal  Apple silicon + Intel
#   scripts/build_app.sh --dev        a test copy, "Qlick Lab Dev.app" in dist/qlick-lab-dev/, with its own bundle
#                                     identifier (be.jackfrom.qlicklab.dev), so its settings and its Application
#                                     Support folder never touch the installed Qlick Lab's
#   scripts/build_app.sh --speed      a second test copy, "Qlick Lab Dev Speed.app" in dist/qlick-lab-dev-speed/
#                                     (be.jackfrom.qlicklab.devspeed), to try a test branch beside Qlick Lab Dev
#   scripts/build_app.sh --benchmark  with the timing benchmarks compiled in (-DSPEKTRAFILM_BENCHMARK, see
#                                     macos/Sources/QlickLab/Diagnostics); with --dev or --speed, never to ship
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
universal=false; dev=false; speed=false; benchmark=false
for arg in "$@"; do
    case "$arg" in
        --universal) universal=true ;;
        --dev) dev=true ;;
        --speed) dev=true; speed=true ;;
        --benchmark) benchmark=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
if $speed; then
    name="Qlick Lab Dev Speed"; bundle_id="be.jackfrom.qlicklab.devspeed"; dist="${DIST_DIR:-dist/qlick-lab-dev-speed}"
elif $dev; then
    name="Qlick Lab Dev"; bundle_id="be.jackfrom.qlicklab.dev"; dist="${DIST_DIR:-dist/qlick-lab-dev}"
else
    name="Qlick Lab"; bundle_id="be.jackfrom.qlicklab"; dist="${DIST_DIR:-dist/qlick-lab}"
fi
app="$dist/$name.app"

if $universal; then
    rust_targets=(--target aarch64-apple-darwin --target x86_64-apple-darwin)
    swift_archs=(--arch arm64 --arch x86_64)
else
    rust_targets=(); swift_archs=()
fi
swift_flags=(); swift_scratch="$target_dir/swift-release"
if $benchmark; then
    $dev || { echo "--benchmark goes with --dev or --speed: a benchmark build is never the app that ships" >&2; exit 1; }
    swift_flags=(-Xswiftc -DSPEKTRAFILM_BENCHMARK); swift_scratch="$target_dir/swift-release-benchmark"
fi

command -v cargo >/dev/null || { echo "Rust is missing: install it from https://rustup.rs" >&2; exit 1; }
# The Xcode project follows the sources and the version on every build, so it never falls behind (`project.yml`).
if $dev; then
    :  # a test copy leaves the committed project alone
elif command -v xcodegen >/dev/null; then
    sed -i '' -e "s/^\(    MARKETING_VERSION: \).*/\1\"$version\"/" -e "s/^\(    CURRENT_PROJECT_VERSION: \).*/\1\"$build\"/" project.yml
    xcodegen generate --quiet
else
    echo "XcodeGen is missing (brew install xcodegen): QlickLab.xcodeproj is not brought up to date" >&2
fi
# The engine's crates carry the app's version too (it names the software in exported files' metadata); Cargo.lock
# follows, offline, before the --locked builds below.
if ! $dev && ! grep -q "^version = \"$version\"$" Cargo.toml; then
    sed -i '' "/^\[workspace.package\]/,/^\[/ s/^version = \".*\"$/version = \"$version\"/" Cargo.toml
    cargo update --workspace --offline --quiet
fi
# The f32 and f64 tools are built apart: Cargo would otherwise unify their features.
cargo build --locked --release -p spektrafilm-native ${rust_targets[@]+"${rust_targets[@]}"} --target-dir "$target_dir"
cargo build --locked --release -p spektrafilm-cli --bin spektrafilm ${rust_targets[@]+"${rust_targets[@]}"} --target-dir "$target_dir"
cargo build --locked --release -p spektrafilm-cli --bin spektrafilm-f64 --features precision-f64 ${rust_targets[@]+"${rust_targets[@]}"} --target-dir "$target_dir"
swift build --package-path macos --scratch-path "$swift_scratch" -c release ${swift_archs[@]+"${swift_archs[@]}"} ${swift_flags[@]+"${swift_flags[@]}"}
swift_bin="$(swift build --package-path macos --scratch-path "$swift_scratch" -c release ${swift_archs[@]+"${swift_archs[@]}"} ${swift_flags[@]+"${swift_flags[@]}"} --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts" "$app/Contents/Frameworks"
cp "$swift_bin/QlickLab" "$app/Contents/MacOS/$name"
# The executable looks for Sparkle beside it in a development build, in Frameworks in the app.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$name" 2>/dev/null || true
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

sed -e "s/\$(EXECUTABLE_NAME)/$name/" -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/" \
    -e "s|<string>Qlick Lab</string>|<string>$name</string>|" \
    -e "s/\$(MARKETING_VERSION)/$version/" -e "s/\$(CURRENT_PROJECT_VERSION)/$build/" -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    macos/QlickLab-Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Updates: the app that ships reads the releases' feed (the appcast.xml attached to the latest GitHub release, written
# by make_dmg.sh) and checks it by itself; an update is accepted only if signed with the private key kept in the
# Keychain of whoever makes the releases (Sparkle's generate_keys). Never in a Dev copy: an update would replace it
# with the app that ships.
if ! $dev; then
    plutil -insert SUFeedURL -string "https://github.com/Kede0111/qlick-lab/releases/latest/download/appcast.xml" "$app/Contents/Info.plist"
    plutil -insert SUPublicEDKey -string "KbESBt5iDO7Y4xkZVsV/Cfj62CQniYMvSE4HDOy94FE=" "$app/Contents/Info.plist"
    plutil -insert SUEnableAutomaticChecks -bool YES "$app/Contents/Info.plist"
fi

# Ad-hoc signatures: the helpers first, then the app. Sparkle keeps its own.
for tool in spektrafilm-native spektrafilm spektrafilm-f64 "$name"; do codesign --force --sign - "$app/Contents/MacOS/$tool"; done
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built: $root/$app  ($name $version, build $build)"
