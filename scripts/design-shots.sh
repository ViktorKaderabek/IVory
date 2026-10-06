#!/bin/bash
# Captures every screen and state of the app at the size of the design (1280×900), so the result can be
# held next to "IVory Redesign v2". One launch = one picture (the app quits after it).
#
#   scripts/design-shots.sh <folder> [dark|light] [state …]
#
# Without a list of states it goes through all of them. The states are the same ones the design has.
set -u
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/ivory-shots}"
LOOK="${2:-dark}"
shift 2 2>/dev/null || shift $#
BIN=app/.build/debug/PoGoInventoryManager
[ -x "$BIN" ] || { echo "build it first: (cd app && swift build)"; exit 1; }
mkdir -p "$OUT"

# name | the environment that makes the state
STATES=(
  "01-run-ready|IVORY_PREVIEW=none IVORY_STEP=rename"
  "02-run-running|IVORY_PREVIEW=running"
  "03-run-done|IVORY_PREVIEW=done"
  "04-run-ivtags|IVORY_PREVIEW=none IVORY_STEP=iv"
  "04b-run-weak|IVORY_PREVIEW=none IVORY_STEP=weak"
  "04c-run-dup|IVORY_PREVIEW=none IVORY_STEP=duplicates"
  "04d-run-pvp|IVORY_PREVIEW=none IVORY_STEP=pvp"
  "04e-run-bat|IVORY_PREVIEW=none IVORY_STEP=battle"
  "05-storage|IVORY_PREVIEW=none IVORY_PAGE=storage"
  "06-storage-detail|IVORY_PREVIEW=none IVORY_PAGE=storage IVORY_DETAIL=1"
  "07-raids|IVORY_PREVIEW=none IVORY_PAGE=raids"
  "08-pvp|IVORY_PREVIEW=none IVORY_PAGE=pvp"
  "09-upgrades|IVORY_PREVIEW=none IVORY_PAGE=powerups"
  "09b-upgrades-pvp|IVORY_PREVIEW=none IVORY_PAGE=powerups IVORY_DETAIL=pvp"
  "09c-upgrades-raid|IVORY_PREVIEW=none IVORY_PAGE=powerups IVORY_DETAIL=raid"
  "10-settings|IVORY_PREVIEW=none IVORY_PAGE=settings"
  "11-banner|IVORY_PREVIEW=none IVORY_BANNER=1"
  "12-firststart|IVORY_PREVIEW=none IVORY_SHOTS_CONSENT=1"
)


for entry in "${STATES[@]}"; do
  name="${entry%%|*}"; envs="${entry#*|}"
  if [ $# -gt 0 ]; then
    hit=0; for w in "$@"; do case "$name" in *"$w"*) hit=1;; esac; done
    [ $hit -eq 1 ] || continue
  fi
  echo "→ $name ($LOOK)"
  env $envs \
      IVORY_SHOTS="$OUT" IVORY_SHOTS_NAME="$name-$LOOK" IVORY_SHOTS_LOOK="$LOOK" \
      IVORY_SHOTS_WIDTH=1280 IVORY_SHOTS_HEIGHT=900 IVORY_SHOTS_WAIT="${IVORY_SHOTS_WAIT:-3}" \
      "$BIN" 2>/dev/null | grep -E '^[✔✖]' || echo "  ✖ no shot"
  # let the window go before the next one opens – two of them on screen at once and the capture
  # can come back with the other one's content
  while pgrep -f "$BIN" >/dev/null 2>&1; do sleep 0.2; done
  sleep 0.4
done
echo "done → $OUT"
