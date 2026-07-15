#!/bin/bash
# build-oracle.sh — sync overlay, then build both macOS oracle flavors from it.
#
# Two separate BUILD_DIRs because darwin builds are static-renderer
# (USE_RENDERER_DLOPEN=0): mixing RENDERER_DEFAULT values in one object dir
# would silently mix objects compiled under different feature defines.
# The engine binary's exit code is meaningless (it exits 0 on fatal errors),
# so this script asserts on produced artifacts, and runners assert on log
# content.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

./scripts/sync-overlay.sh

JOBS=$(sysctl -n hw.ncpu)
for R in gl vk; do
  case $R in
    gl) RD=opengl ;;
    vk) RD=vulkan ;;
  esac
  echo "== building oracle-$R (RENDERER_DEFAULT=$RD)"
  make -C build/src-overlay release BUILD_DIR="$ROOT/build/oracle-$R" RENDERER_DEFAULT=$RD -j"$JOBS" > "$ROOT/build/oracle-$R-make.log" 2>&1 \
    || { echo "FATAL: make failed for oracle-$R — tail of log:"; tail -30 "$ROOT/build/oracle-$R-make.log"; exit 1; }
  BIN="$ROOT/build/oracle-$R/release-darwin-aarch64/quake3e.aarch64"
  [ -x "$BIN" ] || { echo "FATAL: $BIN not produced"; exit 1; }
  echo "   $BIN sha256=$(shasum -a 256 "$BIN" | cut -c1-12)"
done
echo "ORACLE BUILDS OK"
