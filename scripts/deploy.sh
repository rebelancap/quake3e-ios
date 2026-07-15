#!/bin/bash
# deploy-spike.sh — build + install + data-verify + optional launch for the
# iOS spike, encoding the device-loop facts from D-007:
#   * every devicectl install rotates the data container → verify paks and
#     re-push after EVERY install; never assume data survived
#   * engine exit codes and install success prints are not trusted — assert
#     on device-side file listings and console log content
#
# Usage: deploy-spike.sh [--launch "<Q3E_ARGS string>"]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
UDID="960B5E4D-DD8F-57EF-A7B7-7B84B8633496" # Austin's iPhone Air
BUNDLE="com.rebelancap.quake3e"

LAUNCH_ARGS=""
DO_LAUNCH=0
if [ "${1:-}" = "--launch" ]; then
  DO_LAUNCH=1
  LAUNCH_ARGS="${2:-}"
fi

./scripts/build-ios.sh

APP="$ROOT/build/ios/xcode/Release-iphoneos/Quake3e.app"
echo "== installing"
xcrun devicectl device install app --device "$UDID" "$APP" > /dev/null

echo "== verifying game data in container"
PAKS=$(xcrun devicectl device info files --device "$UDID" --username mobile \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory Documents/baseq3 2>/dev/null | grep -c "pk3" || true)
if [ "$PAKS" -lt 9 ]; then
  echo "== container has $PAKS paks (install rotated it) — pushing baseq3"
  xcrun devicectl device copy to --device "$UDID" \
    --source "$ROOT/gamedata/baseq3" --destination Documents/baseq3 \
    --user mobile --domain-type appDataContainer --domain-identifier "$BUNDLE" > /dev/null
  PAKS=$(xcrun devicectl device info files --device "$UDID" --username mobile \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --subdirectory Documents/baseq3 2>/dev/null | grep -c "pk3")
  [ "$PAKS" -ge 9 ] || { echo "FATAL: data push failed ($PAKS paks)"; exit 1; }
fi
echo "== $PAKS paks on device"

if [ "$DO_LAUNCH" = 1 ]; then
  echo "== launching with Q3E_ARGS: $LAUNCH_ARGS"
  xcrun devicectl device process launch --device "$UDID" \
    --environment-variables "{\"Q3E_ARGS\": \"$LAUNCH_ARGS\"}" \
    --console "$BUNDLE"
else
  echo "DEPLOY OK (not launched — tap the icon or rerun with --launch)"
fi
