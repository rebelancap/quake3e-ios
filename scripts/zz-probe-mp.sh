#!/usr/bin/env bash
# zz-probe-mp.sh — the R4.1 multiplayer acceptance probe, in the visionOS
# simulator, over the console bridge.
#
# Two questions the suite cannot ask, because both answers depend on the public
# internet being up and this project's suite is not allowed to:
#
#   1. does the shipped master-server configuration return live servers?
#   2. does a connection to a real one complete, produce VR world frames, and
#      advance its simulation, and does disconnecting land back on the panel?
#
# The server to join comes from `zz-probe-mp.py candidates`, which does the same
# UDP conversation from the host — the engine parses the master's reply into the
# browser's list and the browser is a QVM, so no console command here can print
# an address. Pass one explicitly with --server to reproduce a specific run.
#
# Politeness: this connects ONCE, plays for under a minute, and disconnects. Do
# not loop it against a populated server.
#
# Usage: scripts/zz-probe-mp.sh [--udid UDID] [--server ADDR] [--keep-booted]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

UDID=${Q3E_VR_UDID:-}
KEEP=0
SERVER=${Q3E_MP_SERVER:-}
while [ $# -gt 0 ]; do case "$1" in
  --udid) UDID=$2; shift 2 ;;
  --server) SERVER=$2; shift 2 ;;
  --keep-booted) KEEP=1; shift ;;
  *) echo "FATAL: unknown arg $1" >&2; exit 2 ;;
esac; done

BUNDLE=com.rebelancap.quake3e
PORT=27999
APP="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/Quake3e.app"
ARTS="$ROOT/artifacts/vr-r41"
PFX="$ARTS/$(date '+%Y-%m-%d-%H%M%S')-mp"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-visionos-sim.sh" >&2; exit 1; }
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | awk '/Apple Vision Pro \(/{print $0}' | tail -1 |
         sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
fi
[ -n "$UDID" ] || { echo "FATAL: no Apple Vision Pro simulator found (never create one — ask)" >&2; exit 1; }

FAILED=0
INTERRUPTED=0
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
  if [ "$INTERRUPTED" != 0 ]; then
    echo "*** INTERRUPTED — this run proves nothing" >&2
  elif [ "$FAILED" = 0 ]; then
    echo "*** MP PROBE PASSED"
  else
    echo "*** MP PROBE FAILED" >&2
  fi
  return 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; exit 1; }
ok ()  { printf '   PASS  %s\n' "$1"; }
bad () { printf '   FAIL  %s\n' "$1" >&2; FAILED=1; }

mkdir -p "$ARTS"

# --- the shipped ATS exception, read out of the BUILT product ----------------
# Not out of ios/Info-visionos.plist: the question is whether the exception is in
# the app the simulator runs, and a source plist that never reached the bundle
# has been a real failure mode on this project (the SpatialGamepad case).
# It is checked BEFORE the device is touched, so a packaging regression costs
# nothing to find.
echo "== 1a. the ATS exception survived into the built visionOS product"
ATS=$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' \
        "$APP/Info.plist" 2>/dev/null)
if [ "$ATS" = "true" ]; then ok "NSAllowsArbitraryLoads=true in $APP/Info.plist"
else bad "NSAllowsArbitraryLoads is '${ATS:-absent}' in the built Info.plist"; fi

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
OWN_LANE=1
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
echo "== install"
xcrun simctl install "$UDID" "$APP" || die "install failed"

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
BB="$DOCS/blackbox.log"
mkdir -p "$DOCS/baseq3"
for p in pak0 pak1 pak2 pak3 pak4 pak5 pak6 pak7 pak8; do
  [ -f "$ROOT/gamedata/baseq3/$p.pk3" ] || die "missing gamedata/baseq3/$p.pk3"
  [ -f "$DOCS/baseq3/$p.pk3" ] || cp "$ROOT/gamedata/baseq3/$p.pk3" "$DOCS/baseq3/"
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
opened=0
for _i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { opened=1; break; }; sleep 1; done
[ "$opened" = 1 ] || die "the console bridge never opened on $PORT"

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null 2>&1; }
# Hold the bridge open for <secs> and keep everything the engine prints. The
# master's replies arrive over several seconds, so a 3-second `ask` reads the
# request and none of the answers.
listen_for () { { printf '%s\n' "$2"; sleep "$1"; } | nc 127.0.0.1 $PORT 2>/dev/null | tr -d '\r'; }
shot () {
  for _t in 1 2 3 4 5 6; do
    xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1 &&
      { echo "   shot: $PFX-$1.png"; return 0; }
    sleep 4
  done
  die "screenshot '$1' never landed"
}
lastline () { grep -E "\] $1 " "$BB" 2>/dev/null | tail -1; }
netnow () { say 'q3evrnet'; sleep 2; lastline NETNOW; }
field () { printf '%s' "$1" | grep -Eo "$2=[^ ]+" | head -1 | cut -d= -f2-; }

