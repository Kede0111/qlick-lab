#!/usr/bin/env bash
# Qlick Lab — the universal app (Apple silicon + Intel) in a disk image for a GitHub release:
# dist/Qlick-Lab-<version>.dmg, with a link to Applications to drag it onto.
#
#   scripts/make_dmg.sh              build the universal app, then the DMG
#   scripts/make_dmg.sh --no-build   the DMG of what dist/qlick-lab already holds
#
# The app is signed ad hoc, not notarized: the README says how to open it the first time.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
version="$(sed -n 's/^QLICK_LAB_VERSION=//p' scripts/version)"
dist="${DIST_DIR:-dist/qlick-lab}"
app="$dist/Qlick Lab.app"

[[ "${1:-}" == "--no-build" ]] || scripts/build_app.sh --universal
[[ -d "$app" ]] || { echo "Nothing built at $app" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Qlick Lab.app"
ln -s /Applications "$stage/Applications"
dmg="dist/Qlick-Lab-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Qlick Lab $version" -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$dmg"
echo "Built: $root/$dmg"
shasum -a 256 "$dmg"
