#!/usr/bin/env bash
# Qlick Lab — builds this checkout's app and installs it as /Applications/Qlick Lab.app, then links it from the
# working folder (the main checkout's root), so the version just committed is at hand in both places.
#
#   scripts/install.sh             build, then install
#   scripts/install.sh --no-build  install what dist/qlick-lab already holds
#
# A Qlick Lab that's open is asked to quit first (it saves as it quits, and asks if an import or an export is
# running); if it was open, the new one is opened again behind the other windows. The old app goes to the Trash,
# never deleted outright.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
built="$root/${DIST_DIR:-dist/qlick-lab}/Qlick Lab.app"
installed="/Applications/Qlick Lab.app"

[[ "${1:-}" == "--no-build" ]] || scripts/build_app.sh
[[ -d "$built" ]] || { echo "Nothing built at $built" >&2; exit 1; }

# Quit the installed app if it runs, as a person would: it can refuse (a question still open), and then nothing is replaced.
# Asked of Launch Services, not with pgrep: pgrep reads every process's arguments and can hang behind a process stuck
# on a network disk that doesn't answer (a NAS gone away).
running() { [[ -n "$(perl -e 'alarm 10; exec @ARGV' lsappinfo find bundleid=be.jackfrom.qlicklab 2>/dev/null)" ]]; }
was_running=false
if running; then
    was_running=true
    osascript -e 'tell application id "be.jackfrom.qlicklab" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do running || break; sleep 0.5; done
    if running; then
        echo "Qlick Lab didn't quit (a question may be open in it): nothing was installed." >&2
        exit 1
    fi
fi

# The new app beside the old one, then swapped, so there's never a moment without one.
staging="/Applications/.Qlick Lab.installing.app"
rm -rf "$staging"
ditto "$built" "$staging"
if [[ -d "$installed" ]]; then
    osascript -e "tell application \"Finder\" to delete (POSIX file \"$installed\" as alias)" >/dev/null 2>&1 \
        || mv "$installed" "$HOME/.Trash/Qlick Lab $(date +%Y%m%d-%H%M%S).app"
fi
mv "$staging" "$installed"
codesign --verify --strict "$installed"
# Launch Services learns the new version (its icon, its document types).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed" >/dev/null 2>&1 || true

# A link in the working folder: the main checkout's root, whichever worktree this runs from. Kept out of git.
main="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
ln -sfn "$installed" "$main/Qlick Lab.app"
exclude="$(git rev-parse --git-common-dir)/info/exclude"
grep -qxF "/Qlick Lab.app" "$exclude" 2>/dev/null || echo "/Qlick Lab.app" >> "$exclude"

$was_running && open -g "$installed"
echo "Installed: $installed  ($(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD); linked from $main/Qlick Lab.app)"