sleep 8

# --- 1. the masters --------------------------------------------------------
echo "== 1b. the shipped master configuration"
MASTERS=$(listen_for 4 'sv_master1' ; listen_for 4 'sv_master2' ; listen_for 4 'sv_master3')
printf '%s\n' "$MASTERS" | grep -E '^"sv_master' | sed 's/^/   /'
printf '%s\n' "$MASTERS" > "$PFX-masters.log"

echo "== 1c. globalservers against every configured master"
# `globalservers 0` fans out to masters 1..N. 40 s: the ioquake3 directory
# answers in five datagrams and the last one has been seen 20 s late on a cold
# DNS cache.
GS=$(listen_for 40 'globalservers 0 68 empty full')
printf '%s\n' "$GS" > "$PFX-globalservers.log"
printf '%s\n' "$GS" | grep -E 'Requesting servers|servers parsed|Error' | sed 's/^/   /'
PARSED=$(printf '%s\n' "$GS" | grep -Ec 'servers parsed')
TOTAL=$(printf '%s\n' "$GS" | grep -Eo 'total [0-9]+\)' | tail -1 | grep -Eo '[0-9]+')
TOTAL=${TOTAL:-0}
echo "   $PARSED getserversResponse packets, $TOTAL servers in the client's list"
if [ "$PARSED" -gt 0 ] && [ "$TOTAL" -ge 50 ]; then
  ok "the browser's master query returns a live internet server list ($TOTAL servers)"
else
  bad "the master query returned $TOTAL servers across $PARSED packets"
fi

# --- 2. join a live server -------------------------------------------------
if [ -z "$SERVER" ]; then
  echo "== 2. picking a live vanilla server from the host-side probe"
  SERVER=$(python3 "$ROOT/scripts/zz-probe-mp.py" candidates 1 2>/dev/null | head -1 | cut -f1)
fi
[ -n "$SERVER" ] || die "no server to join (pass --server ADDR)"
echo "== 2. joining $SERVER in VR"

say 'q3evr 1'; sleep 10
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
BEFORE=$(netnow)
printf '   before: %s\n' "$BEFORE"
[ -n "$BEFORE" ] || die "NETNOW never appeared in the black box — is this build current?"
case "$(field "$BEFORE" state)" in
  disconnected*) ok "starts disconnected" ;;
  *) bad "expected to start disconnected, NETNOW says $(field "$BEFORE" state)" ;;
esac

CONNECT=$(listen_for 30 "connect $SERVER")
printf '%s\n' "$CONNECT" > "$PFX-connect.log"
printf '%s\n' "$CONNECT" | grep -Ei 'connect|challenge|awaiting|download|error|refused' |
  tail -12 | sed 's/^/   /'

ACTIVE=0
for _i in $(seq 1 20); do
  N=$(netnow)
  S=$(field "$N" state)
  echo "   $_i: $N"
  case "$S" in active*) ACTIVE=1; break ;; esac
  sleep 4
done
if [ "$ACTIVE" = 1 ]; then ok "the connection reached CA_ACTIVE"; else bad "never reached CA_ACTIVE"; fi
N1=$(netnow)
printf '%s\n' "$N1" > "$PFX-netnow-active.log"

