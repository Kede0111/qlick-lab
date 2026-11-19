#!/usr/bin/env bash
# Qlick Lab — drives a development build without the mouse, the keyboard or the front of the screen.
#
#   scripts/drive.sh start            launch off screen, with a home of its own (no real settings touched)
#   scripts/drive.sh send <command>   one automation command (see macos/Sources/QlickLab/App/Automation.swift)
#   scripts/drive.sh shot <file.png>  capture the lab's own window only
#   scripts/drive.sh state            print the lab's state
#   scripts/drive.sh stop
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${QLICK_DRIVE_DIR:-${TMPDIR:-/tmp}/qlick-drive}"
pipe="$work/pipe"
case "${1:-}" in
start)
    mkdir -p "$work/home"
    [[ -p "$pipe" ]] || mkfifo "$pipe"
    bin="$(swift build --package-path "$root/macos" --scratch-path "$root/target/swift-native" --show-bin-path)/QlickLab"
    # Sparkle is built beside the executable; an unbundled run finds it there.
    SPEKTRAFILM_ROOT="$root" QLICK_RENDER_LOG=1 QLICK_AUTOMATION="$pipe" QLICK_OFFSCREEN=1 CFFIXED_USER_HOME="$work/home" \
        DYLD_FRAMEWORK_PATH="$(dirname "$bin")" "$bin" >"$work/app.log" 2>&1 </dev/null &
    echo $! > "$work/pid"
    ;;
esac
# Writing to the pipe would wait for ever without the app to read it.
if [[ "${1:-}" =~ ^(send|shot|state)$ ]] && ! kill -0 "$(cat "$work/pid" 2>/dev/null)" 2>/dev/null; then
    echo "Qlick Lab isn't running (see $work/app.log)" >&2; exit 1
fi
case "${1:-}" in
start) ;;
send) shift; printf '%s\n' "$*" > "$pipe" ;;
shot)
    rm -f "$work/winid"; printf 'winid %s\n' "$work/winid" > "$pipe"
    for _ in $(seq 1 50); do [[ -s "$work/winid" ]] && break; sleep 0.1; done
    line="$(sed -n "${3:-1}p" "$work/winid")"
    screencapture -x -o -l "${line%% *}" "$2"
    ;;
state)
    rm -f "$work/state"; printf 'state %s\n' "$work/state" > "$pipe"
    for _ in $(seq 1 50); do [[ -s "$work/state" ]] && break; sleep 0.1; done
    cat "$work/state"
    ;;
stop) [[ -f "$work/pid" ]] && kill "$(cat "$work/pid")" 2>/dev/null || true ;;
*) sed -n '2,9p' "$0"; exit 2 ;;
esac
