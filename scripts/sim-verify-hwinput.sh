#!/usr/bin/env bash
# sim-verify-hwinput.sh — iOS simulator suite for HARDWARE mouse + keyboard
# input on iPad (GitHub issues #3 pointer lock, #4 mouse buttons/wheel, #5 the
# player-name field ignoring a hardware keyboard).
#
# A simulator has no hardware mouse and delivers no hardware keystroke to a
# headless guest. So this suite drives the two injectors that enter the shell at
# exactly the points the real devices do:
#   * q3e_fakemouse — the internal entry points the GCMouse handlers call
#     (button edges tagged with a device, motion, scroll, device add/remove) and
#     the indirect-pointer touch filter + tap path;
#   * q3ekbdhw — the press router (q3e_hwkey) with the UIKey fields a keyboard
#     carries, optionally ALSO through -insertText: to model UIKit delivering
#     the same keystroke twice.
# Every assertion below is first watched FAIL under a q3e_hwfault that removes
# the protection it guards, then watched pass with the fault cleared.
#
# What it can NEVER prove (stays on the device checklist): that iPadOS grants
# pointer lock, what a real GCMouse reports (object splitting, scroll values),
# and whether UIKit calls -insertText: for a hardware key on a real iPad.
#
# Usage: scripts/sim-verify-hwinput.sh [--device NAME] [--keep-booted] [--explore]
#   --explore: boot, install, launch, and stop (lane left booted for manual
#              poking via `nc 127.0.0.1 27999`; shut it down yourself).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

DEVNAME="iPhone Air"
KEEP=0
EXPLORE=0
while [ $# -gt 0 ]; do case "$1" in
  --device) DEVNAME=$2; shift 2 ;;
  --keep-booted) KEEP=1; shift ;;
  --explore) EXPLORE=1; KEEP=1; shift ;;
  *) echo "FATAL: unknown arg $1" >&2; exit 2 ;;
esac; done

BUNDLE=com.rebelancap.quake3e
PORT=27999
APP="$ROOT/build/ios-sim/xcode/Release-iphonesimulator/Quake3e.app"
ARTS="$ROOT/artifacts/issue-3-5"
TAG=$(echo "$DEVNAME" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')
PFX="$ARTS/$(date '+%Y-%m-%d-%H%M%S')-$TAG"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-ios-sim.sh" >&2; exit 1; }
UDID=$(xcrun simctl list devices available | awk -v n="    $DEVNAME (" '/^-- /{rt=$0} index($0,n)==1 && rt ~ /iOS 27\.0/ {print}' | head -1 |
       sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "FATAL: no '$DEVNAME' simulator on iOS 27.0 (never create one — ask)" >&2; exit 1; }

FAILED=0
INTERRUPTED=0
OWN_LANE=0
on_signal () { INTERRUPTED=1; exit 143; }
trap on_signal INT TERM

cleanup () {
  local rc=$?
  if [ "$OWN_LANE" = 1 ]; then
    if [ "$KEEP" = 0 ]; then
      xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
      echo "== shutting down $DEVNAME (lane discipline: always, pass or fail)"
      xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    else
      echo "== LEAVING $DEVNAME BOOTED (--keep-booted/--explore): xcrun simctl shutdown $UDID"
    fi
  else
    echo "== leaving $DEVNAME alone — this run never took the lane"
  fi
  if [ "$INTERRUPTED" != 0 ]; then
    echo "SIM HWINPUT VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
    exit 143
  fi
  if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
    echo "SIM HWINPUT VERIFY: *** FAILED *** (script status $rc, assertion-failure flag ${FAILED:-0})" >&2
    exit 1
  fi
  [ "$EXPLORE" = 1 ] && { echo "SIM HWINPUT: explore session up (no verdict)"; exit 0; }
  echo "SIM HWINPUT VERIFY: PASSED ($PASSES assertions, $FAULTS fault-injected reds seen)"
  exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }

mkdir -p "$ARTS"

# --- lane discipline --------------------------------------------------------
booted_now () { xcrun simctl list devices | grep "$UDID" | grep -q "(Booted)"; }
if booted_now; then
  die "$DEVNAME is already booted — another session holds this lane (never create a device; pick another lane or ask)"
fi
echo "== booting $DEVNAME ($UDID)"
xcrun simctl bootstatus "$UDID" -b >/dev/null || die "the device never booted"
OWN_LANE=1

echo "== install"
xcrun simctl install "$UDID" "$APP" || die "install failed"
CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
mkdir -p "$DOCS/baseq3"
for p in pak0 pak1 pak2 pak3 pak4 pak5 pak6 pak7 pak8; do
  [ -f "$ROOT/gamedata/baseq3/$p.pk3" ] || die "missing gamedata/baseq3/$p.pk3"
  [ -f "$DOCS/baseq3/$p.pk3" ] || cp "$ROOT/gamedata/baseq3/$p.pk3" "$DOCS/baseq3/"
done
[ -f "$DOCS/baseq3/q3key" ] || cp "$ROOT/gamedata/baseq3/q3key" "$DOCS/baseq3/"
n=$(ls "$DOCS/baseq3"/pak*.pk3 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 9 ] || die "expected 9 paks in the container, found $n"
# A fresh config every run: binds under test must not leak in from a previous one.
rm -f "$DOCS/baseq3/q3config.cfg"
cat > "$DOCS/baseq3/autoexec.cfg" <<'CFG'
seta com_maxfps 120
seta cg_drawfps 0
seta name HwBase
seta s_volume 0
seta s_musicvolume 0
CFG
c=$(grep -c '^seta ' "$DOCS/baseq3/autoexec.cfg")
[ "$c" = 5 ] || die "autoexec.cfg write asserted 5 seta lines, found $c"

echo "== launch (silent: s_volume 0 / s_musicvolume 0)"
LOG="$PFX-app.log"
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
SIMCTL_CHILD_Q3E_IGNORE_PAD=1 \
SIMCTL_CHILD_Q3E_ARGS="+set s_volume 0 +set s_musicvolume 0" \
  xcrun simctl launch --console-pty --terminate-running-process "$UDID" $BUNDLE > "$LOG" 2>&1 &
ok=0
for i in $(seq 1 90); do
  nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || die "the console bridge never opened on $PORT"
sleep 8

say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null 2>&1; }
alive () { nc -z -G 2 127.0.0.1 $PORT >/dev/null 2>&1; }
ask () { { printf '%s\n' "$1"; sleep "${2:-2}"; } | nc 127.0.0.1 $PORT 2>/dev/null; }

