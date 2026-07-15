#!/bin/bash
# ios-cap.sh — from a RUNNING app (console bridge up), grab a screenshot and a
# few seconds of console (Q3E_FT lines), and pull the screenshot to artifacts/.
# The same-run content artifact the charter requires next to any perf number.
#
# Usage: ios-cap.sh <tag> [seconds]   (app must be running with Q3E_CONSOLE=1)
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=960B5E4D-DD8F-57EF-A7B7-7B84B8633496
BUNDLE=com.rebelancap.quake3e
HOST=Austins-iPhone.local
PORT=27999
TAG="${1:-cap}"
SECS="${2:-14}"
OUT=artifacts/runs
mkdir -p "$OUT"

nc -z -G 3 "$HOST" "$PORT" 2>/dev/null || { echo "FATAL: bridge down — launch with Q3E_CONSOLE=1 first"; exit 1; }

# hold stdin open (sleep) so the bridge keeps streaming output back to us
{ printf 'screenshotJPEG\nstatus\n'; sleep "$SECS"; } | nc "$HOST" "$PORT" > "$OUT/$TAG-console.txt" 2>&1 || true
echo "== console (FT / status):"
grep -aE "Q3E_FT|Wrote .*screenshots|players connected|map: " "$OUT/$TAG-console.txt" | tail -10 || true

# pull the newest screenshot the engine just wrote
NEWEST=$(xcrun devicectl device info files --device "$DEV" --username mobile \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory Documents/baseq3/screenshots 2>/dev/null | grep -aoE '[A-Za-z0-9_.-]+\.jpg' | sort | tail -1 || true)
if [ -n "$NEWEST" ]; then
  xcrun devicectl device copy from --device "$DEV" --user mobile \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Documents/baseq3/screenshots/$NEWEST" --destination "$OUT/$TAG.jpg" >/dev/null 2>&1 \
    && echo "== screenshot pulled: $OUT/$TAG.jpg ($NEWEST)" || echo "== screenshot pull FAILED"
else
  echo "== no screenshot found to pull"
fi
