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

# The updates' feed: dist/appcast.xml names this DMG with its signature (the private key in this Mac's Keychain, made
# once by Sparkle's generate_keys). Attach it to the GitHub release beside the DMG: the app reads the latest one.
build="$(sed -n 's/^QLICK_LAB_BUILD=//p' scripts/version)"
sign_update="${SPARKLE_BIN:-target/swift-release/artifacts/sparkle/Sparkle/bin}/sign_update"
[[ -x "$sign_update" ]] || { echo "No $sign_update: build the app once (scripts/build_app.sh) to fetch Sparkle" >&2; exit 1; }
signature="$("$sign_update" "$dmg")"   # sparkle:edSignature="…" length="…"
release="https://github.com/Kede0111/qlick-lab/releases"
cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Qlick Lab</title>
    <link>$release</link>
    <item>
      <title>Qlick Lab $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$release/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="$release/download/v$version/Qlick-Lab-$version.dmg" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout dist/appcast.xml
echo "Feed: $root/dist/appcast.xml (attach it to the release v$version with the DMG)"