shot () {
  for _t in 1 2 3 4 5; do
    if xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1; then
      echo "   shot: $PFX-$1.png"; return 0
    fi
    sleep 3
  done
  alive || die "screenshot '$1' never landed AND the app is not answering — crashed"
  die "screenshot '$1' never landed"
}

[ "$EXPLORE" = 1 ] && { shot 00-explore; exit 0; }

# --- assertion machinery ------------------------------------------------------
PASSES=0
FAULTS=0
# chk <label> <text> <extended-regex> -> 0 when the regex matches
chk () { printf '%s' "$2" | grep -Eq "$3"; }
pass_if () { # pass_if <label> <text> <regex>
  if chk "$1" "$2" "$3"; then printf '   PASS  %s\n' "$1"; PASSES=$((PASSES+1))
  else printf '   FAIL  %s  (no /%s/ in: %s)\n' "$1" "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)" >&2; FAILED=1; fi
}
red_if () { # red_if <label> <text> <regex> : under a fault the PASS regex must NOT match
  if chk "$1" "$2" "$3"; then
    printf '   FAIL  %s — the assertion stayed green under its fault: it proves nothing (%s)\n' "$1" \
      "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)" >&2; FAILED=1
  else printf '   RED   %s (fault seen to fail the assertion — good)\n' "$1"; FAULTS=$((FAULTS+1)); fi
}
fault () { say "q3e_hwfault $1 $2"; sleep 0.5; }
mouse_now () { ask 'q3e_mouse state' 2 | grep -E '^MOUSENOW ' | tail -1; }
kbd_now () { ask 'q3ekbdnow' 2 | grep -E '^KBDNOW ' | tail -1; }
field () { printf '%s' "$1" | grep -Eo "(^| )$2=[^ ]+" | head -1 | cut -d= -f2; }
cvar () { ask "$1" 2 | grep -E "^\"$1\" is" | tail -1; }
key () { say "q3ekbdkey $1"; sleep 0.7; }
hw () { say "q3ekbdhw $1"; sleep 0.7; }

alive || die "app not answering after boot"
shot 00-title
say 'q3e_hwfault clear'

