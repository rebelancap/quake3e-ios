#!/usr/bin/env bash
# sim-verify-keyboard.sh — the visionOS simulator acceptance suite for KEYBOARD
# input (R4.9). Separate from sim-verify-vr.sh because it shares none of that
# script's subject matter and all of its discipline: lane guard, a verdict that
# survives a signal, assertions that have been watched fail, teardown on every
# exit path.
#
# What it proves:
#   * a key event routed through the shell's own press handler reaches the
#     engine and changes engine state (the console opens);
#   * characters routed through -insertText: — the entry point UIKit uses for
#     BOTH a hardware keystroke and a tap on the virtual keyboard — land in the
#     engine's own text fields, read back from the cvar the field writes;
#   * the shell raises the system keyboard exactly when the engine wants text
#     (console, chat, focused menu field) and drops it again when it does not;
#   * the same holds with the immersive space open, which is the platform
#     gotcha: the 2D window is parked behind a curtain there.
#
# What it can NEVER prove, and what therefore stays on the human checklist: that
# the visionOS virtual keyboard is legible/reachable in the headset, and that a
# real Mac Virtual Display keyboard pairs at all. A headless simulator delivers
# neither a keystroke nor a keyboard tap to the guest — which is why the two
# injectors (q3ekbdtype / q3ekbdkey) enter the shell at exactly the points UIKit
# would, and why case K0 below forces them to fail before any of them is
# believed.
#
# Usage: scripts/sim-verify-keyboard.sh [--udid UDID] [--keep-booted]
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
ARTS="$ROOT/artifacts/vr-r49"
PFX="$ARTS/$(date '+%Y-%m-%d-%H%M%S')-kbd"

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
  local rc=$?
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
    echo "SIM KEYBOARD VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
    exit 143
  fi
  if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
    echo "SIM KEYBOARD VERIFY: *** FAILED *** (script status $rc, assertion-failure flag ${FAILED:-0})" >&2
    exit 1
  fi
  echo "SIM KEYBOARD VERIFY: PASSED"
  exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }

mkdir -p "$ARTS"

# --- lane discipline --------------------------------------------------------
booted_now () { xcrun simctl list devices | grep "$UDID" | grep -q "(Booted)"; }
if booted_now; then
  echo "== $UDID is already booted — waiting for the other session's lane to free"
  for _i in $(seq 1 60); do booted_now || break; sleep 5; done
  booted_now && die "the Apple Vision Pro simulator is still booted by another session — never create a second one, wait or ask"
fi

for _i in $(seq 1 60); do
  state=$(xcrun simctl list devices | grep "$UDID" |
          sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
  case "$state" in Shutdown|Booted) break ;; esac
  echo "   waiting for $UDID to settle (currently: ${state:-unknown})"
  sleep 2
done
echo "== booting $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null || die "the device never booted"
OWN_LANE=1
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1

echo "== install"
xcrun simctl install "$UDID" "$APP" || die "install failed"

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
mkdir -p "$DOCS/baseq3"

echo "== game data"
for p in pak0 pak1 pak2 pak3 pak4 pak5 pak6 pak7 pak8; do
  [ -f "$ROOT/gamedata/baseq3/$p.pk3" ] || die "missing gamedata/baseq3/$p.pk3"
  [ -f "$DOCS/baseq3/$p.pk3" ] || cp "$ROOT/gamedata/baseq3/$p.pk3" "$DOCS/baseq3/"
done
[ -f "$DOCS/baseq3/q3key" ] || cp "$ROOT/gamedata/baseq3/q3key" "$DOCS/baseq3/"
n=$(ls "$DOCS/baseq3"/pak*.pk3 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 9 ] || die "expected 9 paks in the container, found $n"

# The name this suite starts from. Asserted after writing, because a silent
# no-op file edit is how three regressions shipped in one day on a sibling port.
cat > "$DOCS/baseq3/autoexec.cfg" <<'CFG'
seta com_maxfps 120
seta cg_drawfps 0
seta name KbdBaseline
CFG
c=$(grep -c '^seta ' "$DOCS/baseq3/autoexec.cfg")
[ "$c" = 3 ] || die "autoexec.cfg write asserted 3 seta lines, found $c"

echo "== launch"
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "launch failed"

echo "== waiting for the console bridge"
ok=0
for i in $(seq 1 60); do
  nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || die "the console bridge never opened on $PORT"

