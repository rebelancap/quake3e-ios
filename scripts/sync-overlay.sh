#!/bin/bash
# sync-overlay.sh — regenerate build/src-overlay = pristine vendor + patches/*.patch
#
# Content-checksum sync (rsync -c, deliberately NO -t): a changed file gets a
# fresh mtime so make rebuilds exactly the changed set. Preserving mtimes let
# ninja/make silently reuse stale objects in the predecessor project (q2repro
# M-004 false A/B — a day lost). Patches apply with --fuzz=0: any drift from
# upstream fails the sync loudly. Nothing inside vendor/ is ever touched.
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR=vendor/Quake3e
OVERLAY=build/src-overlay

[ -d "$VENDOR/code" ] || { echo "FATAL: $VENDOR missing — clone upstream at the commit in upstream.pin"; exit 1; }

mkdir -p "$OVERLAY"
rsync -rlpc --delete --exclude=.git "$VENDOR/" "$OVERLAY/"

applied=0
shopt -s nullglob
for p in patches/[0-9][0-9][0-9][0-9]-*.patch; do
  echo "== applying $p"
  patch -d "$OVERLAY" -p1 --fuzz=0 --no-backup-if-mismatch < "$p"
  applied=$((applied+1))
done

echo "OVERLAY OK: $applied patch(es) onto $(grep '^commit' upstream.pin)"