# --- H0. baseline -------------------------------------------------------------
echo "== H0. no mouse: nothing wants the lock, touch path untouched"
L=$(mouse_now); echo "   $L"
[ -n "$L" ] || die "no MOUSENOW line — the q3e_mouse command is missing"
pass_if "H0 no mouse device in the simulator" "$L" 'present=0 mice=0 fake=0'
pass_if "H0 menu route, lock not wanted" "$L" 'route=menu want=0 prefers=0'

# ============================ KEYBOARD (#5) =====================================
echo "== K1. a hardware keystroke types into the console — via the PRESS path"
key CONSOLE
K=$(kbd_now); echo "   $K"
pass_if "K1 console open (text context)" "$K" 'catcher=0x[13]'
fault nochars 1
hw "type name HwNoChars"; hw "tap ENTER"
red_if "K1 [fault nochars] name typed through presses" "$(cvar name)" '"name" is:"HwNoChars'
fault nochars 0
hw "type name HwConsole"; hw "tap ENTER"
pass_if "K1 name typed through hardware presses lands exactly" "$(cvar name)" '"name" is:"HwConsole\^7"'
K=$(kbd_now); echo "   $K"
pass_if "K1 the press path generated the characters" "$K" 'hwchars=[1-9][0-9]*'

echo "== K2. UIKit delivering the same keystroke TWICE types it once"
fault nodedupe 1
hw "both name HwBoth"; hw "tap ENTER"
red_if "K2 [fault nodedupe] press+insertText typed once" "$(cvar name)" '"name" is:"HwBoth\^7"'
fault nodedupe 0
hw "both name HwBoth"; hw "tap ENTER"
pass_if "K2 press then insertText: exactly one copy" "$(cvar name)" '"name" is:"HwBoth\^7"'
hw "textfirst name HwTextFirst"; hw "tap ENTER"
pass_if "K2 insertText then press: exactly one copy" "$(cvar name)" '"name" is:"HwTextFirst\^7"'
K=$(kbd_now); echo "   $K"
pass_if "K2 duplicates were counted as dropped" "$K" 'dedup=[1-9][0-9]*'

echo "== K3. held key repeats in the console (text context)"
fault norepeat 1
hw "type name R"; hw "down x"; sleep 1.3; hw "up x"; hw "tap ENTER"
red_if "K3 [fault norepeat] a held x repeats" "$(cvar name)" '"name" is:"Rxxxxxxxxxx+'
fault norepeat 0
hw "type name R"; hw "down x"; sleep 1.3; hw "up x"; hw "tap ENTER"
pass_if "K3 a held x repeats (>=10 x after ~1.3 s)" "$(cvar name)" '"name" is:"Rxxxxxxxxxx+'
hw "type name RXXX"; hw "tap BACKSPACE"; hw "tap ENTER"
pass_if "K3 a short BACKSPACE tap deletes exactly one" "$(cvar name)" '"name" is:"RXX\^7"'

echo "== K4. soft-keyboard (-insertText:) path and Paste still work"
say 'q3ekbdtype name SoftKbd'; sleep 1; hw "tap ENTER"
pass_if "K4 insertText: types into the console" "$(cvar name)" '"name" is:"SoftKbd\^7"'
say 'q3ekbdpaste name PasteOK'; sleep 1; hw "tap ENTER"
pass_if "K4 Paste lands" "$(cvar name)" '"name" is:"PasteOK\^7"'
key CONSOLE
shot 01-console-closed

echo "== K5. no key repeat outside text contexts (main menu, nothing focused)"
K=$(kbd_now); r0=$(field "$K" repeats); echo "   $K"
pass_if "K5 main menu is not a text context" "$K" 'catcher=0x2 .*want=0'
fault anyrepeat 1
hw "down x"; sleep 1.0; hw "up x"
K=$(kbd_now); r1=$(field "$K" repeats)
red_if "K5 [fault anyrepeat] no repeats in a plain menu" "repeats_delta=$((r1-r0))" '^repeats_delta=0$'
fault anyrepeat 0
hw "down x"; sleep 1.0; hw "up x"
K=$(kbd_now); r2=$(field "$K" repeats)
pass_if "K5 no repeats in a plain menu" "repeats_delta=$((r2-r1))" '^repeats_delta=0$'

