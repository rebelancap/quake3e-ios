#!/bin/bash
# oracle-timedemo.sh — run timedemo four on a macOS oracle build, N times,
# into a per-scenario sandbox homepath; parse fps + TIMEDEMO_FT percentiles.
#
# Usage: oracle-timedemo.sh --renderer gl|vk --tag TAG [--runs N] [--shots]
#                           [--binary PATH] [-- +set foo bar ...]
#
# The engine exits 0 even on fatal errors, so success is asserted by the
# presence of the timedemo result line in the log, never by exit code.
# Display must be awake for vsync'd runs; timedemo runs vsync-off and a
# session-wide caffeinate -dimsu is expected to be active for benches.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

RENDERER=gl; TAG=""; RUNS=3; SHOTS=0; BIN=""; EXTRA=()
while [[ $# -gt 0 ]]; do case "$1" in
  --renderer) RENDERER=$2; shift 2 ;;
  --tag)      TAG=$2; shift 2 ;;
  --runs)     RUNS=$2; shift 2 ;;
  --shots)    SHOTS=1; shift ;;
  --binary)   BIN=$2; shift 2 ;;
  --)         shift; EXTRA=("$@"); break ;;
  *) echo "FATAL: unknown arg $1"; exit 1 ;;
esac; done
[ -n "$TAG" ] || { echo "FATAL: --tag required"; exit 1; }
[ -n "$BIN" ] || BIN="$ROOT/build/oracle-$RENDERER/release-darwin-aarch64/quake3e.aarch64"
[ -x "$BIN" ] || { echo "FATAL: missing $BIN (run scripts/build-oracle.sh)"; exit 1; }

if [ "$RENDERER" = vk ]; then
  export SDL_VULKAN_LIBRARY=/opt/homebrew/lib/libMoltenVK.dylib
  [ -f "$SDL_VULKAN_LIBRARY" ] || { echo "FATAL: MoltenVK missing (brew install molten-vk)"; exit 1; }
fi

RUNDIR="$ROOT/artifacts/runs/$TAG"
mkdir -p "$RUNDIR/baseq3"

if [ "$SHOTS" = 1 ]; then
  printf 'timedemo 1\nset nextdemo quit\ndemo four\nwait 250\nscreenshotJPEG\nwait 350\nscreenshotJPEG\nwait 400\nscreenshotJPEG\n' > "$RUNDIR/baseq3/bench.cfg"
else
  printf 'timedemo 1\nset nextdemo quit\ndemo four\n' > "$RUNDIR/baseq3/bench.cfg"
fi

SUMMARY="$RUNDIR/results.txt"
{
  echo "# tag=$TAG renderer=$RENDERER runs=$RUNS shots=$SHOTS"
  echo "# extra: ${EXTRA[*]:-none}"
  echo "# upstream: $(grep '^commit' upstream.pin)"
  echo "# binary: $BIN sha256=$(shasum -a 256 "$BIN" | cut -c1-12)"
  echo "# date: $(date '+%Y-%m-%d %H:%M:%S') thermal:$(pmset -g therm 2>/dev/null | grep -i speed | tr -d ' \t' || echo n/a)"
} > "$SUMMARY"

for i in $(seq 1 "$RUNS"); do
  LOG="$RUNDIR/run$i.log"
  # engine exit code is meaningless — asserted below on log content
  "$BIN" \
    +set fs_basepath "$ROOT/gamedata" \
    +set fs_homepath "$RUNDIR" \
    +set r_fullscreen 0 +set r_mode -1 +set r_customWidth 1920 +set r_customHeight 1080 \
    +set r_swapInterval 0 \
    ${EXTRA[@]:+"${EXTRA[@]}"} \
    +exec bench.cfg > "$LOG" 2>&1 || true
  FPS=$(grep -E "^[0-9]+ frames, .* seconds: .* fps" "$LOG" | tail -1 || true)
  FT=$(grep "^TIMEDEMO_FT:" "$LOG" | tail -1 || true)
  [ -n "$FPS" ] || { echo "FATAL: no timedemo result in $LOG — tail:"; tail -8 "$LOG"; exit 1; }
  echo "run$i: $FPS" >> "$SUMMARY"
  [ -n "$FT" ] && echo "run$i: $FT" >> "$SUMMARY"
done

if [ "$SHOTS" = 1 ]; then
  ls "$RUNDIR"/baseq3/screenshots/*.jpg >/dev/null 2>&1 || { echo "FATAL: shots requested but no screenshots produced"; exit 1; }
  echo "# screenshots: $(ls "$RUNDIR"/baseq3/screenshots/ | tr '\n' ' ')" >> "$SUMMARY"
fi

cat "$SUMMARY"