# --- helpers ----------------------------------------------------------------
say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null 2>&1; }
alive () { nc -z -G 2 127.0.0.1 $PORT >/dev/null 2>&1; }
ask () { { printf '%s\n' "$1"; sleep 3; } | nc 127.0.0.1 $PORT 2>/dev/null; }

shot () {
  for _t in 1 2 3 4 5 6; do
    if xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1; then
      echo "   shot: $PFX-$1.png"; return 0
    fi
    sleep 4
  done
  alive || die "screenshot '$1' never landed AND the app is not answering the bridge — it has crashed"
  die "screenshot '$1' never landed (app alive — screen surfaces unavailable)"
}

# THE dump, with freshness built in: seq is monotone and written by the shell,
# so a reply that repeats the previous seq is a wedged app, not a state.
KBD_LINE=""
KBD_SEQ=-1
kbd_read () { # kbd_read <label>
  local out seq
  out=$(ask 'q3ekbdnow' | grep -E '^KBDNOW ' | tail -1)
  [ -n "$out" ] || {
    alive || die "the app stopped answering the bridge during '$1' — it has crashed"
    die "no KBDNOW line came back during '$1' — the command surface is gone"
  }
  seq=$(printf '%s' "$out" | grep -Eo 'seq=[0-9]+' | cut -d= -f2)
  KBD_LINE=$out
  KBD_SEQ=${seq:-0}
  printf '   KBDNOW: %s\n' "$out"
}

kbd_assert () { # kbd_assert <label> <extended-regex>
  kbd_read "$1"
  if printf '%s' "$KBD_LINE" | grep -Eq "$2"; then printf '   PASS  %s\n' "$1"
  else printf '   FAIL  %s  (no /%s/ in the KBDNOW line)\n' "$1" "$2" >&2; FAILED=1; fi
  return 0
}

cvar_is () { # cvar_is <label> <cvar> <extended-regex over the printed value>
  local out
  out=$(ask "$2" | tail -3)
  if printf '%s' "$out" | grep -Eq "$3"; then printf '   PASS  %s (%s)\n' "$1" "$(printf '%s' "$out" | tr '\n' ' ')"
  else printf '   FAIL  %s: %s did not match /%s/ — got: %s\n' "$1" "$2" "$3" "$(printf '%s' "$out" | tr '\n' ' ')" >&2; FAILED=1; fi
  return 0
}

# One tap of a key, the way a keyboard sends it.
tap () { say "q3ekbdkey $1"; sleep 1; }

sleep 10
shot 00-2d-title

# --- K0. the instrument can go RED ------------------------------------------
# Forced off drops first responder, which is exactly the vacuous case this whole
# suite would otherwise be: if the responder never activates, no key and no
# character can arrive, and every green case below would be meaningless. Prove
# the refusal happens BEFORE trusting any of them.
echo "== K0. fault injection: the responder is dropped, so nothing can be typed"
say 'q3ekbd off'; sleep 2
kbd_assert "K0 responder down and text mode off under forced-off" 'resp=0 text=0 mode=off'
say 'q3ekbdtype ThisMustNotLand'; sleep 2
cvar_is "K0 the name cvar is untouched while the responder is down" 'name' 'KbdBaseline'
kbd_assert "K0 no character was counted" 'chars=0'

# --- K1. the resting state: responder up, keyboard down ----------------------
echo "== K1. auto mode at the main menu: first responder, but NO keyboard"
say 'q3ekbd auto'; sleep 2
kbd_assert "K1 the view holds first responder in auto mode" 'resp=1'
kbd_assert "K1 no keyboard while nothing wants text" 'text=0 mode=auto'
kbd_assert "K1 a menu is up (so this is not just 'no menu')" 'catcher=0x2'

# --- K2. a KEY EVENT changes engine state ------------------------------------
# The ` key is K_CONSOLE. Routing it through the press handler and watching the
# key catcher move to the console is the end-to-end proof for SE_KEY: nothing
# else in this app can open the console.
echo "== K2. a hardware key opens the console"
# The catcher is a MASK and Con_ToggleConsole_f XORs only the console bit into
# it, so with the main menu up the answer is 0x3 (UI|CONSOLE), never a bare 0x1
# — asserting equality here was this suite's own bug, written unrun.
tap CONSOLE
kbd_assert "K2 the console catcher is set by the injected key" 'catcher=0x[13]'
kbd_assert "K2 the keyboard came up on its own for the console" 'text=1'
shot 01-console-open