echo "== K6. THE REPORTED CASE: hardware keys type into Player Settings > Name"
key DOWNARROW; key DOWNARROW; key ENTER; sleep 1.5      # SETUP
shot 02-setup
key ENTER; sleep 1.5                                    # PLAYER
key DOWNARROW; sleep 1.5                                # onto the name field
K=$(kbd_now); echo "   $K"
pass_if "K6 the name field has focus" "$K" 'want=1'
shot 03-player-name-focused
# Empty the field the way a player would (the field holds the current name;
# END first — the field cursor does not start at the end).
key END
for _b in 1 2 3 4 5 6 7 8 9 10 11 12; do say 'q3ekbdhw tap BACKSPACE'; sleep 0.15; done
sleep 0.5
hw "type IpadHw"
shot 04-player-name-typed
key ESCAPE; sleep 1.5                                   # q3_ui writes name on leaving
pass_if "K6 the player name is exactly what the hardware keys typed" "$(cvar name)" '"name" is:"IpadHw\^7"'
key ESCAPE; sleep 1.5                                   # back to the main menu
shot 05-main-menu

# ============================ MOUSE (#3, #4) ====================================
say 'q3e_fakemouse add 1 FakeMouse'; sleep 0.5
say 'q3e_fakemouse kbd 1'; sleep 0.5

echo "== M1. Controls menu: a RIGHT click binds MOUSE2 (was MOUSE1, issue #4)"
# The bind row is armed with a LEFT pointer click on it — the touch layer's
# warp + MOUSE1 tap, the path a real left click takes in menus — then the
# right click is the "new key". q3_ui writes binds when the menu is left.
ctl_bind_rclick () {
  key DOWNARROW; key DOWNARROW; key ENTER; sleep 1.5    # SETUP
  key DOWNARROW; key ENTER; sleep 2                     # CONTROLS (LOOK tab)
  say 'q3e_fakemouse pointerclick 0.47 0.435 1'; sleep 1.5   # "look up" row: waiting for key
  shot "$1-waiting"
  say 'q3e_fakemouse click 1 2'; sleep 1
  shot "$1-bound"
  key ESCAPE; sleep 1.5; key ESCAPE; sleep 1.5          # leave: q3_ui saves the binds
}
fault rightasleft 1
ctl_bind_rclick 06-controls-fault
red_if "M1 [fault rightasleft] MOUSE2 bound to look up" "$(ask 'bind MOUSE2' 2)" '"MOUSE2" = "\+lookup'
fault rightasleft 0
say 'bind MOUSE1 +attack'; sleep 0.5
ctl_bind_rclick 07-controls
pass_if "M1 the right button bound as MOUSE2" "$(ask 'bind MOUSE2' 2)" '"MOUSE2" = "\+lookup'
pass_if "M1 ...and MOUSE1 kept its own bind" "$(ask 'bind MOUSE1' 2)" '"MOUSE1" = "\+attack'
shot 08-main-menu-after-controls
# Hover follow: the q3 cursor tracks the system pointer in menus (visual check:
# the cursor sits top-left in the first shot, lower-right in the second).
say 'q3e_fakemouse hover 0.15 0.2 1'; sleep 1; shot 08a-hover-topleft
say 'q3e_fakemouse hover 0.5 0.5'; sleep 0.3; say 'q3e_fakemouse hover 0.85 0.8'; sleep 1; shot 08b-hover-bottomright

echo "== M2. menu: left click = exactly one MOUSE1; right click = MOUSE2, no MOUSE1"
key CONSOLE                                             # a menu route where clicks are inert
L=$(mouse_now); echo "   $L"
pass_if "M2 menu route" "$L" 'route=menu'
fault nosuppress 1
m1a=$(field "$(mouse_now)" M1)
say 'q3e_fakemouse button 1 1 1'; say 'q3e_fakemouse pointerclick 0.5 0.5 1'; say 'q3e_fakemouse button 1 1 0'; sleep 1
m1b=$(field "$(mouse_now)" M1)
red_if "M2 [fault nosuppress] one left click = one MOUSE1" "m1_delta=$((m1b-m1a))" '^m1_delta=1$'
fault nosuppress 0
say 'q3e_fakemouse button 1 1 1'; say 'q3e_fakemouse pointerclick 0.5 0.5 1'; say 'q3e_fakemouse button 1 1 0'; sleep 1
L=$(mouse_now); m1c=$(field "$L" M1); m2c=$(field "$L" M2)
pass_if "M2 one left click = one MOUSE1" "m1_delta=$((m1c-m1b))" '^m1_delta=1$'
rclick () { say 'q3e_fakemouse button 1 2 1'; say 'q3e_fakemouse pointerclick 0.5 0.5 2'; say 'q3e_fakemouse button 1 2 0'; sleep 1; }
fault nofilter 1
rclick
L=$(mouse_now); m1d=$(field "$L" M1); m2d=$(field "$L" M2)
red_if "M2 [fault nofilter] right click: MOUSE2 once, MOUSE1 never" "m1_delta=$((m1d-m1c)) m2_delta=$((m2d-m2c))" '^m1_delta=0 m2_delta=1$'
fault nofilter 0
rclick
L=$(mouse_now); m1e=$(field "$L" M1); m2e=$(field "$L" M2)
pass_if "M2 right click: MOUSE2 once, MOUSE1 never" "m1_delta=$((m1e-m1d)) m2_delta=$((m2e-m2d))" '^m1_delta=0 m2_delta=1$'

