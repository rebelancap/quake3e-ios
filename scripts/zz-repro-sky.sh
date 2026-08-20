#!/usr/bin/env bash
# zz-repro-sky.sh — ONE suite section (4b-xviii, the sky) in about six minutes
# instead of the full twenty-minute pass.
#
# Boots the Vision Pro simulator, enters VR, loads q3dm1, moves the player off
# the spawn the way the full suite's earlier `kill` cycles do (without that, the
# probe tests a starting position the suite never reaches), and then runs the
# sky case verbatim. Its verdict line is the section's own.
#
# It also prints a coarse shape map per frame (sim-pixel-count.py's `map`),
# because "the sky is a small lit rectangle in a black void" is a claim about
# SHAPE, and no scalar pixel count can see one.
#
# Usage: scripts/zz-repro-sky.sh [--udid UDID] [--keep-booted]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

UDID=${Q3E_VR_UDID:-}
KEEP=0
while [ $# -gt 0 ]; do case "$1" in
  --udid) UDID=$2; shift 2 ;;
  --keep-booted) KEEP=1; shift ;;
  *) echo "FATAL: unknown arg $1" >&2; exit 2 ;;
esac; done

BUNDLE=com.rebelancap.quake3e
PORT=27999
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/Quake3e.app"
ARTS="$ROOT/artifacts/vr-r21"
PFX="$ARTS/$(date '+%Y-%m-%d-%H%M%S')-sky"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-visionos-sim.sh" >&2; exit 1; }
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | awk '/Apple Vision Pro \(/{print $0}' | tail -1 |
         sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
fi
[ -n "$UDID" ] || { echo "FATAL: no Apple Vision Pro simulator found (never create one — ask)" >&2; exit 1; }

INTERRUPTED=0
# R2.2 fix 8: lane discipline cuts BOTH ways. The teardown below terminates the
# app and shuts the device down — correct for a device THIS run booted, and a
# direct attack on another session's measurement for one it did not. The trap
# was installed before the "already booted by someone else" guard, so the abort
# path for a busy Vision Pro killed the app of the very session it was being
# polite to. Nothing is torn down until this flag says the lane is ours, which
# happens only after the guard passes and the boot succeeds.
OWN_LANE=0
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM
cleanup () {
  if [ "$OWN_LANE" = 1 ]; then
    xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
    if [ "$KEEP" = 0 ]; then
      echo "== shutting down $UDID (lane discipline: always, pass or fail)"
      xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    fi
  else
    echo "== leaving $UDID alone — this run never took the lane"
  fi
  [ "$INTERRUPTED" != 0 ] && echo "*** INTERRUPTED — this run proves nothing" >&2
  return 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; exit 1; }

mkdir -p "$ARTS"

state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
if [ "$state" = "Booted" ]; then
  echo "== $UDID is already booted — waiting for the other session to finish"
  for _i in $(seq 1 60); do
    sleep 5
    state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
    [ "$state" = "Booted" ] || break
  done
  [ "$state" = "Booted" ] && die "the Apple Vision Pro simulator is booted by another session (never create a second one — wait, or ask)"
fi
nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && die "port $PORT is already answering — another app owns the console bridge"

for _i in $(seq 1 60); do
  state=$(xcrun simctl list devices | grep "$UDID" |
          sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
  case "$state" in Shutdown|Booted) break ;; esac
  sleep 2
done
echo "== booting $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
OWN_LANE=1          # from here the device is this run's to tear down
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
echo "== install"
xcrun simctl install "$UDID" "$APP" || die "install failed"

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
BB="$DOCS/blackbox.log"
mkdir -p "$DOCS/baseq3"
for p in pak0 pak1 pak2 pak3 pak4 pak5 pak6 pak7 pak8; do
  [ -f "$DOCS/baseq3/$p.pk3" ] || cp "$ROOT/gamedata/baseq3/$p.pk3" "$DOCS/baseq3/" || die "missing gamedata pak $p"
done
[ -f "$DOCS/baseq3/q3key" ] || cp "$ROOT/gamedata/baseq3/q3key" "$DOCS/baseq3/"
cat > "$DOCS/baseq3/autoexec.cfg" <<'CFG'
seta com_maxfps 120
seta cg_drawfps 0
seta r_ext_multisample 0
seta r_renderScale 0
seta r_renderWidth 800
seta r_renderHeight 600
CFG
c=$(grep -c '^seta ' "$DOCS/baseq3/autoexec.cfg")
[ "$c" = 6 ] || die "autoexec.cfg write asserted 6 seta lines, found $c"

echo "== launch"
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "launch failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the console bridge never opened on $PORT"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null 2>&1; }
ask () { { printf '%s\n' "$1"; sleep 3; } | nc 127.0.0.1 $PORT 2>/dev/null; }
shot () {
  for _t in 1 2 3 4 5 6; do
    xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 && return 0
    sleep 4
  done
  die "screenshot '$1' never landed"
}
grid () { python3 "$ROOT/scripts/sim-pixel-count.py" "$PFX-$1.png" map "${2:-40}" "${3:-18}"; }
lastline () { grep -E "\] $1 " "$BB" 2>/dev/null | tail -1; }

sleep 8
echo "== enter VR"
say 'q3evr 1'; sleep 8
echo "== map q3dm1"
say 'map q3dm1'; sleep 25
say 'q3evrpose 0 0 0 1.60 0'; sleep 3

# Emulate what the full suite has done to the player by the time it reaches
# this case: 4b-xvi's kill cycles land him at a random respawn, indoors as
# often as not. Without this the probe tests a spawn the suite never sees.
echo "== moving the player off the spawn (kill x3), as the suite does"
for _k in 1 2 3; do say 'kill'; sleep 6; done

