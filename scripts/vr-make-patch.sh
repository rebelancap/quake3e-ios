#!/usr/bin/env bash
# vr-make-patch.sh — generate an overlay patch from build/src-base -> build/src-overlay.
#
# Usage: scripts/vr-make-patch.sh patches/00NN-name.patch code/a.c code/b.c …
#
# THE TRAP THIS SCRIPT CANNOT PREVENT, so read it here: after generating patch N
# you MUST re-baseline src-base to include patch N before starting patch N+1.
# Otherwise N+1 is diffed against a pre-N tree, silently contains all of N's
# hunks, and then fails to apply on top of N. The recovery is fiddly:
#
#   scripts/vr-make-patch.sh patches/00NN-thing.patch code/…
#   scripts/sync-overlay.sh && rsync -rlpc --delete build/src-overlay/ build/src-base/
#
# Every step below asserts: an empty diff, a file that does not differ, or a
# patch that does not apply cleanly fails the script rather than producing a
# plausible-looking patch nobody reads until it breaks a build.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BASE=build/src-base
OVL=build/src-overlay

OUT=${1:-}
shift || true
[ -n "$OUT" ] || { echo "usage: $0 <out.patch> <file…>" >&2; exit 2; }
[ $# -gt 0 ] || { echo "FATAL: no files given" >&2; exit 2; }
[ -d "$BASE/code" ] || { echo "FATAL: $BASE missing — rsync src-overlay to it first" >&2; exit 2; }

TMP=$(mktemp)
changed=0
for f in "$@"; do
  [ -f "$BASE/$f" ] || { echo "FATAL: $BASE/$f missing" >&2; rm -f "$TMP"; exit 1; }
  [ -f "$OVL/$f" ]  || { echo "FATAL: $OVL/$f missing" >&2; rm -f "$TMP"; exit 1; }
  if diff -q "$BASE/$f" "$OVL/$f" >/dev/null; then
    echo "FATAL: $f is IDENTICAL in base and overlay — a patch listing an unchanged file is a mistake" >&2
    rm -f "$TMP"; exit 1
  fi
  diff -u "$BASE/$f" "$OVL/$f" |
    sed -e "1s|^--- .*|--- a/$f|" -e "2s|^+++ .*|+++ b/$f|" >> "$TMP"
  changed=$((changed+1))
done

hunks=$(grep -c '^@@' "$TMP" || true)
[ "${hunks:-0}" -gt 0 ] || { echo "FATAL: produced 0 hunks" >&2; rm -f "$TMP"; exit 1; }

mv "$TMP" "$OUT"
echo "wrote $OUT: $changed file(s), $hunks hunk(s)"

# Prove it applies to a pristine base at fuzz 0 before anyone trusts it.
VERIFY=$(mktemp -d)
for f in "$@"; do
  mkdir -p "$VERIFY/$(dirname "$f")"
  cp "$BASE/$f" "$VERIFY/$f"
done
if ! patch -d "$VERIFY" -p1 --fuzz=0 --forward --dry-run < "$OUT" >/dev/null 2>&1; then
  echo "FATAL: $OUT does not apply cleanly to $BASE at --fuzz=0" >&2
  rm -rf "$VERIFY"; exit 1
fi
rm -rf "$VERIFY"
echo "verified: applies to $BASE at --fuzz=0"