echo "== M3. menu wheel reaches the engine (console scrolls / lists / binds)"
wu0=$(field "$(mouse_now)" WU)
say 'q3e_fakemouse scroll -1'; sleep 0.6
wu1=$(field "$(mouse_now)" WU)
pass_if "M3 wheel up in a menu = one MWHEELUP" "wu_delta=$((wu1-wu0))" '^wu_delta=1$'
key CONSOLE

echo "== M4. in game"
say 'bind MWHEELUP "set probewu 1"'; say 'bind MWHEELDOWN "set probewd 1"'
say 'set probewu 0'; say 'set probewd 0'
say 'set sv_pure 0'; say 'map q3dm1'
for _i in $(seq 1 40); do
  L=$(mouse_now); chk x "$L" 'route=game' && break; sleep 1
done
echo "   $L"
pass_if "M4 in a game: game route, pointer lock WANTED and asked for" "$L" 'route=game want=1 prefers=1'
pass_if "M4 mouse + keyboard = desktop: touch controls hidden" "$L" 'desktop=1 .*hide=1'
shot 09-game-desktop
say 'q3e_fakemouse kbd 0'; sleep 1
L=$(mouse_now); echo "   $L"
pass_if "M4 mouse alone keeps the touch controls" "$L" 'desktop=0 .*hide=0'
shot 10-game-mouse-only
say 'q3e_fakemouse kbd 1'; sleep 1

echo "== M5. wheel in game triggers its binds"
fault nowheel 1
say 'q3e_fakemouse scroll -1'; sleep 1
red_if "M5 [fault nowheel] MWHEELUP bind ran" "$(cvar probewu)" '"probewu" is:"1'
fault nowheel 0
say 'q3e_fakemouse scroll -1'; sleep 1
pass_if "M5 wheel up ran the MWHEELUP bind" "$(cvar probewu)" '"probewu" is:"1'
sleep 0.4
say 'q3e_fakemouse scroll 1'; sleep 1
pass_if "M5 wheel down ran the MWHEELDOWN bind" "$(cvar probewd)" '"probewd" is:"1'

