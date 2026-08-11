#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Read-only UI smoke test for the installed Developer build. Drives the real
# app through Accessibility (menu panel, quick panel, Settings), captures
# screenshots and fails loudly when a surface does not appear. It never
# changes preferences: everything it opens is closed again, and no toggle is
# flipped. Requires Accessibility + Screen Recording permission for the
# terminal running it.
#
# Usage: ./Tools/ui-smoke.sh [output-dir]
set -uo pipefail

APP="/Applications/Vorssaint (Developer).app"
PROCESS="VorssaintDeveloper"
OUT="${1:-$(mktemp -d /tmp/vorss-ui-smoke.XXXXXX)}"
mkdir -p "$OUT"
FAILURES=0
LAYOUT_LOG="$OUT/layout-warnings.log"

step() { echo "▸ $1"; }
fail() { echo "✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✓ $1"; }

ax() { osascript -e "tell application \"System Events\" to tell process \"$PROCESS\" to $1" 2>/dev/null; }

if [[ ! -d "$APP" ]]; then
    echo "✗ $APP not installed — run ./build.sh --dev --install first" >&2
    exit 1
fi

step "Launching the app"
open "$APP"
sleep 3
if ! pgrep -xq "$PROCESS"; then
    fail "app process did not start"
    exit 1
fi
pass "process running"

# Capture AppKit layout recursion warnings while we exercise Settings.
: > "$LAYOUT_LOG"
/usr/bin/log stream \
    --style compact \
    --predicate 'process == "VorssaintDeveloper" AND eventMessage CONTAINS "layoutSubtreeIfNeeded"' \
    >"$LAYOUT_LOG" 2>/dev/null &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

step "Status item"
ITEMS=$(ax 'count menu bar items of menu bar 2')
if [[ "${ITEMS:-0}" -ge 1 ]]; then
    pass "menu bar has $ITEMS status item(s)"
else
    fail "no status item in the menu bar"
fi

step "Menu panel"
ax 'click menu bar item 1 of menu bar 2' >/dev/null
sleep 1.5
if [[ "$(ax 'exists pop over 1 of menu bar item 1 of menu bar 2')" == "true" ]]; then
    pass "panel popover opened"
    screencapture -x "$OUT/panel.png"
else
    fail "panel popover did not open"
fi
osascript -e 'tell application "System Events" to key code 53' >/dev/null
sleep 0.8

step "Quick panel"
osascript -e 'tell application "System Events" to keystroke "v" using {control down, command down}' >/dev/null
sleep 1.5
QP=$(ax 'get position of window "Vorssaint"')
if [[ -n "${QP:-}" ]]; then
    pass "quick panel window at $QP"
    screencapture -x "$OUT/quick-panel.png"
else
    fail "quick panel window did not appear"
fi
osascript -e 'tell application "System Events" to key code 53' >/dev/null
sleep 0.8

open_settings() {
    ax 'click menu bar item 1 of menu bar 2' >/dev/null
    sleep 1.2
    ax 'click button 9 of group 1 of pop over 1 of menu bar item 1 of menu bar 2' >/dev/null
    sleep 1.5
}

close_settings() {
    ax 'click button 1 of window "Vorssaint Settings"' >/dev/null
    sleep 0.6
}

step "Settings window"
START_MS=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
open_settings
SW=$(ax 'get position of window "Vorssaint Settings"')
END_MS=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
ELAPSED=$((END_MS - START_MS))
if [[ -n "${SW:-}" ]]; then
    pass "settings window at $SW (${ELAPSED} ms)"
    if (( ELAPSED > 3000 )); then
        fail "settings window took ${ELAPSED} ms to appear (> 3000 ms)"
    else
        pass "settings open within 3 s budget"
    fi
    screencapture -x "$OUT/settings.png"
else
    fail "settings window did not open"
fi

step "Settings Mouse page"
# Sidebar rows are outline rows; try common English/German titles.
MOUSE_CLICKED=0
for title in "Mouse & Trackpad" "Maus & Trackpad" "Mouse" "Maus"; do
    if ax "click UI element \"$title\" of outline 1 of scroll area 1 of splitter group 1 of window \"Vorssaint Settings\"" >/dev/null; then
        MOUSE_CLICKED=1
        break
    fi
done
sleep 1.2
if (( MOUSE_CLICKED )); then
    pass "navigated toward Mouse settings"
    screencapture -x "$OUT/settings-mouse.png"
else
    # Soft fail: sidebar AX labels vary by localization/build.
    echo "  ⚠ could not click Mouse sidebar row by title; continuing"
fi

step "Settings open/close stress"
close_settings
for i in 1 2 3; do
    open_settings
    if [[ -z "$(ax 'get position of window "Vorssaint Settings"')" ]]; then
        fail "settings window missing on open #$i"
    fi
    close_settings
done
pass "settings survived repeated open/close"

kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
sleep 0.3

step "Layout recursion warnings"
if rg -q 'layoutSubtreeIfNeeded' "$LAYOUT_LOG" 2>/dev/null; then
    if rg -qi 'recursion|already being laid out' "$LAYOUT_LOG" 2>/dev/null; then
        fail "layoutSubtreeIfNeeded recursion warning observed (see $LAYOUT_LOG)"
    else
        pass "layoutSubtreeIfNeeded mentioned without recursion warning"
    fi
else
    pass "no layoutSubtreeIfNeeded warnings during smoke"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "UI SMOKE OK — screenshots in $OUT"
else
    echo "UI SMOKE FAILED ($FAILURES failure(s)) — screenshots in $OUT" >&2
    exit 1
fi
