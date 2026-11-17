#!/usr/bin/env bash
# Qlick Lab — makes the app icon from the project's artwork (assets/icon.png, a square picture, edge to edge):
#   - macos/AppIcon.icon, Icon Composer's format: macOS 26 and later cut it to their own rounded shape;
#   - assets/qlick-lab.icns, the picture set in the rounded tile by macos/Sources/QlickLab/Lab/AppIcon.swift, for
#     older macOS.
#
#   scripts/make_icon.sh                     from assets/icon.png
#   scripts/make_icon.sh other-picture.png   from another square picture
#   scripts/make_icon.sh --drawn             the icon the lab draws itself (a ringed frame of film)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$(swift build --package-path "$root/macos" --scratch-path "$root/target/swift-native" --show-bin-path)/QlickLab"
swift build --package-path "$root/macos" --scratch-path "$root/target/swift-native" >/dev/null
out="$(mktemp -d)"
artwork="${1:-$root/assets/icon.png}"
if [[ "$artwork" == "--drawn" ]]; then artwork=(); else artwork=("$artwork"); fi
DYLD_FRAMEWORK_PATH="$(dirname "$bin")" "$bin" --qlick-icon "$out" ${artwork[@]+"${artwork[@]}"}
# The asset catalog's icon is the Icon Composer file now; the old icon set would clash with its name.
rm -rf "$root/macos/Assets.xcassets/AppIcon.appiconset"
if [[ ${#artwork[@]} -gt 0 ]]; then
    mkdir -p "$root/macos/AppIcon.icon/Assets"
    cp "$out/icon-square.png" "$root/macos/AppIcon.icon/Assets/icon.png"
fi
iconutil -c icns "$out/QlickLab.iconset" -o "$root/assets/qlick-lab.icns"
cp "$out/QlickLab.iconset/icon_512x512@2x.png" "$root/assets/qlick-lab.png"
echo "Icon written: macos/AppIcon.icon, assets/qlick-lab.icns, assets/qlick-lab.png"