echo "== M6. mouse motion turns the view"
yaw () { ask viewpos 2 | grep -Eo '\) : -?[0-9]+' | tail -1 | grep -Eo -- '-?[0-9]+$'; }
y0=$(yaw)
fault nomove 1
say 'q3e_fakemouse move 400 0'; sleep 1
y1=$(yaw)
d=$(( y1 - y0 )); d=${d#-}
red_if "M6 [fault nomove] the yaw changed" "yaw_delta=$d" '^yaw_delta=([1-9][0-9]+)$'
fault nomove 0
say 'q3e_fakemouse move 400 0'; sleep 1
y2=$(yaw)
d=$(( y2 - y1 )); d=${d#-}
echo "   yaw $y0 -> $y1 -> $y2"
pass_if "M6 400 counts of motion turned the view >= 10 degrees" "yaw_delta=$d" '^yaw_delta=([1-9][0-9]+)$'
shot 11-game-turned

echo "== M7. pointer touches belong to the mouse layer in game"
P=$(ask 'q3e_fakemouse pointerclick 0.5 0.5 1' 1)
pass_if "M7 an in-game pointer click never reaches the touch layer" "$P" 'FAKEPOINTER ignored'

echo "== M8. a held button is released when its device disappears"
say 'q3e_fakemouse add 7 Vanishing'; sleep 0.3
fault norelease 1
say 'q3e_fakemouse button 7 2 1'; sleep 0.3
R=$(ask 'q3e_fakemouse remove 7' 1 | grep MOUSENOW | tail -1)
red_if "M8 [fault norelease] released on removal" "$R" 'eng=00'
sleep 1; say 'q3e_fakemouse add 7 Vanishing'; sleep 0.3
fault norelease 0
say 'q3e_fakemouse button 7 2 1'; sleep 0.3
L=$(mouse_now)
pass_if "M8 the button is held" "$L" 'eng=02'
R=$(ask 'q3e_fakemouse remove 7' 1 | grep MOUSENOW | tail -1)
pass_if "M8 removal released it immediately" "$R" 'eng=00'

echo "== M9. guard: a held button nobody reports pressed is released"
say 'q3e_fakemouse add 8 Stale'; sleep 0.3
fault noguard 1
say 'q3e_fakemouse button 8 3 1'; say 'q3e_fakemouse poll 8 0'; sleep 1
red_if "M9 [fault noguard] guard released it" "$(mouse_now)" 'eng=00'
fault noguard 0
sleep 1
pass_if "M9 guard released the stale button" "$(mouse_now)" 'eng=00'
H=$(ask 'q3e_mouse history' 1)
pass_if "M9 history shows the guard release" "$H" ' G b3 '
say 'q3e_fakemouse remove 8'

echo "== M10. lone release from a split mouse is recovered as one click"
lone () {
  say 'q3e_fakemouse add 11 Razer'; say 'q3e_fakemouse add 12 Razer'; sleep 0.3
  say 'q3e_fakemouse button 11 1 1'; sleep 0.2       # press on object A
  say 'q3e_fakemouse button 12 1 0'; sleep 0.2       # released on object B
  say 'q3e_fakemouse button 11 1 0'; sleep 1         # A's lone release: a swallowed click
}
a=$(field "$(mouse_now)" M1)
fault notap 1
lone
b=$(field "$(mouse_now)" M1)
red_if "M10 [fault notap] two clicks = two MOUSE1" "m1_delta=$((b-a))" '^m1_delta=2$'
fault notap 0
lone
c=$(field "$(mouse_now)" M1)
pass_if "M10 press + lone release = two MOUSE1 (one recovered)" "m1_delta=$((c-b))" '^m1_delta=2$'
pass_if "M10 nothing left held" "$(mouse_now)" 'eng=00'
H=$(ask 'q3e_mouse history' 1)
pass_if "M10 history shows the recovered click (down)" "$H" ' T b1 '
pass_if "M10 history shows the recovered click (up)" "$H" ' t b1 '
say 'q3e_fakemouse remove 11'; say 'q3e_fakemouse remove 12'

echo "== M11. no stuck button across game -> menu while held"
say 'q3e_fakemouse button 1 2 1'; sleep 0.5
pass_if "M11 held in game" "$(mouse_now)" 'eng=02'
key ESCAPE; sleep 1.5
pass_if "M11 the menu released it" "$(mouse_now)" 'route=menu .*eng=00'
say 'q3e_fakemouse button 1 2 0'; sleep 0.5
key ESCAPE; sleep 1.5

echo "== M12. the diagnostic a player pastes"
D=$(ask 'q3e_mouse' 2)
printf '%s\n' "$D" > "$PFX-q3e_mouse.txt"
pass_if "M12 q3e_mouse prints the header line" "$D" 'q3e_mouse \(iOS [0-9.]+, .*\): mice=0 fake=1 hwkeyboard=1 pointerlock=[a-zA-Z]+ prefersPointerLocked=[01]'
pass_if "M12 ...and the button history" "$D" 'history \([0-9]+ events'

echo "== M13. no mouse: in-game pointer touch goes back to the touch layer"
say 'q3e_fakemouse clear'; sleep 1
L=$(mouse_now); echo "   $L"
pass_if "M13 no mouse: lock not wanted, touch controls back" "$L" 'present=0 .*want=0 .*hide=0'
P=$(ask 'q3e_fakemouse pointerclick 0.5 0.5 1' 1)
pass_if "M13 pointer click without a mouse is a touch again" "$P" 'FAKEPOINTER game touch'
shot 12-game-touch-controls

echo "== hardware-input cases complete"
