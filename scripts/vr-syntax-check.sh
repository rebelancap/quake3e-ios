#!/usr/bin/env bash
# vr-syntax-check.sh — fast -fsyntax-only pass over overlay files with the
# visionOS target's exact defines. Turns a multi-minute full build into a
# ~10-second answer while iterating on an overlay patch.
#
# Usage: scripts/vr-syntax-check.sh code/renderervk/tr_main.c [more…]
#        (paths relative to build/src-overlay, with or without the .c)
#
# THE SHAPE MATTERS. The donor version of this script was inverted for hard
# errors from the day it was written: it ran the compiler in a pipeline
# (`$CC … 2>&1 | head -30 | grep -q .`) under `set -o pipefail`, and pipefail
# makes a pipeline's status the LAST non-zero one — so a compile that FAILED
# (clang exit 1) made the pipeline non-zero regardless of what grep found, the
# `if` took the else branch, and the script printed "OK". It reported failure
# only for files that compiled with warnings, and success for files that did not
# compile at all.
#
# The shape below cannot invert: capture the output, keep the compiler's own
# status, and fail on either.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
O="$ROOT/build/src-overlay"
[ -d "$O/code" ] || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh"; exit 2; }
[ $# -gt 0 ] || { echo "usage: $0 <overlay-file.c> [...]"; exit 2; }

SDK=$(xcrun --sdk xros --show-sdk-path)
CC=$(xcrun --sdk xros -f clang)
# Same defines as scripts/build-visionos.sh (minus USE_CURL, which only gates
# code that needs the device-only libcurl headers).
DEFS="-DNO_VM_COMPILED -DUSE_VULKAN_API -DUSE_OGG_VORBIS -DMACOS_X -DQ3E_MVK_BRIDGE"
INCS="-I$O/code/libogg/include -I$O/code/libvorbis/include -I$O/code/libvorbis/lib"

fail=0
for f in "$@"; do
  rel=${f%.c}
  src="$O/${rel}.c"
  [ -f "$src" ] || { echo "FATAL: no such overlay file: $src"; exit 2; }
  extra=""
  case "$src" in */botlib/*) extra="-DBOTLIB" ;; esac
  out=$($CC -isysroot "$SDK" -target arm64-apple-xros1.0 -O1 -fsyntax-only \
        -Werror=implicit-function-declaration -Wall -Wno-unused-variable \
        $DEFS $INCS $extra "$src" 2>&1)
  rc=$?
  if [ $rc -ne 0 ] || [ -n "$out" ]; then
    echo "=== $rel (clang exit $rc) ==="
    printf '%s\n' "$out" | head -40
    fail=1
  else
    echo "OK  $rel (visionOS)"
  fi
done
exit $fail