# --- K3. CHARACTERS land in the engine's own text field ----------------------
# The console line IS an engine text field (Field_CharEvent). Typing a command
# into it and pressing ENTER is a readback nobody can fake: the cvar changes.
echo "== K3. typed characters reach the console field"
say 'q3ekbdtype name SimKbdConsole'; sleep 2
kbd_assert "K3 the characters were counted" 'chars=1[0-9]'
tap ENTER
sleep 2
cvar_is "K3 the console executed what was TYPED into it" 'name' 'SimKbdConsole'
shot 02-console-typed

# Backspace is a CHARACTER to this engine, not a key — Field_KeyDownEvent has no
# K_BACKSPACE case at all. Typing a name with three characters too many and
# deleting them back is the case that would have caught R4.9's shipped bug.
echo "== K3a. backspace actually deletes"
say 'q3ekbdtype name SimKbdBackXXX'; sleep 2
tap BACKSPACE; tap BACKSPACE; tap BACKSPACE
tap ENTER
sleep 2
cvar_is "K3a the three deleted characters are gone" 'name' 'SimKbdBack[^X]'

echo "== K3b. the keyboard goes away when the console does"
tap CONSOLE
kbd_assert "K3b the console catcher is gone" 'catcher=0x2'
sleep 1
kbd_assert "K3b the keyboard went down with it" 'text=0'

# --- K4. THE ACCEPTANCE CASE: the player-name field --------------------------
# the maintainer's stand-in, and the one Urban Terror's auth field inherits. q3_ui's
# main menu -> SETUP -> PLAYER lands with the name field focused, which is the
# only thing that makes the UI ask for the overstrike mode (patch 0024).
echo "== K4. the player-name field raises the keyboard by itself"
tap DOWNARROW; tap DOWNARROW      # SINGLE PLAYER -> MULTIPLAYER -> SETUP
tap ENTER                          # SETUP
sleep 2
shot 03-setup-menu
tap ENTER                          # PLAYER
sleep 2
# PLAYER SETTINGS opens with the menu cursor ABOVE the name field, not on it —
# measured, 2026-08-20: the focus hint fires once as the screen builds and then
# goes stale, and one DOWNARROW is what actually lands on the field (uihint
# drops to ~17ms and stays there). The suite assumed the field was focused on
# entry, which is why K4 failed the first time it was ever run.
tap DOWNARROW
sleep 2
shot 04-player-settings
kbd_assert "K4 a focused menu field is visible to the engine" 'text=1'
kbd_assert "K4 the catcher still says UI, so this is the FIELD not the console" 'catcher=0x2'
kbd_assert "K4 the focus hint is fresh" 'uihint=[0-9]{1,3}ms'

echo "== K4b. typing into the field, read back from the cvar it writes"
say 'q3ekbdtype SimKbdField'; sleep 2
shot 05-name-typed
tap ESCAPE                         # q3_ui writes name on leaving the screen
sleep 2
cvar_is "K4b the player name is what was typed into the field" 'name' 'SimKbdField'
shot 06-back-in-setup

echo "== K4c. leaving the field puts the keyboard away"
tap ESCAPE
sleep 2
kbd_assert "K4c no field has focus any more" 'text=0'

# --- K5. the same thing with the immersive space open ------------------------
# The platform gotcha: in VR the 2D window is parked behind a curtain, and a
# responder in a parked window is the likeliest way for this whole mechanism to
# be true in 2D and false in the headset.
echo "== K5. VR: the responder survives the immersive space"
say 'q3evr 1'; sleep 10
kbd_assert "K5 first responder survived entry into VR" 'resp=1'
tap CONSOLE
kbd_assert "K5 the console still opens from the keyboard in VR" 'catcher=0x[13]'
kbd_assert "K5 the keyboard still comes up in VR" 'text=1'
say 'q3ekbdtype name SimKbdVR'; sleep 2
tap ENTER; sleep 2
cvar_is "K5 characters typed in VR reach the engine" 'name' 'SimKbdVR'
shot 07-vr-console
tap CONSOLE
say 'q3evr 0'; sleep 8
kbd_assert "K5 back in 2D with the responder intact" 'resp=1'
shot 08-back-in-2d

echo "== keyboard cases complete"
