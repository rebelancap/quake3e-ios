#!/bin/bash
# fetch-moltenvk.sh — provision the MoltenVK static xcframework (all platforms
# incl. the xros/visionOS slice) into vendor/moltenvk (gitignored). Idempotent.
# Needed for the visionOS build; the iOS build uses vendor/moltenvk-ios.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
MVK_VER=1.4.1
DEST="$ROOT/vendor/moltenvk/MoltenVK.xcframework"

if [ -f "$DEST/xros-arm64/libMoltenVK.a" ]; then
  echo "MoltenVK xros slice already present: $DEST"
  exit 0
fi

TMP="$ROOT/build/moltenvk-dl"
rm -rf "$TMP"; mkdir -p "$TMP"
echo "== downloading MoltenVK $MVK_VER (all platforms)"
curl -L --fail -o "$TMP/mvk.tar" \
  "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MVK_VER/MoltenVK-all.tar"
tar xf "$TMP/mvk.tar" -C "$TMP"
XC=$(find "$TMP" -iname MoltenVK.xcframework -path "*static*" | head -1)
[ -d "$XC" ] || { echo "FATAL: static MoltenVK.xcframework not found in archive"; exit 1; }
mkdir -p "$ROOT/vendor/moltenvk"
rm -rf "$DEST"; cp -R "$XC" "$DEST"
rm -rf "$TMP"
[ -f "$DEST/xros-arm64/libMoltenVK.a" ] || { echo "FATAL: xros slice missing after fetch"; exit 1; }
echo "MOLTENVK OK: $DEST (xros-arm64 present)"
