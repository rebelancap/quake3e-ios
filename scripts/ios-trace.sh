#!/bin/bash
# ios-trace.sh — capture an Instruments trace of Quake3e during live play on
# the device, over USB. Answers the Phase 3 questions the in-engine frame
# timer structurally cannot: CPU core residency (P vs E cores — the charter's
# "potential 2x left on the table on E-cores"), GPU frame time, Game Mode
# engagement, and the FIFO block-vs-work split that M-010/M-011 left open.
#
# Usage: ios-trace.sh [template] [tag]
#   template: "Game Performance" (default) | "Metal System Trace" | "Time Profiler"
#   tag:      output basename (default: trace-run)
#   env TRACE_SECONDS (default 30), Q3E_MAP (default q3dm7)
#
# Requires: device UNLOCKED and connected via USB (xctrace is USB-only). The
# app self-holds the screen awake once foregrounded (idleTimerDisabled), so a
# one-time unlock is enough — but a locked screen = demoted GPU governor =
# garbage numbers (q2repro M-015), so verify it is awake before trusting a run.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
UDID="960B5E4D-DD8F-57EF-A7B7-7B84B8633496" # Austin's iPhone Air, devicectl UDID (launch)
# xctrace uses a DIFFERENT registry than devicectl — USB-oriented, hardware
# UDID. Austin's iPhone is 00008150-000C65E426FB801C there (Court's is
# ...001169A4...; do not trace that one). It must be ONLINE (USB + unlocked).
XCID="00008150-000C65E426FB801C"
BUNDLE="com.rebelancap.quake3e"
HOST="Austins-iPhone.local"
PORT=27999

# xctrace needs the developer disk image mounted AND the phone unlocked; a
# single "online" blip during a connection cycle isn't enough (we saw the
# device flap online for a second then drop). Wait for STABLE online — 4
# consecutive checks (~12s) — before launching, so a 30s record can hold.
echo "== waiting for $XCID to be STABLY online for xctrace (up to 5 min)..."
echo "   fix: unlock the phone (Auto-Lock Never) + open Xcode ▸ Window ▸"
echo "        Devices and Simulators so it mounts the developer disk image."
streak=0; ready=0
for i in $(seq 1 150); do   # ~5 min
  if xcrun xctrace list devices 2>/dev/null \
       | awk '/== Devices ==/{d=1;next} /Offline|Simulators/{d=0} d' | grep -q "$XCID"; then
    streak=$((streak+1))
    if [ "$streak" -ge 4 ]; then ready=1; echo "== STABLY online (${streak} consecutive) — launching"; break; fi
  else
    streak=0
  fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  echo "FATAL: $XCID never became STABLY online for xctrace (5 min)."
  echo "       Unlock the phone (Auto-Lock Never) AND open Xcode ▸ Window ▸ Devices"
  echo "       and Simulators to mount the developer disk image, then rerun."
  exit 1
fi
TEMPLATE="${1:-Game Performance}"
TAG="${2:-trace-run}"
DUR="${TRACE_SECONDS:-30}"
MAP="${Q3E_MAP:-q3dm7}"
OUT="$ROOT/artifacts/runs/${TAG}.trace"   # runs/ is gitignored (traces are large)
mkdir -p "$ROOT/artifacts/runs"
rm -rf "$OUT"

# 1. launch straight into a live bot match, FOREGROUND (--terminate-existing
# also backgrounds any other app so it can't steal the foreground/GPU).
echo "== launching live match ($MAP) on device"
xcrun devicectl device process launch --terminate-existing --device "$UDID" \
  --environment-variables "{\"Q3E_ARGS\":\"+set sv_pure 0 +set bot_minplayers 3 +map $MAP\",\"Q3E_CONSOLE\":\"1\"}" \
  "$BUNDLE" | tee "$ROOT/artifacts/runs/${TAG}-launch.txt"
echo "== waiting for map load + steady state"
sleep 15

# 1b. VERIFY Quake3e is actually FOREGROUND and rendering before we trace.
# A backgrounded Quake3e produces zero frames and the trace captures nothing
# (learned the hard way — once traced an idle Quake3e while q2repro held the
# foreground). A live Q3E_FT line with wall ~8.3ms proves it's rendering at
# ~120Hz, i.e. genuinely foreground and active.
echo "== verifying Quake3e is foreground + rendering..."
FT=$({ printf 'vkinfo\n'; sleep 6; } | nc "$HOST" "$PORT" 2>/dev/null | grep -a "Q3E_FT" | tail -1 || true)
echo "   ${FT:-<no FT line — app not rendering>}"
if ! echo "$FT" | grep -qE "wall p50=[789]\."; then
  echo "FATAL: Quake3e is not rendering at ~120Hz — it is not foreground/active."
  echo "       Make sure Quake3e is the frontmost app (no other app active), then rerun."
  exit 1
fi

# 2. record. Attach by process name (the executable is 'Quake3e').
echo "== recording '$TEMPLATE' for ${DUR}s -> $OUT"
xcrun xctrace record --template "$TEMPLATE" --device "$XCID" \
  --attach "Quake3e" --time-limit "${DUR}s" --output "$OUT" \
  || { echo "FATAL: xctrace record failed — is the device unlocked, awake, and on USB?"; exit 1; }

echo "TRACE OK: $OUT"
echo "   open with:  open '$OUT'"
echo "   summarize:  xcrun xctrace export --input '$OUT' --toc  (then --xpath a table)"
