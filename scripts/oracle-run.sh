#!/bin/bash
# oracle-run.sh — interactive oracle launcher for eyeball/feel sessions.
#
# Usage: oracle-run.sh [gl|vk] [-- +set foo bar ...]
#   Settings persist per-renderer under artifacts/runs/play-<renderer>/.
#   Runs fullscreen at desktop resolution with vsync ON (play config,
#   not a benchmark config — use oracle-timedemo.sh for numbers).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

RENDERER=${1:-gl}
shift || true
[ "${1:-}" = "--" ] && shift
case "$RENDERER" in gl|vk) ;; *) echo "FATAL: renderer must be gl or vk"; exit 1;; esac

BIN="$ROOT/build/oracle-$RENDERER/release-darwin-aarch64/quake3e.aarch64"
[ -x "$BIN" ] || { echo "FATAL: missing $BIN (run scripts/build-oracle.sh)"; exit 1; }

if [ "$RENDERER" = vk ]; then
  export SDL_VULKAN_LIBRARY=/opt/homebrew/lib/libMoltenVK.dylib
fi

HOME_DIR="$ROOT/artifacts/runs/play-$RENDERER"
mkdir -p "$HOME_DIR"

exec "$BIN" \
  +set fs_basepath "$ROOT/gamedata" \
  +set fs_homepath "$HOME_DIR" \
  +set r_fullscreen 1 +set r_mode -2 \
  +set r_swapInterval 1 \
  "$@"
