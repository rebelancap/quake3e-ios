#!/usr/bin/env bash
# ios-syntax-check.sh — the sibling of vr-syntax-check.sh for the PLAIN iOS
# target. Almost every engine file is shared between the iPhone app and the
# visionOS app, so "the visionOS build is green" is not the same claim as "the
# iPhone build still compiles" — and the iPhone app is the shipping one.
#
# Usage: scripts/ios-syntax-check.sh code/renderervk/tr_main.c [more…]
#
# Same non-invertible shape as vr-syntax-check.sh: capture the output, keep the
# compiler's status, fail on either. (The donor's iOS twin still carries the
# inverted-pipeline bug; do not copy that one.)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
O="$ROOT/build/src-overlay"
[ -d "$O/code" ] || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh"; exit 2; }
[ $# -gt 0 ] || { echo "usage: $0 <overlay-file.c> [...]"; exit 2; }

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
DEFS="-DNO_VM_COMPILED -DUSE_VULKAN_API -DUSE_OGG_VORBIS -DMACOS_X -DQ3E_MVK_BRIDGE"
INCS="-I$O/code/libogg/include -I$O/code/libvorbis/include -I$O/code/libvorbis/lib"

fail=0
for f in "$@"; do
  rel=${f%.c}
  src="$O/${rel}.c"
  [ -f "$src" ] || { echo "FATAL: no such overlay file: $src"; exit 2; }
  extra=""
  case "$src" in */botlib/*) extra="-DBOTLIB" ;; esac
  out=$($CC -isysroot "$SDK" -target arm64-apple-ios16.0 -O1 -fsyntax-only \
        -Werror=implicit-function-declaration -Wall -Wno-unused-variable \
        $DEFS $INCS $extra "$src" 2>&1)
  rc=$?
  if [ $rc -ne 0 ] || [ -n "$out" ]; then
    echo "=== $rel (clang exit $rc) ==="
    printf '%s\n' "$out" | head -40
    fail=1
  else
    echo "OK  $rel (iOS)"
  fi
done
exit $fail