FAILED=0
pixels () { # pixels <label> <png> <predicate> [extra args…]
  local label=$1 png=$2; shift 2
  if python3 "$ROOT/scripts/sim-pixel-count.py" "$png" "$@"; then
    printf '   PASS  %s\n' "$label"
  else
    printf '   FAIL  %s\n' "$label" >&2; FAILED=1
  fi
}

# --- 4b-xviii. under a wide per-eye frustum the sky reaches the corner ------
# A device round reported open sky rendering as a small lit rectangle floating
# in black. The claim under test is the one a simulator CAN settle: with the
# per-eye frustum widened well past the game's own FOV, does the sky still
# cover the frame all the way into its CORNER — the part of the picture only
# the wide frustum reveals — or does coverage stop at some narrower box?
#
# The trap this case fell into for a whole round, and the way out of it:
# `q3evrpose`'s yaw is relative to the base captured at VR entry, and
# `cl_vr_body_yaw` drifts with every respawn's server-forced view snap
# (4b-xvi's `kill` runs before this point), so no fixed yaw stays pointed
# anywhere in particular; worse, the player's POSITION is a random spawn and
# many of q3dm1's spawns are indoors under a solid ceiling, where every
# direction is geometry and the corner measures a wall no matter how the sky
# renders. That is a red that says nothing about the renderer.
#
# So the direction is CHOSEN by measurement, and the measurement is the one
# thing a broken sky cannot fake: the corner's share of the SKY HOLE — sky
# pixels plus BLACK pixels. Sky drawn correctly fills the hole with sky; sky
# drawn short leaves the same hole black; a wall fills it with neither. Pick
# the yaw whose corner has the most hole, require that there IS a hole to
# look through (or the run has not tested anything and says so), and only
# then ask the real question: is the hole filled with sky?
echo "== 4b-xviii. under a wide per-eye frustum the sky reaches the frame corner"
CORNER_ARGS="--regionpct 0,0,10,15"
say 'q3evrtan -1.7 1.7 -1.7 1.7'; sleep 2      # a wide symmetric frustum, corners included
# A FRESH MAP LOAD, purely to put the player back at the spawn this suite
# started from. Section 4b-xvi's `kill` cycles have moved him to a random
# respawn by now and many of q3dm1's are indoors — the courtyard spawn a map
# load lands on has open sky in every run measured. `setviewpos` would be more
# direct and was tried first: it is a CHEAT command, a plain `map` leaves
# sv_cheats 0 (measured: "Cheats are not enabled on this server"), and turning
# cheats on for the whole run to place one camera is a worse trade than 25
# seconds. If the spawn ever changes, the hole gate below fails the run and
# says which half is wrong.
say 'map q3dm1'; sleep 25
corner_count () { # corner_count <png> <predicate>
  python3 scripts/sim-pixel-count.py "$1" "$2" $CORNER_ARGS 2>&1 |
    grep -Eo "$2 pixels=[0-9]+" | grep -Eo '[0-9]+'
}
BEST_YAW=""; BEST_HOLE=-1
for yaw in 0 45 90 135 180 225 270 315; do
  say "q3evrpose $yaw 35 0 1.60 0"; sleep 3
  shot "05h-sky-yaw$yaw"
  S=$(corner_count "$PFX-05h-sky-yaw$yaw.png" sky)
  B=$(corner_count "$PFX-05h-sky-yaw$yaw.png" black)
  H=$(( ${S:-0} + ${B:-0} ))
  echo "   yaw=$yaw: corner sky=${S:-0}px black=${B:-0}px hole=${H}px"
  if [ "$H" -gt "$BEST_HOLE" ]; then
    BEST_HOLE=$H; BEST_YAW=$yaw
    cp "$PFX-05h-sky-yaw$yaw.png" "$PFX-05h-sky-wide.png"
  fi
done
echo "   best direction: yaw=$BEST_YAW (${BEST_HOLE}px of sky hole in the corner)"
# 5000 of the corner's 31104 sampled pixels is a sixth of the cell — far more
# than the scattered dark pixels a shadowed wall contributes (measured: an
# indoor spawn's corner holds a few hundred), far less than an open sky's own
# share (measured: 15000-31000, sky or black depending on whether it drew).
if [ "${BEST_HOLE:-0}" -ge 5000 ]; then
  printf '   PASS  the corner really is looking through a sky hole (%s px) — the check below can mean something\n' "$BEST_HOLE"
else
  printf '   FAIL  no direction put a sky hole in the corner (best %s px) — the player is boxed in,\n' "${BEST_HOLE:-0}" >&2
  printf '         so nothing below tests sky coverage — the map load above did not land him\n' >&2
  printf '         where it used to. Fix the spawn/pose, not the renderer.\n' >&2
  FAILED=1
fi
# Asserted on the SCAN's own frame, not on a fresh shot of the same pose: this
# is a live bot match, the player can be fragged and respawned mid-scan, and a
# second capture 30 seconds later is a different place. Choosing a direction by
# one frame and then judging another is how this case reported a corner full of
# sky and a corner full of wall in the same run.
pixels "the corner of a wide-frustum frame is not empty" "$PFX-05h-sky-wide.png" nonblack \
  $CORNER_ARGS --min 200
pixels "...and what fills it is SKY, not a black void" "$PFX-05h-sky-wide.png" sky \
  $CORNER_ARGS --min 100
say 'q3evrtan off'; sleep 3

grid 05h-sky-wide
echo "PFX=$PFX"
if [ "$FAILED" = 0 ]; then echo "SKY SECTION: PASSED"; else echo "SKY SECTION: *** FAILED ***"; fi
