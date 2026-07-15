#!/bin/bash
# ios-bench.sh — launch Quake3e into a scenario FOREGROUND, verify it is
# actually rendering, then capture the engine's own Q3E_FT telemetry (wall /
# engine-frame / sim-rate / thermal, one line per ~5s window) over N seconds
# via the Wi-Fi console bridge. The no-USB counterpart to ios-trace.sh — good
# for A/B scenario sweeps (MSAA on/off, bot counts, maps) without Instruments.
#
# Usage: ios-bench.sh <tag> <seconds> "<Q3E_ARGS>"
#   ios-bench.sh stress-msaa 90 "+set r_ext_multisample 8 +set sv_pure 0 +set bot_minplayers 12 +map q3dm17"
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=960B5E4D-DD8F-57EF-A7B7-7B84B8633496
BUNDLE=com.rebelancap.quake3e
HOST=Austins-iPhone.local; PORT=27999
TAG="${1:?tag}"; SECS="${2:?seconds}"; ARGS="${3:-}"
OUT=artifacts/runs; mkdir -p "$OUT"

echo "== launching FOREGROUND: $ARGS"
xcrun devicectl device process launch --terminate-existing --device "$DEV" \
  --environment-variables "{\"Q3E_CONSOLE\":\"1\",\"Q3E_ARGS\":\"$ARGS\"}" \
  "$BUNDLE" >/dev/null 2>&1
up=0; for i in $(seq 1 30); do nc -z -G 2 "$HOST" "$PORT" 2>/dev/null && { up=1; break; }; sleep 1; done
[ "$up" = 1 ] || { echo "FATAL: bridge never came up (device asleep?)"; exit 1; }
sleep 12   # settle + map load

# foreground/render guard: a backgrounded app produces no frames
FT=$({ printf 'vkinfo\n'; sleep 6; } | nc "$HOST" "$PORT" 2>/dev/null | grep -a "Q3E_FT" | tail -1 || true)
echo "   verify: ${FT:-<no FT — not rendering>}"
echo "$FT" | grep -qE "wall p50=[789]\." || { echo "FATAL: not rendering at ~120Hz (backgrounded / another app foreground). Retry."; exit 1; }

echo "== capturing ${SECS}s of telemetry -> $OUT/$TAG-ft.txt"
{ printf '\n'; sleep "$SECS"; } | nc "$HOST" "$PORT" > "$OUT/$TAG-ft.txt" 2>&1 || true
echo "== Q3E_FT windows (~5s each):"
grep -aE "Q3E_FT" "$OUT/$TAG-ft.txt" | sed -E 's/Q3E_FT: //'
echo "== window count: $(grep -ac Q3E_FT "$OUT/$TAG-ft.txt")  (fewer than expected => app was backgrounded mid-run)"