# Downloads: recorded either way. The simulator build has NO libcurl (see
# build-visionos-sim.sh), so an HTTP redirect can only be OBSERVED here, never
# followed — the device build is the one that carries curl.
DL=$(field "$N1" dl)
DLURL=$(field "$N1" dlurl)
echo "   download state: dl=$DL dlurl=$DLURL allowdl=$(field "$N1" allowdl)"

echo "== 2b. the world renders per-eye, and the simulation advances"
say 'q3evrzones'; sleep 3
MODE=$(lastline MODENOW); EYE=$(lastline EYENOW)
printf '   %s\n' "$(printf '%s' "$MODE" | cut -c1-200)"
printf '   %s\n' "$(printf '%s' "$EYE" | cut -c1-200)"
if printf '%s' "$MODE" | grep -q 'mode=VR .*present=world'; then ok "present=world in VR on a live server"
else bad "the connected VR frame did not present the world"; fi
# NOT `views=2`: the simulator's drawable is single-view (the device's is not),
# so the per-eye claim has to be read off the number of eye PAIRS the renderer
# actually produced, which counts both eyes on either drawable.
PAIRS=$(printf '%s' "$EYE" | grep -Eo 'pairs=[0-9]+' | cut -d= -f2)
if printf '%s' "$EYE" | grep -q 'vr=on' && [ "${PAIRS:-0}" -gt 0 ]; then
  ok "the engine's VR path is armed and has rendered $PAIRS eye pairs"
else
  bad "EYENOW does not report an armed VR path with eye pairs (pairs=${PAIRS:-none})"
fi
shot 01-connected-world

SNAP1=$(field "$N1" snapnum); TIME1=$(field "$N1" snaptime)
echo "== 2c. a minute of play: input, then the snapshot counter again"
# The simulator has no controllers, so the play input is the head-aim path plus
# ordinary movement commands — the same chain a gamepad drives.
for _p in 1 2 3; do
  say 'q3evrpose 0 25 0 1.60 0'; sleep 3
  say '+forward'; sleep 2; say '-forward'
  say 'q3evrpose 0 -25 0 1.60 0'; sleep 3
  say '+moveright'; sleep 2; say '-moveright'
done
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
N2=$(netnow)
printf '%s\n' "$N2" > "$PFX-netnow-played.log"
SNAP2=$(field "$N2" snapnum); TIME2=$(field "$N2" snaptime)
echo "   snapnum $SNAP1 -> $SNAP2, servertime $TIME1 -> $TIME2"
if [ "${SNAP2:-0}" -gt "${SNAP1:-0}" ] 2>/dev/null; then
  ok "snapshots advanced ($SNAP1 -> $SNAP2)"
else
  bad "the snapshot counter did not advance ($SNAP1 -> $SNAP2)"
fi
if [ "${TIME2%ms}" -gt "${TIME1%ms}" ] 2>/dev/null; then
  ok "server time advanced (${TIME1} -> ${TIME2})"
else
  bad "server time did not advance (${TIME1} -> ${TIME2})"
fi
shot 02-after-play
say 'q3evrdiag'; sleep 2
[ -f "$BB" ] && cp "$BB" "$PFX-bb-connected.log"

echo "== 2d. clean disconnect, back to the panel"
say 'disconnect'; sleep 8
N3=$(netnow)
printf '   after: %s\n' "$N3"
printf '%s\n' "$N3" > "$PFX-netnow-disconnected.log"
case "$(field "$N3" state)" in
  disconnected*) ok "disconnect returns to CA_DISCONNECTED" ;;
  *) bad "after disconnect NETNOW says $(field "$N3" state)" ;;
esac
say 'q3evrzones'; sleep 3
MODE3=$(lastline MODENOW)
printf '   %s\n' "$(printf '%s' "$MODE3" | cut -c1-200)"
if printf '%s' "$MODE3" | grep -q 'mode=VR .*present=panel'; then ok "back on the panel, still in VR"
else bad "after disconnect the VR present mode is not the panel"; fi
shot 03-disconnected-panel
say 'q3evrdiag'; sleep 2
[ -f "$BB" ] && cp "$BB" "$PFX-bb-final.log"

echo "== artifacts: $PFX-*"
[ "$FAILED" = 0 ] || exit 1
exit 0
