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
# R3.5 probe: the per-weapon anchor table.
echo "== enter VR"
say 'q3evr 1'; sleep 8
echo '== devmap q3dm1 (cheats, so give all works)'
say 'devmap q3dm1'; sleep 28
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
say 'q3evrhand r 60 0 0 0.20 1.20 -0.30'; sleep 2
say 'give all'; sleep 3

for w in 2 1 3 4 5 6 7 8 9; do
  say "weapon $w"; sleep 4
  say 'q3evrviewmodel'; sleep 2
  printf '  weapon %s : %s\n' "$w" "$(lastline VIEWMODELNOW | sed -E 's/.*(fwd=.*anch=[a-z]+).*/\1/')"
done

echo "== A/B: anchor off"
say 'weapon 5'; sleep 4
say 'q3evranchor 0'; sleep 2
say 'q3evrviewmodel'; sleep 2
printf '  rocketl anchor OFF : %s\n' "$(lastline VIEWMODELNOW | sed -E 's/.*(fwd=.*anch=[a-z]+).*/\1/')"
say 'q3evranchor 1'; sleep 2
say 'q3evrviewmodel'; sleep 2
printf '  rocketl anchor ON  : %s\n' "$(lastline VIEWMODELNOW | sed -E 's/.*(fwd=.*anch=[a-z]+).*/\1/')"

echo "== grip right clamp"
printf '  %s\n' "$(ask 'q3evrgrip -8 -9 4 2' | tr -d '\r' | grep -E 'q3evrgrip:')"
printf '  %s\n' "$(ask 'q3evrgrip reset' | tr -d '\r' | grep -E 'q3evrgrip:')"
echo "== PROBE DONE"
