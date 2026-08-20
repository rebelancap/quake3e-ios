#!/usr/bin/env bash
# sim-verify-vr.sh — the visionOS simulator acceptance suite for VR mode.
#
# What a simulator CAN prove: the mode machine, the present-mode arbitration and
# its reason codes, that per-eye world frames are produced and that their PIXELS
# respond to an injected pose, that the depth snapshots exist, that entry/exit is
# clean and repeatable, and that the app survives being killed mid-VR.
#
# What it can NEVER prove, and what therefore goes on the human checklist:
# stereo fusion, world lock under real head motion, comfort, the real refresh
# rate, controller enumeration and chirality, the Digital Crown, and whether any
# of it feels right.
#
# Usage: scripts/sim-verify-vr.sh [--udid UDID] [--keep-booted]
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
ARTS="$ROOT/artifacts/vr-sim"
PFX="$ARTS/$(date '+%Y-%m-%d-%H%M%S')-vr"

[ -d "$APP" ] || { echo "FATAL: sim app missing — run scripts/build-visionos-sim.sh" >&2; exit 1; }
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | awk '/Apple Vision Pro \(/{print $0}' | tail -1 |
         sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
fi
[ -n "$UDID" ] || { echo "FATAL: no Apple Vision Pro simulator found (never create one — ask)" >&2; exit 1; }

# --- the verdict ------------------------------------------------------------
# Declared BEFORE the trap: `set -u` plus an early death would otherwise make the
# trap itself fail on an unbound variable, and the verdict would be lost.
FAILED=0
# The signal half. Without it the trap reads `$?` from the last COMPLETED
# command — a successful one — and prints PASSED for a run that was killed
# halfway through. A killed run has no verdict, and saying it passed is worse
# than saying nothing: every claim downstream of it is fiction.
INTERRUPTED=0
# R2.2 fix 8 (found in zz-repro-sky.sh, the same shape here): the teardown below
# terminates the app and shuts the device down, which is right for a device THIS
# run booted and an attack on another session's measurement for one it did not.
# The trap is installed before the "already booted by another session" guard —
# it has to be, or a failure between here and there leaks a device — so the
# teardown is gated on having actually taken the lane instead.
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
    echo "SIM VR VERIFY: *** INTERRUPTED *** — no verdict, this run proves nothing" >&2
    exit 143
  fi
  if [ "$rc" != 0 ] || [ "${FAILED:-0}" != 0 ]; then
    echo "SIM VR VERIFY: *** FAILED *** (script status $rc, assertion-failure flag ${FAILED:-0})" >&2
    exit 1
  fi
  echo "SIM VR VERIFY: PASSED"
  exit 0
}
trap cleanup EXIT
die () { echo "FATAL: $1" >&2; FAILED=1; exit 1; }

mkdir -p "$ARTS"

# --- lane discipline --------------------------------------------------------
# There is exactly ONE Apple Vision Pro simulator and creating another is
# forbidden, so a device that is already booted is another session's lane. Wait
# for it, and if it does not free up, FAIL — launching over it backgrounds the
# other session's app mid-test and produces failures that look like port bugs.
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
if nc -z -G 1 127.0.0.1 $PORT 2>/dev/null; then
  die "port $PORT is already answering — another app owns the console bridge"
fi

# --- device ----------------------------------------------------------------
# Wait out a SHUTTING-DOWN device before booting it. `bootstatus -b` does not: it
# boots whatever state the device is in, and booting one that is still shutting
# down wedges CoreSimulator's system services.
for _i in $(seq 1 60); do
  state=$(xcrun simctl list devices | grep "$UDID" |
          sed -E 's/.*\((Booted|Shutdown|Shutting Down|Creating|Booting)\).*/\1/')
  case "$state" in Shutdown|Booted) break ;; esac
  echo "   waiting for $UDID to settle (currently: ${state:-unknown})"
  sleep 2
done
echo "== booting $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
OWN_LANE=1          # from here the device is this run's to tear down
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1

echo "== install"
xcrun simctl install "$UDID" "$APP" || die "install failed"

# --- the app's REAL preferences store (not `simctl spawn defaults`) --------
# R2.1 discovery, made while chasing two suite failures that turned out to be
# the SAME environment quirk: `simctl spawn defaults <read|write|delete>`
# operates on the SIMULATOR's device-global preference domain for a bundle
# ID — a DIFFERENT file from the one the running APP itself reads and writes
# (its own sandboxed container's Library/Preferences/<bundle>.plist). A brand
# new key external tooling seeds is visible to the app's first read of it
# (nothing has cached it yet) — which is why seeding a stash entry this way
# works — but once the APP ITSELF has written a key, the simulator's own
# cfprefsd daemon (a real per-runtime HOST process, confirmed with `ps`, not
# a per-app one) caches that bundle's values in memory, and an external
# `simctl spawn defaults write/delete` for the SAME key afterward can report
# success via `simctl spawn defaults read` while the next app LAUNCH still
# sees whatever the app itself last wrote — the daemon's cache wins over the
# file for a key it already holds. Editing the container-scoped plist file
# directly (PlistBuddy) and then killing the runtime's cfprefsd — confirmed
# to respawn immediately — is what actually forces a fresh read and was
# verified to work where `simctl spawn defaults delete` silently did not.
q3e_prefs_plist() {
  local cont; cont=$(xcrun simctl get_app_container "$UDID" $BUNDLE data 2>/dev/null)
  [ -n "$cont" ] && printf '%s/Library/Preferences/%s.plist' "$cont" "$BUNDLE"
}
# ...AND THE OTHER ONE. R2.2, measured this round (scratch probe, both plists
# printed side by side across four launches): there are TWO files for this
# bundle, and the app READS BOTH — its own container-scoped plist above, and the
# DEVICE-GLOBAL `<device>/data/Library/Preferences/<bundle>.plist`, which is the
# file `simctl spawn defaults write` edits. That is the whole of the R2.1
# mystery this script's header describes as "unreliably invisible": an externally
# seeded key IS visible to the app (different file, still in its search list),
# but the app's own removeObjectForKey only ever writes to its CONTAINER domain,
# so a key seeded into the global one can never be removed by the app and comes
# back at EVERY launch, forever. This device had exactly that: a stash mark plus
# two values seeded by an earlier run's `simctl spawn defaults write`, silently
# "recovered" by every single launch since — cvars overwritten, config rewritten,
# for two days. Nothing writes that domain in production; it is purely a harness
# artifact, and the harness now cleans it.
q3e_prefs_global_plist() {
  local cont; cont=$(xcrun simctl get_app_container "$UDID" $BUNDLE data 2>/dev/null)
  [ -n "$cont" ] && printf '%s/Library/Preferences/%s.plist' "${cont%%/Containers/Data/Application/*}" "$BUNDLE"
}
# R2.2 fix 9: the pattern below has to name THIS device's runtime and nothing
# else. The previous one ('CoreSimulator/.*simruntime/.*cfprefsd daemon')
# claimed that in its comment and did not deliver it: it matches the cfprefsd of
# EVERY booted simulator runtime, so a sibling project testing on an iPhone
# simulator lost its app's unflushed preference writes every time this suite
# deleted a key. cfprefsd is one host process per RUNTIME (not per device), so
# the runtime is as tight as this can honestly get — and with exactly one
# visionOS device in existence, this runtime is this lane.
q3e_runtime_bundle() {   # e.g. "xrOS 27.0.simruntime" — the runtime THIS UDID runs on
  xcrun simctl list -j 2>/dev/null | python3 -c '
import json, sys, os
udid = sys.argv[1].upper()
j = json.load(sys.stdin)
ident = ""
for rt, devs in j.get("devices", {}).items():
    for d in devs:
        if d.get("udid", "").upper() == udid:
            ident = rt
for r in j.get("runtimes", []):
    if r.get("identifier") == ident and r.get("runtimeRoot"):
        p = r["runtimeRoot"]
        while p and not p.endswith(".simruntime"):
            p = os.path.dirname(p)
        if p:
            print(os.path.basename(p))
' "$UDID"
}
RUNTIME_BUNDLE=$(q3e_runtime_bundle)
[ -n "$RUNTIME_BUNDLE" ] || die "could not resolve the simulator runtime behind $UDID — refusing to signal cfprefsd blind"
CFPREFSD_PAT="$RUNTIME_BUNDLE/.*cfprefsd"
# A scoping pattern that matches NOTHING fails silently and takes several
# sections' worth of preference seeding down with it — the failure mode of
# tightening a regex — so it is asserted against the live process list once,
# here, while the device is known to be booted.
_pat_ok=0
for _i in $(seq 1 10); do
  pgrep -f "$CFPREFSD_PAT" >/dev/null 2>&1 && { _pat_ok=1; break; }
  sleep 1
done
[ "$_pat_ok" = 1 ] || die "no running cfprefsd matches /$CFPREFSD_PAT/ — the runtime-scoped pattern names nothing, and every preference seed in this run would silently not take"
echo "== preference daemon scoped to: $RUNTIME_BUNDLE"
q3e_prefs_kick_cfprefsd() {
  local n
  n=$(pgrep -f "$CFPREFSD_PAT" 2>/dev/null | wc -l | tr -d ' ')
  pkill -f "$CFPREFSD_PAT" >/dev/null 2>&1
  echo "   (kicked $n cfprefsd process(es) on $RUNTIME_BUNDLE — this runtime only)"
  sleep 1
}
# R2.2: every delete below covers BOTH domains — see q3e_prefs_global_plist.
# The app can only remove keys from its own, so anything the harness ever put in
# the other one is the harness's to take back out.
q3e_prefs_delete_keys() { # q3e_prefs_delete_keys <key> [key...]
  local p k any=0
  for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    for k in "$@"; do
      /usr/libexec/PlistBuddy -c "Delete :$k" "$p" >/dev/null 2>&1 && any=1
    done
  done
  [ "$any" = 1 ] && q3e_prefs_kick_cfprefsd
  return 0
}
# R4.2: a delete that is PROVED to have taken, for the cases whose whole meaning
# is that a key is absent. `q3e_prefs_delete_keys` above writes the plist and
# hopes; a just-terminated app still owes cfprefsd its in-memory defaults, and a
# flush that lands AFTER the delete puts the key straight back. That is not
# hypothetical — it is how 6c-iv's negative migration case read a height trim of
# 12 inches from a store it had just cleared, and the failure looks exactly like
# a migration bug. Kick first (so anything owed is settled), delete, then READ
# BACK, up to three times.
q3e_prefs_delete_keys_verified() { # q3e_prefs_delete_keys_verified <key> [key...]
  local attempt p k left
  for attempt in 1 2 3; do
    q3e_prefs_kick_cfprefsd
    q3e_prefs_delete_keys "$@"
    left=""
    for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
      [ -n "$p" ] && [ -f "$p" ] || continue
      for k in "$@"; do
        /usr/libexec/PlistBuddy -c "Print :$k" "$p" >/dev/null 2>&1 && left="$left $k"
      done
    done
    if [ -z "$left" ]; then
      printf '   deleted%s (verified absent from both domains, attempt %s)\n' "$(printf ' %s' "$@")" "$attempt"
      return 0
    fi
    sleep 2
  done
  printf '   FAIL  these preference keys survived three verified deletes:%s\n' "$left" >&2
  return 1
}
q3e_prefs_delete_vr_keys() {
  local p k keys any=0
  for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    keys=$(/usr/libexec/PlistBuddy -c "Print" "$p" 2>/dev/null |
           grep -Eo '^ *q3e_vr_[A-Za-z0-9_]+' | tr -d ' ' | sort -u)
    [ -n "$keys" ] || continue
    for k in $keys; do /usr/libexec/PlistBuddy -c "Delete :$k" "$p" >/dev/null 2>&1; done
    any=1
  done
  [ "$any" = 1 ] && q3e_prefs_kick_cfprefsd
  return 0
}
# R2.2 fix 11: the crash-safe cvar STASH keys are dotted — `q3e.vrStashActive`
# and `q3e.vrStash.<cvar>` — so the q3e_vr_[A-Za-z0-9_]+ sweep above has never
# matched one of them. Section 7b seeds exactly those keys, and a run
# interrupted between the seeding and the relaunch that consumes them left a
# LIVE stash behind: the next launch by hand would "recover" it and write the
# suite's test values into the player's own config. Cleaned at the top of every
# run and at the end of the section that seeds them.
#
# BOTH domains (see q3e_prefs_global_plist): the app can only ever clean its
# own, and a stash key in the global one outlives every launch, every reinstall
# of the suite's expectations, and every hand session. The sweep ends by
# PROVING both files are clear, because a cleanup that silently missed is how
# this went unnoticed for two days.
q3e_prefs_delete_stash_keys() {
  local p k keys left=""
  for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    # [^ ] rather than an identifier charset: section 7b deliberately seeds a
    # key whose NAME is not a legal cvar name, and a cleanup that cannot see
    # the hostile key is exactly the cleanup that leaves it behind.
    keys=$(/usr/libexec/PlistBuddy -c "Print" "$p" 2>/dev/null |
           grep -Eo '^ *q3e\.vrStash[^ ]*' | sed 's/^ *//' | sort -u)
    [ -n "$keys" ] || continue
    for k in $keys; do /usr/libexec/PlistBuddy -c "Delete :$k" "$p" >/dev/null 2>&1; done
    q3e_prefs_kick_cfprefsd
  done
  for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    keys=$(/usr/libexec/PlistBuddy -c "Print" "$p" 2>/dev/null |
           grep -Eo '^ *q3e\.vrStash[^ ]*' | sed 's/^ *//' | sort -u)
    [ -n "$keys" ] && left="$left $p:$keys"
  done
  [ -z "$left" ] || die "stash keys survived the sweep —$left"
  return 0
}

# --- seeding a preference, and PROVING it took ------------------------------
# R2.2 fix 10: section 7b used to seed its keys with `simctl spawn defaults
# write` and check nothing at all — for keys the app itself had already written
# and removed earlier in the same run, which is the exact shape this script's
# own header documents as unreliably invisible to the next launch. A seed that
# silently does not take turns a healthy build RED and sends the next session
# hunting a bug that is not there. Every seed now goes through the app's OWN
# container plist (the file its next launch actually reads, per that header),
# kicks the runtime's cfprefsd, and then READS THE VALUE BACK and dies if it is
# not what was asked for.
#
# The app must be TERMINATED before seeding: a running one rewrites its own
# preferences on the way out and would undo the seed. The read-back happens
# AFTER the cfprefsd kick, deliberately — the daemon is the thing that can
# overwrite the file from its cache, so verifying before signalling it would
# check the one moment nothing was in doubt.
# R2.3: KICK FIRST, WRITE SECOND — and retry.
#
# The old order (write, then kick) raced the daemon it was trying to defeat.
# cfprefsd holds this bundle's values in memory, and a daemon that is still
# alive when PlistBuddy edits the file can put its own snapshot back over that
# edit as it goes down. The race is invisible for every seed whose value already
# EQUALS the cached one — which is most of them — and lands on the one seed in
# this suite that lowers a stamp the app itself has just written (6d's
# `q3e_vr_mig` 2 -> 1). Both full R2.3 runs died there, at the same line, after
# 190-odd assertions had passed: a harness defect that reads exactly like a
# product regression, which is the kind this file exists to not have.
#
# Clearing the cache BEFORE writing removes the race outright: nothing holds a
# competing copy while the file is edited, and the next daemon reads what is
# there. The retry covers the remaining window — a daemon that respawns and
# re-reads while PlistBuddy is mid-write — and every attempt is reported, so a
# seed that needed three tries says so instead of looking like a clean one.
q3e_prefs_set() { # q3e_prefs_set <key> <type: string|bool|real|integer> <value>
  local key=$1 type=$2 val=$3 plist got attempt
  plist=$(q3e_prefs_plist)
  [ -n "$plist" ] || die "no preferences plist path for $BUNDLE (is the app installed?)"
  for attempt in 1 2 3 4 5; do
    q3e_prefs_kick_cfprefsd
    [ -f "$plist" ] || /usr/libexec/PlistBuddy -c "Save" "$plist" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :$key $val" "$plist" >/dev/null 2>&1 ||
      /usr/libexec/PlistBuddy -c "Add :$key $type $val" "$plist" >/dev/null 2>&1 ||
      die "could not write $key into $plist"
    sleep 1
    got=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null | tr -d '[:space:]')
    case "$type" in
      real) # PlistBuddy prints reals with its own precision; compare numerically
        if python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<1e-4 else 1)" \
             "$got" "$val" 2>/dev/null; then
          echo "   seeded $key=$val (verified in the app's own container plist, attempt $attempt)"
          return 0
        fi ;;
      *)
        if [ "$got" = "$val" ]; then
          echo "   seeded $key=$val (verified in the app's own container plist, attempt $attempt)"
          return 0
        fi ;;
    esac
    echo "   (seed of $key=$val read back as '${got:-nothing}' on attempt $attempt — retrying)"
  done
  die "seeding $key=$val did not take after 5 attempts (plist reads '${got:-nothing}')"
}
# Delete a single key by exact name, dots and all, from BOTH domains — and
# prove it is gone from both. "Absent" is an assertion here exactly as much as
# "present" is: section 7b's second half is entirely about what happens when
# the mark is NOT there, and a delete that quietly did nothing would test the
# first half twice.
q3e_prefs_delete_one() {
  local p
  for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    /usr/libexec/PlistBuddy -c "Delete :$1" "$p" >/dev/null 2>&1
  done
  q3e_prefs_kick_cfprefsd
  for p in "$(q3e_prefs_plist)" "$(q3e_prefs_global_plist)"; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    /usr/libexec/PlistBuddy -c "Print :$1" "$p" >/dev/null 2>&1 &&
      die "$1 is still present in $p after deleting it"
  done
  echo "   deleted $1 (verified absent in both preference domains)"
  return 0
}

# The height baseline and trim live in NSUserDefaults and are DESIGNED to
# outlive a session. That makes them state a previous suite run can leave behind:
# a run that ends with the trim at -0.30 m starts the next one there, and the
# height cases then assert against a value they did not set. Cleared here so each
# run begins from "never calibrated", which is also the state a new player is in.
q3e_prefs_delete_keys Q3EVRHeightBaselineMetres Q3EVRHeightTrimMetres
# R2.2 fix 11: and the dotted stash keys, which no sweep here has ever matched
# (see q3e_prefs_delete_stash_keys) — an interrupted 7b leaves a live stash the
# next launch would honour.
q3e_prefs_delete_stash_keys
# R2.1 fix 14: section 6c seeds a turn-speed sentinel to test the migration
# guard, and until this fix nothing ever cleaned it back up — every session
# AFTER that one (including a hand feel-testing session that never touches
# this script again) booted with a random turn speed in a project whose
# acceptance bar is feel parity. Every q3e_vr_* key is wiped here too,
# unconditionally, so a leftover from ANY previous run (this suite's own
# seeding, or a hand session) can never leak into the run about to start.
q3e_prefs_delete_vr_keys

CONT=$(xcrun simctl get_app_container "$UDID" $BUNDLE data)
DOCS="$CONT/Documents"
BB="$DOCS/blackbox.log"
mkdir -p "$DOCS/baseq3"

echo "== game data"
# A fresh container needs the POINT-RELEASE paks and q3key, not just pak0.
for p in pak0 pak1 pak2 pak3 pak4 pak5 pak6 pak7 pak8; do
  [ -f "$ROOT/gamedata/baseq3/$p.pk3" ] || die "missing gamedata/baseq3/$p.pk3"
  [ -f "$DOCS/baseq3/$p.pk3" ] || cp "$ROOT/gamedata/baseq3/$p.pk3" "$DOCS/baseq3/"
done
[ -f "$DOCS/baseq3/q3key" ] || cp "$ROOT/gamedata/baseq3/q3key" "$DOCS/baseq3/"
n=$(ls "$DOCS/baseq3"/pak*.pk3 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 9 ] || die "expected 9 paks in the container, found $n"

# simctl launch argv never reaches the engine, so boot-time setup goes in
# autoexec.cfg. Written, then ASSERTED: a silent no-op file edit is how three
# regressions shipped in one day on a sibling port.
# The container survives between runs, so the render-size cvars are normalised
# here: case 4f deliberately seeds them, and a leftover from a previous run (or
# from a hand session) would otherwise silently decide the extent every other
# case reads. They are latched, so they take effect from the first vid_restart.
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

echo "== waiting for the console bridge"
ok=0
for i in $(seq 1 60); do
  nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || die "the console bridge never opened on $PORT"

# --- helpers ----------------------------------------------------------------
say () { printf '%s\n' "$1" | nc -w 3 127.0.0.1 $PORT >/dev/null 2>&1; }
# Is the app still there to be asked? `say` swallows connection failures on
# purpose (the bridge closes after every command), so nothing else notices a
# dead app — and a dead app plus a grep over a log file is how a crash gets read
# as a state-machine bug.
alive () { nc -z -G 2 127.0.0.1 $PORT >/dev/null 2>&1; }
# Send a command and CAPTURE what the engine prints. `say` closes immediately,
# which is right for fire-and-forget but reads nothing back; cvar values have to
# be read back to be asserted.
ask () { { printf '%s\n' "$1"; sleep 3; } | nc 127.0.0.1 $PORT 2>/dev/null; }

# `simctl io screenshot` intermittently returns "Timeout waiting for screen
# surfaces" on a headless-booted xrOS device. Retry — but still fail loudly if
# the shot never lands, and SAY WHY: a crashed app and a busy surface look
# identical from here, and only one of them means the rest of the run is fiction.
shot () {
  for _t in 1 2 3 4 5 6; do
    if xcrun simctl io "$UDID" screenshot "$PFX-$1.png" >/dev/null 2>&1; then
      echo "   shot: $PFX-$1.png"; return 0
    fi
    sleep 4
  done
  alive || die "screenshot '$1' never landed AND the app is not answering the bridge — it has crashed (see ~/Library/Logs/DiagnosticReports/)"
  die "screenshot '$1' never landed (app alive — screen surfaces unavailable)"
}

need () { # need <file> <label> <extended-regex>
  if grep -Eq "$3" "$1" 2>/dev/null; then printf '   PASS  %s\n' "$2"
  else printf '   FAIL  %s  (no line matching /%s/)\n' "$2" "$3" >&2; FAILED=1; fi
}
count_is () { # count_is <file> <label> <regex> <expected>
  local n; n=$(grep -Ec "$3" "$1" 2>/dev/null || true)
  if [ "$n" = "$4" ]; then printf '   PASS  %s (%s)\n' "$2" "$n"
  else printf '   FAIL  %s: expected %s, got %s\n' "$2" "$4" "$n" >&2; FAILED=1; fi
}

# FRESHNESS IS PART OF EVERY ASSERTION. Not a line count: the black box rolls its
# tail and can delete half of it at once, so "the count of ^MODENOW lines grew"
# goes false with the app perfectly healthy. A monotone counter written LAST is
# the part a front-trim can never take.
nowseq () { grep -Eo 'NOWSEQ [0-9]+$' "$BB" 2>/dev/null | tail -1 | awk '{print $2+0}'; }
lastline () { grep -E "\] $1 " "$BB" 2>/dev/null | tail -1; }

# R4.4: the eye path's LIVENESS, measured rather than inferred. `pairs=` counts
# completed L+R eye sets; `vrframes=` counts rendered frames. The defect R4.4
# fixed showed up as exactly one thing — pairs frozen while vrframes climbed —
# so the two directions of that comparison are what the assertions below need,
# and they need BOTH: an "advancing" case with no "frozen" case cannot tell a
# working re-arm from a re-arm that was never required.
pairs_now () { say 'q3evreye'; sleep 2; lastline EYENOW | grep -Eo 'pairs=[0-9]+' | cut -d= -f2; }
pairs_move () { # pairs_move <advance|frozen> <label> [settle-seconds]
  local want=$1 label=$2 secs=${3:-8} a b
  a=$(pairs_now); sleep "$secs"; b=$(pairs_now)
  if [ -z "${a:-}" ] || [ -z "${b:-}" ]; then
    printf '   FAIL  %s: no pairs= could be read at all (a=%s b=%s)\n' \
           "$label" "${a:-none}" "${b:-none}" >&2; FAILED=1; return 0
  fi
  if [ "$want" = advance ]; then
    if [ "$b" -gt "$a" ] 2>/dev/null; then
      printf '   PASS  %s (pairs %s -> %s)\n' "$label" "$a" "$b"
    else
      printf '   FAIL  %s: the eye pairs did NOT advance (%s -> %s)\n' "$label" "$a" "$b" >&2
      FAILED=1
    fi
  else
    if [ "$b" = "$a" ]; then
      printf '   PASS  %s (pairs stuck at %s, as the injected fault requires)\n' "$label" "$a"
    else
      printf '   FAIL  %s: the pairs kept advancing (%s -> %s) — the fault injection did not bite, so the green case below proves nothing\n' \
             "$label" "$a" "$b" >&2
      FAILED=1
    fi
  fi
  return 0
}

# THE HARD INVARIANT: a WORLD present requires the engine's VR path to be ARMED.
# "The eye images have something in them" is not the same claim: r_stereo3d is on
# from the first moment of entry, so the engine fills those images with its
# ordinary FLAT view for the whole pre-commit window, and presenting that as the
# world is what a device round saw as a doubled, head-locked image. MODENOW and
# EYENOW are emitted by ONE q3evrzones dump, so the pair below is coherent by
# construction — a stale-pair comparison would be its own bug.
INVARIANT_CHECKS=0
invariant_violated () { # <file> — status 0 when the last dump pair violates it
  local m e
  m=$(grep -E "\] MODENOW " "$1" 2>/dev/null | tail -1)
  e=$(grep -E "\] EYENOW " "$1" 2>/dev/null | tail -1)
  [ -n "$m" ] && [ -n "$e" ] || return 1
  printf '%s' "$m" | grep -q 'present=world' || return 1
  printf '%s' "$e" | grep -q 'vr=off' || return 1
  return 0
}
invariant_check () { # <label>
  INVARIANT_CHECKS=$((INVARIANT_CHECKS + 1))
  if invariant_violated "$BB"; then
    printf '   FAIL  INVARIANT VIOLATED at "%s": present=world while vr=off\n' "$1" >&2
    printf '         %s\n' "$(lastline MODENOW)" >&2
    printf '         %s\n' "$(lastline EYENOW)" >&2
    FAILED=1
  fi
  return 0
}

zone_assert () { # zone_assert <label> <PREFIX> <extended-regex> [dump-cmd]
  local before after line cmd
  cmd=${4:-q3evrzones}
  before=$(nowseq); before=${before:-0}
  say "$cmd"; sleep 2            # ALWAYS re-measure first
  after=$(nowseq); after=${after:-0}
  if [ "$after" -le "$before" ]; then
    printf '   FAIL  %s  (NO FRESH %s — the app did not answer; every later line in the file is stale)\n' "$1" "$2" >&2
    FAILED=1
    alive || die "the app stopped answering the bridge during '$1' — it has crashed or wedged"
    die "the app is up but stopped writing dumps during '$1' — the VR loop or the diagnostics writer has wedged"
  fi
  line=$(lastline "$2")
  printf '   %s: %s\n' "$2" "$(printf '%s' "$line" | cut -c1-220)"
  if printf '%s' "$line" | grep -Eq "$3"; then printf '   PASS  %s\n' "$1"
  else printf '   FAIL  %s  (no /%s/ in the last %s line)\n' "$1" "$3" "$2" >&2; FAILED=1; fi
  # Every omnibus dump this suite reads is also checked against the invariant.
  [ "$cmd" = q3evrzones ] && invariant_check "$1"
  return 0
}

pixels () { # pixels <label> <png> <predicate> [extra args…]
  local label=$1 png=$2; shift 2
  if python3 "$ROOT/scripts/sim-pixel-count.py" "$png" "$@"; then
    printf '   PASS  %s\n' "$label"
  else
    printf '   FAIL  %s\n' "$label" >&2; FAILED=1
  fi
}

snap () { # snap <name> — flush and copy the black box
  say 'q3evrdiag'; sleep 2
  [ -f "$BB" ] || die "no blackbox.log to snapshot ($1)"
  cp "$BB" "$PFX-bb-$1.log"
  echo "   black box: $PFX-bb-$1.log"
}

sleep 8
shot 00-2d-title

# --- 0. the invariant checker can FAIL ---------------------------------------
# An assertion nobody has watched fail is a decoration. This one is cheap to
# prove: feed it a crafted pair of dump lines and require the verdict both ways
# BEFORE it is trusted for the rest of the run.
echo "== 0. the present=world => vr=on checker is proven in both directions"
SELFT=$(mktemp)
printf '[1ms t1] MODENOW mode=VR owner=vr present=world reason=0(world)\n[1ms t1] EYENOW vr=off views=2 engine=1x1px\n' > "$SELFT"
if invariant_violated "$SELFT"; then printf '   PASS  it detects a world/vr=off pair\n'
else printf '   FAIL  the invariant checker missed a world/vr=off pair\n' >&2; FAILED=1; fi
printf '[1ms t1] MODENOW mode=VR owner=vr present=world reason=0(world)\n[1ms t1] EYENOW vr=on views=2 engine=1x1px\n' > "$SELFT"
if invariant_violated "$SELFT"; then printf '   FAIL  the invariant checker fired on a legal world/vr=on pair\n' >&2; FAILED=1
else printf '   PASS  it passes a legal world/vr=on pair\n'; fi
rm -f "$SELFT"

# --- 1. the dumps answer at all, in 2D --------------------------------------
echo "== 1. dump family answers in 2D"
zone_assert "MODENOW reports 2D before anything is entered" MODENOW 'mode=2D .*owner=link'
zone_assert "EYENOW carries both the physical and the logical eye size" EYENOW \
  'phys=[0-9]+x[0-9]+px logical=[0-9]+x[0-9]+px'
zone_assert "FRAMENOW carries the rendezvous ids" FRAMENOW 'pubid=-?[0-9]+ renderedid=-?[0-9]+'
zone_assert "DEPTHNOW carries the depth-export state" DEPTHNOW 'wanted=[01] live=[01]'

# NOWSEQ must ADVANCE across assertions — proven by construction above, asserted
# again here so a regression in the counter itself cannot pass silently.
S1=$(nowseq); say 'q3evrzones'; sleep 2; S2=$(nowseq)
if [ "${S2:-0}" -gt "${S1:-0}" ]; then printf '   PASS  NOWSEQ advances (%s -> %s)\n' "$S1" "$S2"
else printf '   FAIL  NOWSEQ did not advance (%s -> %s)\n' "$S1" "$S2" >&2; FAILED=1; fi

# The pre-VR value of an ARCHIVED cvar VR overrides. It has to come back.
# Seed a DISTINCT sentinel into an ARCHIVED cvar VR overrides. An earlier run of
# this suite (before the stash existed) can have left the very value VR sets
# sitting in the config, and "0 came back as 0" proves nothing.
#
# r_ext_multisample is checked too, but the OTHER way round: VR must not touch it
# at all (it is archived AND latched, so it is forced single-sample inside the
# renderer instead), and its whole echo line must come back identical.
say 'seta cg_drawGun 1'; sleep 2
GUN_BEFORE=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
[ "$GUN_BEFORE" = 'is:"1' ] || die "could not seed the cg_drawGun sentinel (read ${GUN_BEFORE:-nothing})"
say 'seta r_ext_multisample 4'; sleep 2
MSAA_BEFORE=$(ask 'r_ext_multisample' | tr -d '\r' | grep -F 'r_ext_multisample' | head -1)
[ -n "$MSAA_BEFORE" ] || die "could not read r_ext_multisample before entering VR"
echo "   pre-VR: $GUN_BEFORE\" | $MSAA_BEFORE"

# --- 2. enter VR at the menu: panel, with the correct reason code ------------
echo "== 2. VR entry at the main menu presents a PANEL, and names the term"
say 'q3evr 1'; sleep 8
shot 01-vr-menu
zone_assert "MODENOW reports VR with the engine thread owning the frame" MODENOW 'mode=VR .*owner=vr'
# Entry must SETTLE, not ride its timeout. Phase 2 polls every 100 ms for the
# render extent to change; if the queued vid_restart never drains (a paused
# display link, a dropped command) it commits 6 s later and every sleep in this
# suite is long enough to hide that.
POLLS=$(grep -Eo 'VR: phase 2 settled after [0-9]+ poll' "$BB" | tail -1 | grep -Eo '[0-9]+' | tail -1)
if [ -n "$POLLS" ] && [ "$POLLS" -le 30 ]; then
  printf '   PASS  entry settled after %s poll(s), well inside the 60-poll abort\n' "$POLLS"
else
  printf '   FAIL  entry did not settle promptly (polls=%s) — the queued vid_restart is not draining\n' "${POLLS:-none}" >&2
  FAILED=1
fi
if grep -q 'VR: ENTRY ABORTED' "$BB"; then
  printf '   FAIL  the entry aborted\n' >&2; FAILED=1
else
  printf '   PASS  the entry did not abort\n'
fi
zone_assert "...and arbitration chose the panel because a menu is up" MODENOW \
  'present=panel reason=[0-9]+\(menu-up\)'
# The park is 1.5 s behind the commit and its outcome is read back from the
# window a second after that. On the first device round the window never parked
# at all and nothing in the log could say so — a request is not an outcome.
sleep 4
need "$BB" "the window park RAN" 'park\(1\) RUNNING'
need "$BB" "...and its outcome was read back from the window" 'park\(1\) SETTLED'
need "$BB" "the curtain went up over the window card" 'curtain: UP over the window card'
snap 01-vr-menu

# --- 2b. the non-world panel shows the WHOLE composite ----------------------
# Device finding: with a menu up in VR, the menu was clipped on the sides and
# along the bottom. The panel was sized at a fixed 4 m width chosen for a 16:9
# window — but in VR the composite is the PER-EYE extent, a near-square, so the
# quad came out nearly 4 m tall at 3 m and its own edges fell outside the field
# of view. Nothing reported it; the menu simply had no bottom row.
#
# Asserted as a PROPERTY, not a geometry: whatever aspect the engine hands over,
# the panel's angular size fits inside the limits on BOTH axes. Read from the
# placement the loop actually computed, so a future aspect cannot quietly break
# it. Entry has already resized the renderer to the per-eye extent by this point,
# so this is the failing configuration exactly.
echo "== 2b. the non-world panel fits the field of view on both axes"
zone_assert "the redirect is DISARMED on a non-world frame" PANELNOW 'redirect=0' q3evrpanel
# R2 item 5: the published h/v are now the LETTERBOXED CONTENT's own angular
# size inside a widescreen outer frame (34/24 degree half-angles at 2.6 m —
# full 68x48), not the R1 quad shaped to the composite's aspect (which topped
# out at 54/44) — deliberately bigger, per the device round that reported the
# old size as still cropping. The bound still means something: content can
# never exceed the OUTER frame it is fit inside (68/48 full), so 70/50 is a
# real ceiling, not a number picked to make this pass.
zone_assert "the panel subtends a size that fits the display on both axes" PANELNOW \
  'panel=\(d[0-9.]+m,hw[0-9.]+m,hh[0-9.]+m,aspect[0-9.]+,h[0-6][0-9]\.[0-9]deg,v[0-4][0-9]\.[0-9]deg\)' \
  q3evrpanel
# R2.1 fix 13c: the frame-SIZE regex above only ever bounds the OUTER box —
# it would pass just as happily if the letterbox math regressed to STRETCHING
# the near-square composite to fill the wide frame (exactly the distortion
# the letterbox shader exists to prevent), because a stretched quad is still
# a quad inside the same size ceiling. The actual claim item 5 makes is about
# CONTENT aspect: hw/hh (the published half-extents, already the FIT-ADJUSTED
# content size per the panel's own comment) must reproduce the `aspect` field
# — if letterboxing is working, the content quad's own aspect ratio equals
# the composite's; if it regressed to filling the frame, hh/hw would instead
# equal the OUTER FRAME's fixed ratio (~0.706) regardless of what `aspect`
# says the content actually is.
PANEL_LINE=$(lastline PANELNOW)
python3 - "$PANEL_LINE" <<'PYEOF'
import re, sys
line = sys.argv[1]
m = re.search(r'panel=\(d[0-9.]+m,hw([0-9.]+)m,hh([0-9.]+)m,aspect([0-9.]+),', line)
if not m:
    print("   FAIL  could not parse hw/hh/aspect out of PANELNOW", file=sys.stderr)
    sys.exit(1)
hw, hh, aspect = float(m.group(1)), float(m.group(2)), float(m.group(3))
got = hh / hw if hw > 0 else -1
if abs(got - aspect) < 0.03:
    print(f"   PASS  the fit-adjusted quad's own aspect (hh/hw={got:.3f}) matches the content aspect ({aspect:.3f}) — letterboxed, not stretched")
    sys.exit(0)
else:
    print(f"   FAIL  hh/hw={got:.3f} but the reported content aspect is {aspect:.3f} — the quad does not "
          f"reproduce the composite's own shape, which is exactly what a stretch-to-fill regression looks like",
          file=sys.stderr)
    sys.exit(1)
PYEOF
[ $? -eq 0 ] || FAILED=1
# Prove THIS checker can fail: a synthetic line where hh/hw is the outer
# frame's fixed ratio (~0.706) while `aspect` claims the content is
# near-square (0.95) — exactly what a stretch-to-fill regression would emit.
python3 - <<'PYEOF'
import re, sys
line = "[1ms t1] PANELNOW panel=(d2.60m,hw0.500m,hh0.353m,aspect0.950,h34.0deg,v24.0deg)"
m = re.search(r'panel=\(d[0-9.]+m,hw([0-9.]+)m,hh([0-9.]+)m,aspect([0-9.]+),', line)
hw, hh, aspect = float(m.group(1)), float(m.group(2)), float(m.group(3))
got = hh / hw
if abs(got - aspect) < 0.03:
    print("   FAIL  the aspect checker missed a stretched (frame-ratio) quad claiming a different content aspect", file=sys.stderr)
    sys.exit(1)
else:
    print(f"   PASS  confirmed: a stretched quad (hh/hw={got:.3f}) vs its own claimed aspect ({aspect:.3f}) is caught")
    sys.exit(0)
PYEOF
[ $? -eq 0 ] || FAILED=1
shot 01b-vr-menu-panel
pixels "the menu is on the panel" "$PFX-01b-vr-menu-panel.png" nonblack --min 20000

# --- 2c. the four corners of the widened panel are covered (R2 item 5) -----
# "The quad shows a crop of the square composite" — the R1 panel's own edges
# fell inside the field of view but the CONTENT (drawn for a near-square
# extent) sat flush against them with no margin. Four inset regions, one per
# corner of the panel's own bounding rect, each required to carry content —
# a panel that is still cropped or still tiny fails at least one corner.
# --regionpct (not --region): a menu/panel frame's `simctl io screenshot` can
# land at a genuinely different resolution than a full stereo world frame in
# the SAME run — percentages of this image's own size, not literal pixels.
echo "== 2c. the widened panel's four corners all carry content"
pixels "top-left corner of the panel has content" "$PFX-01b-vr-menu-panel.png" nonblack \
  --regionpct 20,15,35,35 --min 40
pixels "top-right corner of the panel has content" "$PFX-01b-vr-menu-panel.png" nonblack \
  --regionpct 65,15,80,35 --min 40
pixels "bottom-left corner of the panel has content" "$PFX-01b-vr-menu-panel.png" nonblack \
  --regionpct 20,65,35,85 --min 40
pixels "bottom-right corner of the panel has content" "$PFX-01b-vr-menu-panel.png" nonblack \
  --regionpct 65,65,80,85 --min 40

# --- 3. a live world: per-eye world frames ----------------------------------
echo "== 3. a bot match produces per-eye WORLD frames"
say 'map q3dm1'; sleep 20
zone_assert "arbitration switched to the world" MODENOW 'present=world reason=0\(world\)'
zone_assert "the engine is rendering per-eye at the drawable's physical size" EYENOW \
  'engine=[1-9][0-9]*x[1-9][0-9]*px'
zone_assert "depth snapshots are live" DEPTHNOW 'wanted=1 live=1'
# Single-sample is what makes a mid-frame colour snapshot and a copyable depth
# attachment valid. Asserted from the number the RENDERER used, not from the
# cvar it was asked to leave alone.
zone_assert "VR is rendering single-sample" EYENOW 'msaa=1x'
# R2.3 fix 4: the per-eye extent is never NARROWER than 4:3. Quake III's own
# menu QVM scales its 640x480 layout by height on both axes and centres it only
# when the screen is WIDER than 4:3 — on a narrower one it draws from x=0 and
# the overflow is clipped away, which is what cut the right fifth off the menu
# on the device. Read from the numbers the engine reports rather than the ones
# the compositor asked for, and computed here so a future drawable shape cannot
# quietly reintroduce it. The simulator's own drawable is already wider than
# 4:3, so this is a property assertion, not a reproduction of the device case.
EW=$(lastline EYENOW | grep -Eo 'engine=[0-9]+x[0-9]+px' | grep -Eo '[0-9]+' | head -1)
EH=$(lastline EYENOW | grep -Eo 'engine=[0-9]+x[0-9]+px' | grep -Eo '[0-9]+' | sed -n 2p)
if [ -n "$EW" ] && [ -n "$EH" ] && [ "$((EH * 4))" -le "$((EW * 3))" ]; then
  printf '   PASS  the engine extent %sx%s is 4:3 or wider (Quake III cannot draw a menu into narrower)\n' "$EW" "$EH"
else
  printf '   FAIL  engine extent %sx%s is NARROWER than 4:3 — the menu will be clipped on the right\n' \
         "${EW:-?}" "${EH:-?}" >&2
  FAILED=1
fi
shot 02-vr-world
pixels "the world frame is not a black screen" "$PFX-02-vr-world.png" nonblack --min 20000
snap 03-vr-world

# --- 4. the pixels respond to the pose --------------------------------------
# Differential, deliberately: any fixed region goes stale, and "the world is
# drawn" is not the same claim as "the world responded to the pose".
echo "== 4. injected pose moves the pixels"
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
shot 03-pose-yaw0
say 'q3evrpose 90 0 0 1.60 0'; sleep 3
shot 04-pose-yaw90
pixels "a 90-degree yaw injection changes the frame" "$PFX-03-pose-yaw0.png" diff \
  --diff "$PFX-04-pose-yaw90.png" --minpct 15
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
shot 05-pose-back
# The world is LIVE while this runs (bots move, animations play), so "the same
# pose" is not the same picture — it is the same picture plus a few per cent of
# moving world. The bound separates that from the ~50% a real yaw produces.
pixels "...and coming back reproduces the first frame" "$PFX-03-pose-yaw0.png" diff \
  --diff "$PFX-05-pose-back.png" --maxpct 20
zone_assert "HEADNOW reports the injected pose" HEADNOW 'synth=1 headpos=\(0\.000,1\.600,0\.000\)m'

# --- 4b. an ASYMMETRIC vertical frustum: the cull planes follow it -----------
# The simulator's drawable has no projection to recover, so without injection the
# tangents are symmetric — and a vertical cull plane attached to the wrong edge is
# ARITHMETICALLY INVISIBLE in the symmetric case. It is also close to invisible in
# a screenshot even when wrong (BSP culling is per node, and the surfaces at your
# feet straddle the plane either way), so this asserts the planes themselves:
# FRUSTUMNOW reports the bottom/top tangents recovered from the FINISHED planes,
# and they must match the ones that were asked for.
echo "== 4b. asymmetric-Y frustum: the cull planes follow the projection"
say 'q3evrtan -1.0 1.0 -1.6 0.45'; sleep 4
zone_assert "the cull planes encode the ASKED-FOR bottom and top, not each other's" FRUSTUMNOW \
  'wantL=\(b-1\.600,t0\.450\) cullL=\(b-1\.6[0-9]*,t0\.45[0-9]*\)'
shot 05b-asym-y
pixels "the asymmetric frustum still renders a world" "$PFX-05b-asym-y.png" nonblack --min 20000

# --- 4b-i. THE PROJECTION THE GPU ACTUALLY GOT ------------------------------
# The tangents that go IN are already asserted above. This asserts what comes
# OUT, and the difference between those two is where a shipped defect lived: the
# OpenGL-to-Vulkan conversion inverts Y by negating the projection's vertical
# SCALE, and for twenty-six years the vertical OFF-CENTRE term beside it was
# always zero, so negating it too was never needed. A head-mounted display's
# per-eye frustum is off-centre in both axes. The world was then rendered through
# a projection the compositor had not been told about: a fixed offset while the
# head is still, and a depth-dependent warp the moment it moves.
#
# So: where does the FINISHED projection put the four edges that were asked for?
# Left -1, right +1, bottom +1, top -1 (Vulkan's Y runs down), or the matrix is
# not the frustum. Run while the tangents are strongly asymmetric, because that
# is the only condition under which the wrong answer differs from the right one.
echo "== 4b-i. the finished projection encodes the frustum it was given"
zone_assert "the projection puts the asked-for edges at the NDC limits" PROJNOW \
  'edgeL=\(l-(0\.99[0-9]|1\.00[0-9]),r(0\.99[0-9]|1\.00[0-9]),b(0\.99[0-9]|1\.00[0-9]),t-(0\.99[0-9]|1\.00[0-9])\)' \
  q3evrproj
# Prove the assertion can fail: a SYMMETRIC frustum passes it whichever way the
# vertical off-centre term is signed (the term is zero), so a run that only ever
# saw symmetry would prove nothing. The asymmetric case above is the one that
# discriminates, and this records that it really was asymmetric at the time.
zone_assert "...and the frustum under test really was asymmetric" FRUSTUMNOW \
  'wantL=\(b-1\.600,t0\.450\)'
say 'q3evrtan off'; sleep 3

# --- 4b-ii. brightness: VR is graded the way the flat window is --------------
# The engine's gamma pass (pow(colour, 1/r_gamma) * (1 << overbrightBits)) lives
# in the blit to the swapchain, and nothing in VR goes through the swapchain. The
# overbright factor is not decoration: the renderer scales vertex lighting DOWN
# by 1/overbright on the way in and expects that pass to put it back. Missing it
# is a picture half as bright as the flat window, which is what the device round
# reported.
echo "== 4b-ii. the VR blit reproduces the engine's own gamma + overbright"
zone_assert "the grade the VR blit applies is the engine's live one" PROJNOW \
  'gammainv=[0-9]\.[0-9]+ overbright=[1-9]\.[0-9]+x' q3evrproj
OB=$(lastline PROJNOW | grep -Eo 'overbright=[0-9.]+' | cut -d= -f2)
# awk, not bc, and no `|| echo 1` fallback: a comparison tool that fails must
# fail the ASSERTION. The bc form here passed whenever bc itself errored, which
# is a check that reports success when it did not run.
if [ -n "${OB:-}" ] && awk -v v="$OB" 'BEGIN{exit !(v+0 >= 1.0)}'; then
  printf '   PASS  overbright is a real scale factor (%sx), not a zero that would black the eyes\n' "$OB"
else
  printf '   FAIL  overbright read back as %s — the eye blit would multiply the world by it\n' \
         "${OB:-none}" >&2; FAILED=1
fi

# --- 4b-iii. the 2D redirect: the HUD leaves the eyes ------------------------
# The headline R1 change. In a VR WORLD frame the entire 2D stream is separated
# out of the eye buffers and onto one head-locked layer, which is what removes
# the doubled scoreboard and the two in-world crosshairs — and gives mod HUDs
# the same treatment for free, because it is the engine's own stream and the
# engine does not know which mod drew it.
#
# Asserted as an IDENTITY: the redirect is armed, the layer is being written, and
# the compositor is copying it. A screenshot cannot tell a HUD on the layer from
# a HUD in the eyes.
echo "== 4b-iii. the 2D stream is redirected to the UI layer in world frames"
zone_assert "the redirect is armed in a world frame" PANELNOW 'redirect=1' q3evrpanel
UIF1=$(lastline PANELNOW | grep -Eo 'uiframes=[0-9]+' | cut -d= -f2)
UIC1=$(lastline PANELNOW | grep -Eo 'uicopies=[0-9]+' | cut -d= -f2)
sleep 3
say 'q3evrpanel'; sleep 2
UIF2=$(lastline PANELNOW | grep -Eo 'uiframes=[0-9]+' | cut -d= -f2)
UIC2=$(lastline PANELNOW | grep -Eo 'uicopies=[0-9]+' | cut -d= -f2)
if [ "${UIF2:-0}" -gt "${UIF1:-0}" ] && [ "${UIC2:-0}" -gt "${UIC1:-0}" ]; then
  printf '   PASS  the UI layer is being written AND copied (frames %s->%s, copies %s->%s)\n' \
         "$UIF1" "$UIF2" "$UIC1" "$UIC2"
else
  printf '   FAIL  the UI layer is not advancing (frames %s->%s, copies %s->%s) — a HUD that never\n' \
         "${UIF1:-none}" "${UIF2:-none}" "${UIC1:-none}" "${UIC2:-none}" >&2
  printf '         updates hangs frozen in the world and looks exactly like one that works\n' >&2
  FAILED=1
fi
shot 05c-vr-world-hud
pixels "the world frame with the UI layer is still a world" "$PFX-05c-vr-world-hud.png" \
  nonblack --min 20000

# --- 4b-v. HEAD-AIM MODE (default): aim IS gaze, so the basis never diverges
# R2.1 fix 2: cl_vr_view_yaw now ALREADY contains the head's yaw — patch
# 0013's CL_VRApplyHeadAim writes it into cl.viewangles before CL_FinishMove
# samples this frame's view yaw. The OLD formula here (view + head) would
# double it: a 60-degree head turn walks the player at body+120 degrees, the
# exact R1 device bug patch 0013 was written to fix, reintroduced by the
# basis math never learning about it. In head-aim mode the basis is the aim
# yaw AS-IS, so the delta is ~0 at ANY head yaw — movement always follows
# where the player is looking, because that IS the aim now.
echo "== 4b-v. HEAD-AIM MODE: aim IS gaze, so the move basis never diverges from it"
say 'q3evrheadaim 1'; sleep 1
say 'q3evrmovemode head'; sleep 2
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "with the head straight ahead the basis matches the aim" MOVENOW \
  'basis=head basissrc=head .*active=1 .*delta=-?0\.[0-9]deg' q3evrmove
say 'q3evrpose 60 0 0 1.60 0'; sleep 3
zone_assert "a 60-degree head yaw is ALREADY folded into the aim — delta stays zero" MOVENOW \
  'delta=-?0\.[0-9]deg' q3evrmove
zone_assert "the head gyro is suppressed in VR (no self-drifting aim)" MOVENOW \
  'gyrosuppressed=1' q3evrmove
# Delta=0 means NO rotation is applied to the move vector at all — pushing
# forward with the head yawed 60 degrees still sends a plain forward packet,
# because forward-in-the-aim-basis IS forward-in-the-gaze-basis now.
say '+forward'; sleep 2
zone_assert "...so the move packet is UNROTATED at 60 degrees of head yaw" MOVENOW \
  'pre=\(f12[0-9],r0\) sent=\(f12[0-9],r-?[0-2]\)' q3evrmove
say '-forward'; sleep 2
say 'q3evrpose 0 0 0 1.60 0'; sleep 3

# --- 4b-v-i. PROOF: q3evrheadaim 0 is what still exercises the OLD rotation -
# `q3evrheadaim 0` is patch 0013's own fault-injection switch: with it off,
# CL_VRApplyHeadAim never touches cl.viewangles, so cl_vr_view_yaw stays
# BODY-ONLY and PublishMoveBasis's OLD (R1) formula — view + head — is what
# still points movement at the head. This both proves 4b-v's delta=0 is not
# vacuous (disabling the hook visibly reopens the exact 60-degree delta the
# old suite asserted) and keeps the R1 rotation math itself under test, since
# it is still live code for this path.
echo "== 4b-v-i. q3evrheadaim 0: the pre-R2 (R1) view+head basis still works"
say 'q3evrheadaim 0'; sleep 1
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "hook disabled, head straight ahead: still zero delta" MOVENOW \
  'delta=-?0\.[0-9]deg' q3evrmove
say 'q3evrpose 60 0 0 1.60 0'; sleep 3
zone_assert "hook disabled: a 60-degree head yaw reopens a 60-degree move-basis delta (R1 formula)" MOVENOW \
  'delta=(59|60|61)\.[0-9]deg' q3evrmove
say 'q3evrpose 0 0 0 1.60 0'; sleep 3

# --- 4b-v-ii. THE ROTATED VECTOR'S DIRECTION, not its angle (hook disabled) -
# The first version of this section asserted the basis DELTA and stopped
# there. The delta was right and the rotation applied to it was inverted, so
# the case passed while the player, head turned 60 degrees left and stick
# pushed straight forward, was sent a hard strafe to the RIGHT — up to 120
# degrees away from where they were looking. That rotation only fires today
# with the head-aim hook disabled (4b-v above showed the default path applies
# no rotation at all), so this now runs there, on purpose — it is the ONLY
# live path left that exercises it, and the math itself did not change.
#
# The usercmd's basis is (forward, RIGHT) and Quake's yaw increases to the LEFT,
# so expressing one yaw's basis in another is the TRANSPOSE of the rotation. An
# angle cannot show that; only the SIGN of the vector that goes into the packet
# can. `+forward` is used rather than a stick because it needs no controller.
echo "== 4b-v-ii. hook disabled: the rotated move vector points where the head is looking"
say '+forward'; sleep 2
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "head straight ahead: forward stays forward, no strafe" MOVENOW \
  'pre=\(f12[0-9],r0\) sent=\(f12[0-9],r-?[0-2]\)' q3evrmove
# Head LEFT of the aim: the move must acquire a LEFT component, which in the
# usercmd's right-handed-in-name-only basis is a NEGATIVE rightmove.
say 'q3evrpose 60 0 0 1.60 0'; sleep 3
zone_assert "head 60 deg LEFT: the vector strafes LEFT (negative rightmove)" MOVENOW \
  'pre=\(f12[0-9],r0\) sent=\(f(5[0-9]|6[0-9]|7[0-5]),r-(10[0-9]|11[0-5])\)' q3evrmove
# And the mirror, which is what pins the MATRIX rather than one sign.
say 'q3evrpose -60 0 0 1.60 0'; sleep 3
zone_assert "head 60 deg RIGHT: the vector strafes RIGHT (positive rightmove)" MOVENOW \
  'pre=\(f12[0-9],r0\) sent=\(f(5[0-9]|6[0-9]|7[0-5]),r(10[0-9]|11[0-5])\)' q3evrmove
say '-forward'; sleep 2
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
# Restore the shipping default before the rest of the suite — everything from
# here on assumes the hook is doing its job.
say 'q3evrheadaim 1'; sleep 1

echo "== 4b-vi. snap and smooth turn"
say 'q3evrturn 45'; sleep 2
zone_assert "snap-45 is selected" MOVENOW 'turn=snap45' q3evrmove
SNAP1=$(lastline MOVENOW | grep -Eo 'snaps=[0-9]+' | cut -d= -f2)
# HELD past the fire threshold for two seconds — roughly 200 engine frames. The
# property under test is that it turns ONCE: a stick a player is holding must not
# spin them. Then the hold expires (the pad reads 0.0 again, below the 0.4
# re-arm) and a second hold fires the second snap.
#
# The first version of this case injected one-shot deflections instead, and read
# 4 snaps from 5 injections — because the pad layer polls this every frame and
# its own 0.0 re-armed the hysteresis between them. The injection has to be a
# HOLD or it measures the injection, not the feature.
say 'q3evrturnstick 0.9 2.0'; sleep 4
say 'q3evrmove'; sleep 2
SNAPMID=$(lastline MOVENOW | grep -Eo 'snaps=[0-9]+' | cut -d= -f2)
if [ "$(( ${SNAPMID:-0} - ${SNAP1:-0} ))" = 1 ]; then
  printf '   PASS  a two-second HELD deflection fired exactly one snap (snaps %s->%s)\n' \
         "$SNAP1" "$SNAPMID"
else
  printf '   FAIL  a held deflection fired %s snaps, not 1 (snaps %s->%s) — a held stick spins the player\n' \
         "$(( ${SNAPMID:-0} - ${SNAP1:-0} ))" "${SNAP1:-none}" "${SNAPMID:-none}" >&2; FAILED=1
fi
say 'q3evrturnstick 0.9 2.0'; sleep 4
say 'q3evrmove'; sleep 2
SNAP2=$(lastline MOVENOW | grep -Eo 'snaps=[0-9]+' | cut -d= -f2)
if [ "$(( ${SNAP2:-0} - ${SNAPMID:-0} ))" = 1 ]; then
  printf '   PASS  ...and it re-armed once released, so the next hold fires again (snaps %s->%s)\n' \
         "$SNAPMID" "$SNAP2"
else
  printf '   FAIL  the hysteresis did not re-arm: %s snaps on the second hold (snaps %s->%s)\n' \
         "$(( ${SNAP2:-0} - ${SNAPMID:-0} ))" "${SNAPMID:-none}" "${SNAP2:-none}" >&2; FAILED=1
fi
zone_assert "the snap that fired was -45 degrees for a rightward stick" MOVENOW \
  'lastsnap=-45deg' q3evrmove
say 'q3evrturn smooth 140'; sleep 2
zone_assert "smooth turn is restored at its default rate" MOVENOW \
  'turn=smooth speed=140deg/s' q3evrmove

# --- 4b-vii. height calibration, its sanity gate, and the trim --------------
echo "== 4b-vii. height calibration"
say 'q3evrcalibrate 1.75'; sleep 2
zone_assert "a plausible standing height is accepted" HEIGHTNOW \
  'valid=1 baseline=1\.75m' q3evrhead
zone_assert "...and becomes a positive rise above the character's own eye height" HEIGHTNOW \
  'request=[1-9][0-9]*\.[0-9]u' q3evrhead
# Prove the gate refuses as well as accepts — a gate only ever seen accepting is
# not known to be a gate.
say 'q3evrcalibrate 4.0'; sleep 2
zone_assert "an implausible height is REFUSED and the good baseline is kept" HEIGHTNOW \
  'valid=1 baseline=1\.75m' q3evrhead
say 'q3evrheight -0.30'; sleep 2
zone_assert "the trim moves the request" HEIGHTNOW 'trim=-0\.30m' q3evrhead
say 'q3evrheight 0'; sleep 2

# --- 4b-viii. the height gates refuse NOT-A-NUMBER --------------------------
# `if (m < LO || m > HI) refuse` ACCEPTS NaN: every comparison with NaN is false.
# An accepted NaN baseline is persisted, restored next launch, and turns the
# ceiling clamp's easing branch into an integrator — the camera leaves the map at
# 40 units a second, forever, on every launch, with nothing the player can undo.
# Both entry points are driven, because both had the bug in a different spelling.
echo "== 4b-viii. NaN cannot get into the height chain"
say 'q3evrcalibrate 1.80'; sleep 2
zone_assert "a good baseline is in place before the NaN attempt" HEIGHTNOW \
  'valid=1 baseline=1\.80m' q3evrhead
say 'q3evrcalibrate nan'; sleep 2
zone_assert "a NaN baseline is REFUSED and the good one kept" HEIGHTNOW \
  'valid=1 baseline=1\.80m' q3evrhead
say 'q3evrheight nan'; sleep 2
zone_assert "a NaN trim is REFUSED" HEIGHTNOW 'trim=\+0\.00m' q3evrhead
zone_assert "...and the applied rise is still a finite number" HEIGHTNOW \
  'request=[0-9-]+\.[0-9]u applied=[0-9-]+\.[0-9]u' q3evrhead

# --- 4b-ix. the argless calibrate reads a height that EXISTS -----------------
# q3e_vrHeadPos is relative to the captured base, so for a player standing where
# they entered it is about zero — and the sanity gate then refused every real
# on-device recalibration while the forced-value form the suite used worked
# perfectly. The argless path is the one a player actually presses.
echo "== 4b-ix. argless recalibration works from a real pose"
say 'q3evrpose 0 0 0 1.42 0'; sleep 3
say 'q3evrcalibrate'; sleep 2
zone_assert "the argless path captured the ORIGIN-space head height" HEIGHTNOW \
  'valid=1 baseline=1\.4[0-9]m' q3evrhead
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
say 'q3evrcalibrate 1.75'; sleep 2

# --- 4b-ix.1. Reset and Re-calibrate land on the SAME height (R3.5) ---------
# Reported from glass on 1.0.4.10: the Reset button made the maintainer slightly
# shorter, Re-calibrate slightly taller. Reset cleared the baseline and stopped
# there, which drops the player onto Quake's own 50-unit eye until something
# re-measures; Re-calibrate measured the head where it was. Reset now
# re-calibrates as part of what it does, so both buttons run the sequence below
# and the height they leave behind is the same one.
#
# What the simulator can settle is the ENGINE half, which is what both buttons
# now delegate to: argless capture plus a zeroed trim, from any prior state,
# reaching the same answer and staying there when repeated. (Tapping the two
# UIKit buttons is not something the console bridge can do; the sheet wiring is
# a read.)
echo "== 4b-ix.1. Reset and Re-calibrate agree on the height (R3.5 invariant)"
say 'q3evrpose 0 0 0 1.62 0'; sleep 3
# A deliberately WRONG starting state: a stale baseline from some other room and
# a trim dialled against it. This is the state Reset exists to leave.
say 'q3evrcalibrate 1.40'; sleep 2
say 'q3evrheight 0.10'; sleep 2
zone_assert "the stale baseline and its trim are really in place first" HEIGHTNOW \
  'valid=1 baseline=1\.40m trim=\+0\.10m' q3evrhead
# The Re-calibrate sequence.
say 'q3evrcalibrate'; sleep 2
say 'q3evrheight 0'; sleep 2
zone_assert "Re-calibrate: fresh baseline from the live head, trim zeroed" HEIGHTNOW \
  'valid=1 baseline=1\.6[0-9]m trim=\+0\.00m' q3evrhead
RECAL_REQ=$(lastline HEIGHTNOW | grep -Eo 'request=[0-9.-]+u')
# Idempotent: pressing it again from its own result must not move anything.
say 'q3evrcalibrate'; sleep 2
say 'q3evrheight 0'; sleep 2
RECAL_REQ2=$(lastline HEIGHTNOW | grep -Eo 'request=[0-9.-]+u')
if [ -n "$RECAL_REQ" ] && [ "$RECAL_REQ" = "$RECAL_REQ2" ]; then
  printf '   PASS  Re-calibrate twice from the same pose changes nothing (%s)\n' "$RECAL_REQ"
else
  printf '   FAIL  Re-calibrate is not idempotent: %s then %s\n' \
         "${RECAL_REQ:-none}" "${RECAL_REQ2:-none}" >&2; FAILED=1
fi
# The Reset sequence: back to the same wrong starting state, then Reset's own
# steps — the stale baseline goes, and the re-calibration that Reset now
# performs supplies a fresh one.
say 'q3evrcalibrate 1.40'; sleep 2
say 'q3evrheight 0.10'; sleep 2
say 'q3evrcalibrate'; sleep 2
say 'q3evrheight 0'; sleep 2
RESET_REQ=$(lastline HEIGHTNOW | grep -Eo 'request=[0-9.-]+u')
if [ -n "$RESET_REQ" ] && [ "$RESET_REQ" = "$RECAL_REQ" ]; then
  printf '   PASS  Reset leaves the player at exactly the Re-calibrate height (%s)\n' "$RESET_REQ"
else
  printf '   FAIL  Reset and Re-calibrate disagree: reset %s vs recalibrate %s\n' \
         "${RESET_REQ:-none}" "${RECAL_REQ:-none}" >&2; FAILED=1
fi
# And the failure this case exists to catch, produced on purpose: a Reset that
# clears and does NOT re-calibrate publishes no rise at all, which is the
# 1.0.4.10 behaviour and is NOT the same height.
say 'q3evrcalibrate nan'; sleep 2      # keeps the good baseline — the gate holds
say 'q3evrheight 0.25'; sleep 2
STALE_REQ=$(lastline HEIGHTNOW | grep -Eo 'request=[0-9.-]+u')
if [ -n "$STALE_REQ" ] && [ "$STALE_REQ" != "$RECAL_REQ" ]; then
  printf '   PASS  confirmed: a trim left over from another baseline DOES move the height (%s vs %s) — the comparison above discriminates\n' \
         "$STALE_REQ" "$RECAL_REQ"
else
  printf '   FAIL  the height comparison cannot discriminate: a +0.25 m trim read as %s, same as %s\n' \
         "${STALE_REQ:-none}" "${RECAL_REQ:-none}" >&2; FAILED=1
fi
say 'q3evrheight 0'; sleep 2
say 'q3evrcalibrate 1.75'; sleep 2

# --- 4b-x. the UI layer's ALPHA -------------------------------------------
# The half of the layer no screenshot can show. The engine reuses colour blend
# factors for alpha, so a half-transparent HUD fill lands at a*a (0.25 for 0.5)
# and an ADDITIVE draw accumulates coverage it must not have — a thing whose
# whole purpose is to add light ends up occluding the world.
echo "== 4b-x. the UI layer composites at the right coverage"
zone_assert "the standard 2D blend accumulates coverage as (ONE, 1-SRC_ALPHA)" UIALPHANOW \
  'blended=\(src1,dst7\)' q3evrpanel
zone_assert "an additive 2D draw adds light and NO coverage" UIALPHANOW \
  'additive=\(src0,dst1\)' q3evrpanel
# And the coverage itself, over a RUN of pixels rather than one.
#
# The first version of this probed a single pixel and aimed it at the
# scoreboard, which in vanilla Quake 3 is sparse TEXT on nothing — the sample
# landed between two rows, read transparent, and reported the coverage fix as
# broken. That was a layout guess dressed as a measurement. A run crosses
# whatever is actually there, and the CROSSHAIR is the target: dead centre, drawn
# every frame of every match, and the very thing R1 moved onto this layer.
say 'q3evruipixel 100 200 400'; sleep 3
say 'q3evruipixel 100 200 400'; sleep 2
zone_assert "the UI layer is EMPTY across a strip where nothing draws" UIPIXELNOW \
  'ready=1 .*maxalpha=0\.000 covered=0 of=400'
# The coordinates are DERIVED, not written down. This probe is a 400-pixel run
# centred on the crosshair, which sits at the middle of the layer — and the layer
# is the engine's own render target, so the Render Quality default moving from
# 1.25x to 1.85x (R3.3) slid the centre from 2400,1350 to 3552,1998 and the
# hardcoded run landed on empty layer. Reading the extent costs one dump and
# cannot go stale.
UI_EXT=""
for attempt in 1 2 3 4 5; do
  say 'q3evreye'; sleep 3
  UI_EXT=$(lastline EYENOW | grep -Eo 'engine=[0-9]+x[0-9]+px' | head -1)
  [ -n "$UI_EXT" ] && break
  echo "   (no EYENOW line yet for the UI-layer probe, attempt $attempt)"
done
UI_W=${UI_EXT#engine=}; UI_W=${UI_W%%x*}
# The `px` suffix comes off BEFORE the height is cut off the tail, because it
# contains an x of its own and a longest-prefix strip eats the whole line.
UI_H=${UI_EXT%px}; UI_H=${UI_H##*x}
[ -n "${UI_W:-}" ] && [ -n "${UI_H:-}" ] || die "could not read the render extent for the UI-layer probe"
UI_X=$(( UI_W / 2 - 200 )); UI_Y=$(( UI_H / 2 ))
echo "   UI layer is ${UI_W}x${UI_H}px — probing 400px across its centre at $UI_X,$UI_Y"
say "q3evruipixel $UI_X $UI_Y 400"; sleep 3
say "q3evruipixel $UI_X $UI_Y 400"; sleep 2
UIA=$(lastline UIPIXELNOW | grep -Eo 'maxalpha=[0-9.]+' | cut -d= -f2)
UIC=$(lastline UIPIXELNOW | grep -Eo 'covered=[0-9]+' | cut -d= -f2)
if [ -n "${UIA:-}" ] && awk -v v="$UIA" 'BEGIN{exit !(v+0 > 0.05)}' &&
   [ "${UIC:-0}" -gt 0 ]; then
  printf '   PASS  the crosshair gives the layer real coverage (maxalpha=%s, %s of 400 covered)\n' \
         "$UIA" "$UIC"
else
  printf '   FAIL  the crosshair drew but the layer carries no coverage (maxalpha=%s covered=%s) —\n' \
         "${UIA:-none}" "${UIC:-none}" >&2
  printf '         a HUD composited at zero alpha is invisible in the world and perfect in a capture\n' >&2
  FAILED=1
fi

# --- 4b-xi. a stopped HUD must DISAPPEAR, not hang in the world -------------
# The freshness contract the redirect promises: if the 2D stream stops, the
# head-locked quad has to go with it. A HUD frozen in the world is the one
# failure that looks exactly like success.
#
# Driven at the MECHANISM rather than through cg_draw2D. Turning the HUD off was
# the obvious way to make a 2D-less frame and it does not work — with cg_draw2D 0
# the stream still arrives from elsewhere in the frame and the layer keeps
# advancing, so the first version of this case was asserting against a premise
# that is false. It also asserts the QUAD, not just the counter: "the layer
# stopped updating" and "the player stopped seeing a stale HUD" are two different
# claims, and only the second one is the thing anybody would notice.
echo "== 4b-xi. the head-locked HUD is gated on the layer still advancing"
zone_assert "the quad is drawn while the stream is live" PANELNOW \
  'uiquad=1 uistall=0' q3evrpanel
# Baseline AFTER the stall arms and in-flight frames drain — sampling before
# the arm counts the frames between sample and arm as "advance" and fails a
# working feature (found by fault-injecting the case itself).
say 'q3evruistall 1'; sleep 2
say 'q3evrpanel'; sleep 2
UIF_A=$(lastline PANELNOW | grep -Eo 'uiframes=[0-9]+' | cut -d= -f2)
sleep 3
say 'q3evrpanel'; sleep 2
UIF_B=$(lastline PANELNOW | grep -Eo 'uiframes=[0-9]+' | cut -d= -f2)
if [ "${UIF_B:-0}" = "${UIF_A:-0}" ]; then
  printf '   PASS  a stalled 2D stream stops the UI layer advancing (uiframes held at %s)\n' "$UIF_B"
else
  printf '   FAIL  the UI layer kept advancing with the stream stalled (%s -> %s)\n' \
         "${UIF_A:-none}" "${UIF_B:-none}" >&2; FAILED=1
fi
zone_assert "...and the head-locked quad STOPS being drawn" PANELNOW \
  'uiquad=0 uistall=1' q3evrpanel
shot 05f-no-hud
say 'q3evruistall 0'; sleep 4
say 'q3evrpanel'; sleep 2
UIF_C=$(lastline PANELNOW | grep -Eo 'uiframes=[0-9]+' | cut -d= -f2)
if [ "${UIF_C:-0}" -gt "${UIF_B:-0}" ]; then
  printf '   PASS  and both resume when the stream comes back (%s -> %s)\n' "$UIF_B" "$UIF_C"
else
  printf '   FAIL  the UI layer did not resume after the stall was lifted (%s -> %s)\n' \
         "${UIF_B:-none}" "${UIF_C:-none}" >&2; FAILED=1
fi
zone_assert "...including the quad itself" PANELNOW 'uiquad=1 uistall=0' q3evrpanel

# --- 4b-xii. the right field's 2D is not drawn twice ------------------------
# Efficiency, asserted as identity: the redirect only ever ships the left field's
# copy, so drawing the right field's 2D was work whose result was discarded —
# along with a mid-frame pass break and a full-surface clear per host frame.
echo "== 4b-xii. the right field's repeat 2D is discarded, not drawn"
SW_A=$(lastline UIALPHANOW | grep -Eo 'swallowed2d=[0-9]+' | cut -d= -f2)
sleep 3; say 'q3evrpanel'; sleep 2
SW_B=$(lastline UIALPHANOW | grep -Eo 'swallowed2d=[0-9]+' | cut -d= -f2)
if [ "${SW_B:-0}" -gt "${SW_A:-0}" ]; then
  printf '   PASS  the right field'"'"'s 2D stream is being discarded every frame (%s -> %s)\n' \
         "$SW_A" "$SW_B"
else
  printf '   FAIL  the right field is still drawing a 2D stream nothing reads (%s -> %s)\n' \
         "${SW_A:-none}" "${SW_B:-none}" >&2; FAILED=1
fi

# --- 4b-xiii. a screenshot in VR shows the GAME ----------------------------
# Charter rule 6: a performance number needs a content screenshot from the same
# run. With the 2D stream separated out, the colour attachment a screenshot
# normally reads holds the HUD on a transparent ground and no game at all.
echo "== 4b-xiii. the content-capture channel still captures content"
shot 05g-vr-screenshot
pixels "a VR world screenshot is the world, not the separated HUD" \
  "$PFX-05g-vr-screenshot.png" nonblack --min 20000

# --- 4b-xiv. head aim: the sent angles track body+head (R2 item 1) ---------
# cl.viewangles is written every client frame as EXACTLY body_yaw+head_yaw
# (yaw) and head_pitch (pitch) once head-aim owns the aim — so `delta` in
# AIMNOW is an IDENTITY, not a measurement, and must read ~0 continuously.
echo "== 4b-xiv. head aim: sent angles track body+head, continuously (R2 item 1)"
say 'q3evrmovemode head'; sleep 1
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "level head: the sent/(body+head) identity holds" AIMNOW \
  'active=1 .*delta=-?0\.0000deg hookenabled=1' q3evraim
say 'q3evrpose 47 -18 0 1.60 0'; sleep 3
zone_assert "a yawed AND pitched head still keeps the identity" AIMNOW \
  'active=1 .*delta=-?0\.0000deg hookenabled=1' q3evraim
SENTYAW=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
if [ -n "$SENTYAW" ] && awk "BEGIN{v=$SENTYAW; if (v<0) v=-v; exit !(v > 40)}"; then
  printf '   PASS  the sent yaw actually MOVED with the head (%s deg) — the identity is not trivially always zero\n' "$SENTYAW"
else
  printf '   FAIL  the sent yaw did not follow the injected head yaw (sent=%s)\n' "${SENTYAW:-none}" >&2; FAILED=1
fi

# --- 4b-xiv-a. the SENT PITCH follows QUAKE's convention, not ARKit's -------
# The identity above (sent == body+head) holds trivially no matter which sign
# convention cl_vr_head_pitch carries, because CL_VRApplyHeadAim always sets
# cl.viewangles[PITCH] to whatever it was handed — so it passed identically on
# a build that never negated ARKit's convention into Quake's. This checks the
# REAL convention instead: Quake's own AngleVectors defines forward[2] =
# -sin(pitch), so a POSITIVE pitch looks DOWN and a NEGATIVE pitch looks UP.
# q3evrpose's OWN pitch argument follows the ARKit-facing rotX convention this
# suite already had to untangle for the sky-corner case below (4b-xviii) — a
# POSITIVE argument tilts the injected head UP (verified there against the
# corner-sky pose). So: inject a pose looking UP (a positive q3evrpose pitch)
# and require the SENT pitch to be negative — looking up, in Quake's own
# convention.
echo "== 4b-xiv-a. sent pitch follows Quake's convention: looking UP sends NEGATIVE pitch"
say 'q3evrpose 0 35 0 1.60 0'; sleep 3   # positive argument = physically looking UP
say 'q3evraim'; sleep 2
# R2.2 fix 3: read from `eff`, the pitch the SERVER computes (usercmd angles
# plus the playerstate's delta_angles), not from the raw accumulator. They are
# the same number only while that offset is zero, and after any respawn taken
# while pitched it is not — the accumulator then carries the compensation and
# is no longer the quantity whose SIGN this case is about.
SENTPITCH=$(lastline AIMNOW | sed -E 's/.*eff=\(p(-?[0-9.]+)\).*/\1/')
if [ -n "$SENTPITCH" ] && awk "BEGIN{exit !($SENTPITCH < -20)}"; then
  printf '   PASS  looking up sent a NEGATIVE pitch (%sdeg) — Quake convention, not ARKit'"'"'s\n' "$SENTPITCH"
else
  printf '   FAIL  looking up sent pitch=%s — expected a strongly negative value; ARKit'"'"'s\n' "${SENTPITCH:-none}" >&2
  printf '         positive-up convention appears to be reaching cl.viewangles unconverted\n' >&2
  FAILED=1
fi
say 'q3evrpose 0 0 0 1.60 0'; sleep 3

# --- 4b-xv. the head-aim identity assertion can FAIL (fault injection) -----
# R0.1's lesson applied directly: an assertion nobody has seen fail is not
# known to test anything. Disable the engine hook, inject a NEW head pose, and
# require the delta to open — sent angles freeze while head_yaw keeps moving.
echo "== 4b-xv. the head-aim identity assertion can FAIL (fault injection)"
say 'q3evrheadaim 0'; sleep 1
say 'q3evrpose 150 20 0 1.60 0'; sleep 3
# q3evrpose does not itself emit an AIMNOW line — ask for one explicitly, or
# this reads the STALE dump from the 'q3evrheadaim 0' command above (taken
# before the pose changed), which correctly shows delta=0 and proves nothing.
say 'q3evraim'; sleep 2
D=$(lastline AIMNOW | sed -E 's/.*delta=(-?[0-9.]+)deg.*/\1/')
say 'q3evrheadaim 1'; sleep 1
ABSD=$(awk "BEGIN{d=$D; if (d<0) d=-d; print d}" 2>/dev/null)
if [ -n "$ABSD" ] && awk "BEGIN{exit !($ABSD > 1.0)}"; then
  printf '   PASS  with the hook disabled the identity DOES fail (delta=%sdeg) — the assertion discriminates\n' "$D"
else
  printf '   FAIL  disabling the head-aim hook did not open the delta (delta=%s) — the assertion cannot fail, so it proves nothing\n' "${D:-none}" >&2
  FAILED=1
fi
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "...and the hook restores cleanly (identity holds again)" AIMNOW \
  'active=1 .*delta=-?0\.0000deg hookenabled=1' q3evraim

# --- 4b-xv-a. the eye OFFSET resolves against body yaw, not body+head (R2.1 fix 3)
# Every q3evrpose call anywhere ELSE in this suite uses x=z=0 — the head pivots
# exactly on the recentre point, which is precisely the blind spot that let
# this ship: with no roomscale offset, "resolve the offset against body+head"
# and "resolve it against body only" compute the SAME thing (there is nothing
# for the wrong basis to misplace). A nonzero offset is what makes the two
# answers diverge.
#
# The published eyeL/eyeR (HEADNOW) are the SHELL's pose.offset — the value
# about to be handed to the engine, which then rotates it by cl.viewangles[YAW]
# (body+head, after item 1b/R2.1). For the FINAL world-space eye position to
# stay put while only the head turns (no footstep, no body turn), this
# offset must be PRE-ROTATED by the exact inverse of the head's own
# contribution — i.e. it must change with head yaw at a FIXED physical
# position, canceling the engine's later rotation. The old code handed the
# engine a position-only vector that never responded to head yaw at all
# (nothing here rotated it), so the engine's own head-inclusive rotation
# applied to it UNCOMPENSATED — the eye orbits the recentre point as the head
# turns, reported here as eyeL/eyeR staying IDENTICAL across different
# injected yaws at the same physical offset. Fixed, the reported offset
# itself visibly changes with yaw (that is the compensation being applied);
# unfixed, it does not move at all — the two are trivially distinguishable
# without replicating the rotation matrix in bash.
echo "== 4b-xv-a. the eye offset compensates for head yaw at a NONZERO roomscale position"
say 'q3evrpose 0 0 0.50 1.60 0.30'; sleep 3
say 'q3evrhead'; sleep 2
EYE_Y0=$(lastline HEADNOW | grep -Eo 'eyeL=\([^)]*\)')
say 'q3evrpose 90 0 0.50 1.60 0.30'; sleep 3
say 'q3evrhead'; sleep 2
EYE_Y90=$(lastline HEADNOW | grep -Eo 'eyeL=\([^)]*\)')
echo "   eyeL at yaw=0: $EYE_Y0   eyeL at yaw=90 (same 0.50/0.30 offset): $EYE_Y90"
if [ -n "$EYE_Y0" ] && [ -n "$EYE_Y90" ] && [ "$EYE_Y0" != "$EYE_Y90" ]; then
  printf '   PASS  the published eye offset moves with head yaw at a fixed roomscale position\n'
  printf '         (the compensation that keeps the FINAL world position from orbiting)\n'
else
  printf '   FAIL  the eye offset at a 0.50/0.30 m roomscale position did not change between\n' >&2
  printf '         yaw=0 and yaw=90 (%s vs %s) — an UNCOMPENSATED offset is exactly what makes\n' \
         "${EYE_Y0:-none}" "${EYE_Y90:-none}" >&2
  printf '         the world orbit the recentre point as the head turns\n' >&2
  FAILED=1
fi
say 'q3evrpose 0 0 0 1.60 0'; sleep 3

# --- 4b-xvii. the viewmodel is visible in VR (R2 item 3) --------------------
# VR no longer forces cg_drawGun 0 on entry — the gun renders head-attached at
# real depth (RF_DEPTHHACK's range-off already shipped in patch 0009).
echo "== 4b-xvii. the viewmodel stays visible in VR (R2 item 3)"
GUN_LIVE=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
if [ "$GUN_LIVE" = 'is:"1' ]; then
  printf '   PASS  cg_drawGun reads 1 WHILE in VR — the entry override is gone\n'
else
  printf '   FAIL  cg_drawGun reads %s while in VR — expected 1 (item 3 override left in)\n' "${GUN_LIVE:-none}" >&2
  FAILED=1
fi

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

# --- 4b-xix. the 2D layer's independent region quads (R2 item 4) -----------
# One texture (the redirect), many quads: the statusbar/chat/message/crosshair
# quads each sample their own sub-rect and place independently; the fallback
# quad covers everything else (mods included). Presence and NON-degenerate
# sizing are what a simulator can prove; layout judgment is the device
# checklist's job (QUESTIONS Q-019).
echo "== 4b-xix. the 2D layer's region quads are present and positioned (R2 item 4)"
say 'q3evrhud on'; sleep 2
say 'q3evrhudheight 0'; sleep 2
say 'q3evrpanel'; sleep 2
zone_assert "the redirect is armed and the layer is advancing" PANELNOW \
  'redirect=1 .*uiquad=1' q3evrpanel
zone_assert "the fallback quad is sized bigger than the old whole-HUD box" PANELNOW \
  'ui=\(d[0-9.]+m,hw[0-9.]+m,hh[0-9.]+m,h([2-9][0-9]|[0-9]{3})\.[0-9]deg' q3evrpanel
# R2.1 fix 13b: the old regex's h([2-9][0-9]|[0-9]{3}) accepts ANY value from
# 20 up — including the R1 box's own 36 degrees, which this assertion claims
# to rule out (36 matches [2-9][0-9] as cleanly as any real R2 value does).
# Tightened to the actual expected band: the fallback half-angles are 28/22
# degrees, so the full horizontal span is AT MOST 56 degrees and — because
# q3e_vr_quad_half_width takes whichever axis is tighter for the composite's
# own aspect — genuinely close to it for a near-square source (the per-eye
# VR render target).
#
# R2.3 fix 3 multiplies those half-angles by the head-locked layer's own scale
# (R3.1 item 2 splits that in two, and this centred quad takes the HUD SIZE
# half — it has no offset for Panel Size to act on), whose default remains
# 1.25 — so the band moves with it: 40-59.9 becomes 50-74.9, still excluding
# the old 36-degree box by a wide margin at the bottom and still bounded above
# (the multiplier's own 2.0 ceiling would reach 112, which this would catch as
# a default that had silently changed).
zone_assert "...and the size is in the NEW range specifically, not just >=20 (R2.1 fix 13b)" \
  PANELNOW 'ui=\(d[0-9.]+m,hw[0-9.]+m,hh[0-9.]+m,h(5[0-9]|6[0-9]|7[0-4])\.[0-9]deg' q3evrpanel
# Prove 13b's OLD regex really did admit the R1 box it claimed to exclude —
# fed a synthetic PANELNOW line at exactly 36.0 degrees.
SELFT2=$(mktemp)
printf '[1ms t1] PANELNOW ui=(d1.75m,hw0.500m,hh0.400m,h36.0deg,v28.0deg)\n' > "$SELFT2"
if grep -Eq 'ui=\(d[0-9.]+m,hw[0-9.]+m,hh[0-9.]+m,h([2-9][0-9]|[0-9]{3})\.[0-9]deg' "$SELFT2"; then
  printf '   PASS  confirmed: the OLD (h>=20) regex admits a 36-degree R1-sized box — it did not discriminate\n'
else
  printf '   FAIL  the OLD regex unexpectedly rejected 36 degrees — the "vacuous assertion" claim needs re-checking\n' >&2
  FAILED=1
fi
if grep -Eq 'ui=\(d[0-9.]+m,hw[0-9.]+m,hh[0-9.]+m,h(4[0-9]|5[0-9])\.[0-9]deg' "$SELFT2"; then
  printf '   FAIL  the NEW (40-59.9) regex still admits 36 degrees — it does not discriminate either\n' >&2
  FAILED=1
else
  printf '   PASS  ...and the NEW regex correctly rejects it\n'
fi
rm -f "$SELFT2"
# R2.1 fix 7: the source rects actually grew as documented — 64->80 rows for
# NOTIFY (the callvote-at-58 margin), 96->180 for MESSAGE (the row-160
# margin) — asserted as an identity, not inferred from pixels a mismatched
# HUD layout could produce for unrelated reasons.
#
# R2.3 fix 1 moves the MESSAGE band's TOP edge from row 64 to row 80, so the
# bands stop overlapping: rows 64..80 were inside BOTH the notify rect and the
# message rect and were therefore drawn twice, in two places, at two sizes.
# Same bottom edge (244), so the row-160 margin the R2.1 note is about is
# untouched; the height that reports it is now 164 rows rather than 180.
zone_assert "the notify source rect is 80 virtual rows" PANELNOW \
  'notifyrows=80 ' q3evrpanel
zone_assert "the message source rect starts BELOW notify (164 rows: 80..244)" PANELNOW \
  'messagerows=164 ' q3evrpanel
# R4.2 item 1: the band's top edge moved again, 372 -> 356, because
# CG_DrawWeaponSelect draws the selected weapon's NAME at rows 358..374 and 372
# cut three rows off the bottom of it — the device screenshot's doubled,
# clipped "Machinegun". See 4b-xix-b below for the containment assertion and its
# fault injection; this line pins the number the loop actually used.
#
# R3.2 item 3: the statusbar band is the WHOLE lower HUD cluster now — 372..480,
# 108 rows — because baseq3 draws the score box (404..428), the team strip (420)
# and the status face (420, and 390 under the damage kick) above the old 428
# boundary, and everything above it was left behind on the centred fallback quad.
# The device screenshot showed all three symptoms of that at once.
zone_assert "the statusbar source rect takes in the whole lower cluster (356..480)" PANELNOW \
  'statusrows=124 statustop=356 ' q3evrpanel
shot 05i-hud-low
pixels "the statusbar quad has content" "$PFX-05i-hud-low.png" nonblack \
  --regionpct 36,69,64,100 --min 20000

# --- 4b-xix-a. HUD Height moves the whole cluster, together (R3.2 items 2/3) -
# The device round's requirement in one line: health/ammo and the scores "should
# line up as you adjust height of HUD". They are on ONE quad now, so the thing
# to prove is that the quad MOVES with the slider and that its own extent does
# not change while it does — i.e. the height is a translation of the cluster,
# not a scale that would pull it apart the way Panel Size did.
echo "== 4b-xix-a. HUD Height translates the whole head-locked cluster"
say 'q3evrpanel'; sleep 2
SB_PITCH_0=$(lastline PANELNOW)
say 'q3evrhudheight 12'; sleep 3
say 'q3evrpanel'; sleep 2
SB_PITCH_UP=$(lastline PANELNOW)
shot 05i-hud-height-up
say 'q3evrhudheight -12'; sleep 3
say 'q3evrpanel'; sleep 2
SB_PITCH_DN=$(lastline PANELNOW)
shot 05i-hud-height-down
say 'q3evrhudheight 0'; sleep 2
echo "   statusbar pitch fields: $(printf '%s' "$SB_PITCH_0" | grep -Eo 'statuspitch=[+-][0-9.]+deg') |" \
     "$(printf '%s' "$SB_PITCH_UP" | grep -Eo 'statuspitch=[+-][0-9.]+deg') |" \
     "$(printf '%s' "$SB_PITCH_DN" | grep -Eo 'statuspitch=[+-][0-9.]+deg')"
if python3 "$ROOT/scripts/vr-hudheight-check.py" \
     "$SB_PITCH_0" "$SB_PITCH_UP" "$SB_PITCH_DN" 12; then
  :
else
  FAILED=1
fi
# ...and the height must NOT change the band's size, or "move the HUD" would
# quietly mean "resize the HUD" as the old Panel Size did.
zone_assert "...and the band's own extent is untouched by the height" PANELNOW \
  'statusrows=124 statustop=356 .*hudsize=1.10x' q3evrpanel
# "Off" is verified through the command's own state, not a pixel comparison:
# the statusbar band sits over ordinary floor geometry, which is ALSO
# "nonblack" by the same coarse predicate at this region's granularity, so a
# region-average comparison could not reliably separate "floor plus bright
# HUD digits" from "floor alone" without a colour predicate this suite does
# not have yet (confirmed empirically — the region's count barely moved
# between Low and Off even though the digits are visibly gone in the
# screenshots, e.g. artifacts/vr-sim/*-05i-hud-off.png, inspected by hand).
# What IS reliably testable here: the command reaches the renderer, and — R3.2
# item 4 — that Off now draws NO head-locked quad at all rather than moving the
# statusbar's content onto the centred fallback quad, which is what the old
# "hide one quad" Off effectively did.
say 'q3evrhud off'; sleep 3
HUD_OFF=$(ask 'q3evrhud' | grep -Eo 'q3evrhud: [a-z]+' | head -1)
shot 05i-hud-off
if [ "$HUD_OFF" = "q3evrhud: off" ]; then
  printf '   PASS  q3evrhud off reached the renderer (see the screenshot for the visual: %s)\n' \
         "$PFX-05i-hud-off.png"
else
  printf '   FAIL  q3evrhud off did not stick (%s)\n' "${HUD_OFF:-none}" >&2
  FAILED=1
fi
# R2.1 fix 5: with HUD Off, the statusbar's own dedicated quad correctly
# stays hidden — but before this fix the fallback/scoreboard quad ALSO
# excluded the statusbar's rect unconditionally ("Off hides it too"), so the
# bottom 64 virtual rows (spectator banner, team chat rows, scoreboard rows,
# any mod HUD element living there) rendered NOWHERE — carved out of the one
# quad that would otherwise have shown them. Asserted as an identity: with
# HUD Off, only 3 of the 4 dedicated quads draw (statusbar itself does not),
# so only 3 rects are fed to the fallback's exclusion mask — the bottom rows
# are NOT one of them, and the fallback quad (which samples the WHOLE
# texture) carries that content through.
#
# R2.3 fix 1 changes the counts, not the property: there are THREE dedicated
# quads now (the crosshair quad is gone — see 4b-xx), and the fallback's
# exclusion list always carries the crosshair BOX whether or not any region
# drew, because "the engine's flat crosshair is never visible in a VR world
# frame" is a property of the mode. So HUD Off draws 2 and excludes 3, and HUD
# Low draws 3 and excludes 4.
# R3.2 item 4: Off draws NOTHING — no region quads and no fallback quad either,
# in an ordinary world frame. R2.1 fix 5's concern (content rendering NOWHERE
# because a hole was carved that nothing filled) does not apply to a frame that
# deliberately shows no HUD at all; what would re-create it is Off leaving the
# fallback up, which is the state this asserts against.
zone_assert "HUD Off: no dedicated quad draws" PANELNOW 'regionsdrawn=0 ' q3evrpanel
zone_assert "...and nothing is carved, because nothing is drawn" PANELNOW \
  'exclcount=0 ' q3evrpanel
say 'q3evrhud on'; sleep 3
zone_assert "HUD On: back to 3 drawn, 4 excluded (the 3 bands plus the crosshair box)" PANELNOW \
  'regionsdrawn=3 .*exclcount=4' q3evrpanel
# R2.3 fix 1, the headline of this section: the flat crosshair is not drawn
# ANYWHERE in a VR world frame. It is not a quad any more, it is a hole.
zone_assert "the engine's 2D crosshair is drawn on no quad at all" PANELNOW \
  'xhairdrawn2d=0' q3evrpanel

# --- 4b-xix-b. the weapon-select block lands on ONE quad (R4.2 item 1) ------
# the maintainer's 1.0.4.14 device screenshot: during a weapon switch "Machinegun"
# appeared TWICE — an almost-intact copy up on the centred fallback quad and a
# clipped remnant of it far below, in the statusbar band, with the weapon icons
# below that. One boundary, the same class as R3.2's: CG_DrawWeaponSelect draws
# the icon row at y=380 and the selected weapon's NAME at y-22 = row 358, in
# BIGCHARs 16 rows tall, so the name spans 358..374 and the band's old top edge
# at 372 ran straight through it.
#
# The property to assert is CONTAINMENT, not a pixel: every row of every
# weapon-select element must be on ONE side of the boundary. The rows come from
# baseq3's own draw code (the table lives with Q3E_VR_HUD_STATUS_TOP), the
# boundary comes from the live loop's own PANELNOW, and the predicate is
# self-tested against the OLD boundary before it is trusted — 372 must come back
# RED or this assertion is proving nothing.
echo "== 4b-xix-b. the whole weapon-select block is inside the statusbar band"
contained_check () { # contained_check <label> <statustop> <elem-top> <elem-bottom>
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
label, top, lo, hi = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
# One surface means: entirely inside the band [top,480], or entirely above it.
if lo >= top:
    print(f"   PASS  {label} (rows {lo:.0f}..{hi:.0f} are inside the band [{top:.0f},480])")
    sys.exit(0)
if hi <= top:
    print(f"   PASS  {label} (rows {lo:.0f}..{hi:.0f} are entirely above the band [{top:.0f},480])")
    sys.exit(0)
print(f"   FAIL  {label}: rows {lo:.0f}..{hi:.0f} STRADDLE the band edge at {top:.0f} — "
      f"drawn twice, at two scales", file=sys.stderr)
sys.exit(1)
PYEOF
}
say 'q3evrpanel'; sleep 2
WS_TOP=$(lastline PANELNOW | grep -Eo 'statustop=[0-9]+' | sed -E 's/statustop=//')
[ -n "$WS_TOP" ] || { printf '   FAIL  no statustop in PANELNOW — nothing to check containment against\n' >&2; FAILED=1; WS_TOP=0; }
echo "   the live band's top edge: row $WS_TOP"
# The four elements baseq3 puts in this neighbourhood, in draw order.
if ! contained_check "the selected weapon's NAME (CG_DrawWeaponSelect, y-22, BIGCHAR)" "$WS_TOP" 358 374; then FAILED=1; fi
if ! contained_check "the first powerup icon (CG_DrawPowerups, ICON_SIZE*0.75)" "$WS_TOP" 368 404; then FAILED=1; fi
if ! contained_check "the weapon-select marker (CG_DrawWeaponSelect, 40px at y-4)" "$WS_TOP" 376 416; then FAILED=1; fi
if ! contained_check "the lower-right score box (CG_DrawLowerRight)" "$WS_TOP" 404 428; then FAILED=1; fi
# The self-test: the OLD boundary must come back RED for the very element the
# device round reported, and GREEN for one it never cut. Without this pair the
# containment check could be a function that always returns 0.
if contained_check "PROOF: the OLD 372 boundary cut the weapon name" 372 358 374 2>/dev/null; then
  printf '   FAIL  the containment check passed the OLD 372 boundary against the weapon name — it cannot discriminate\n' >&2
  FAILED=1
else
  printf '   PASS  confirmed: at the OLD 372 boundary the weapon name (358..374) straddles — the check discriminates\n'
fi
if contained_check "control: the score box was never cut by 372" 372 404 428 2>/dev/null >/dev/null; then
  printf '   PASS  ...and the same check still passes an element 372 did NOT cut (it is not simply always red)\n'
else
  printf '   FAIL  the containment check called the score box straddled at 372 — it fires on everything\n' >&2
  FAILED=1
fi
# Evidence for the device report: a real weapon-switch frame. WEAPON_SELECT_TIME
# is 1400 ms and a simulator screenshot takes longer than that to land, so the
# switch is re-issued while the shot is being taken rather than hoped for.
say 'give all'; sleep 2
say 'weapnext'; sleep 1
say 'weapnext'
shot 05i-weaponselect
say 'weapprev'; sleep 1

# --- 4b-xix-c. the interactive scoreboard is ONE surface (R4.2 item 2) ------
# the maintainer's 1.0.4.14 MP session: "top half of scores are small, the bottom half is
# then cut and separated from top half and is large." The scoreboard is drawn
# full-screen by the cgame, and the head-locked bands cut it — rows 356..480 land
# on the statusbar quad (about a third larger, per virtual row, than the centred
# fallback quad) while everything above stays on the fallback. Death and
# intermission were already handled by suppressing every band; the case with no
# engine-visible signal was the interactive hold-TAB one, and patch 0021 gives it
# one via the +scores/-scores commands the engine itself dispatches.
#
# His preference is explicit and is what "one surface" resolves to here: ALL
# small, i.e. the whole scoreboard on the fallback quad, so more players fit.
echo "== 4b-xix-c. a held scoreboard suppresses the bands, in both HUD states"
say 'q3evrhud on'; sleep 2
zone_assert "before: the ordinary HUD, three bands drawn, no scoreboard" PANELNOW \
  'regionsdrawn=3 .*scoreboardup=0 scoreshold=0 ' q3evrpanel
say '+scores'; sleep 2
zone_assert "+scores is seen by the engine and raises the scoreboard" PANELNOW \
  'scoreboardup=1 scoreshold=1 ' q3evrpanel
zone_assert "...and NO band draws, so the whole scoreboard is on one quad" PANELNOW \
  'regionsdrawn=0 .*scoreboardup=1 ' q3evrpanel
shot 05i-scoreboard-held
# The band geometry is not merely unplaced, it is UNSET for the frame — the loop
# clears these at the top and only the region block writes them, so a nonzero
# value here would mean a band was sized after all.
zone_assert "...and the statusbar band was never sized this frame" PANELNOW \
  'statusrows=0 statustop=0 ' q3evrpanel
# HUD Off is the other half of "in both HUD states": Off draws no bands anyway,
# but it must still draw the fallback quad, or the scoreboard would be invisible.
say 'q3evrhud off'; sleep 3
zone_assert "HUD Off + held scoreboard: still one surface, still drawn" PANELNOW \
  'regionsdrawn=0 .*scoreboardup=1 ' q3evrpanel
shot 05i-scoreboard-held-hudoff
pixels "the scoreboard quad has content with the HUD off" \
  "$PFX-05i-scoreboard-held-hudoff.png" nonblack --regionpct 30,20,70,80 --min 20000
say 'q3evrhud on'; sleep 3
# The release, and the fade margin: the hold is held ~350 ms past -scores because
# the cgame fades the scoreboard out over 200 ms, and dropping the bands back in
# during that fade is the same tear, briefer.
say '-scores'; sleep 3
zone_assert "-scores lowers it again and the bands come back" PANELNOW \
  'regionsdrawn=3 .*scoreboardup=0 scoreshold=0 ' q3evrpanel
# FAULT INJECTION. `q3evrscorehold 0` is exactly the R4.1 behaviour: the hold is
# ignored, only death and intermission raise the scoreboard, and a held
# scoreboard is therefore torn across the bands. This is the red case the
# assertions above are asserting the absence of — it is what the device saw.
echo "== 4b-xix-c-i. PROOF: with the hold ignored, the scoreboard is torn again"
say 'q3evrscorehold 0'; sleep 2
say '+scores'; sleep 2
zone_assert "hold ignored: the engine does not see the scoreboard" PANELNOW \
  'scoreboardup=0 scoreshold=0 scoreholdhook=0 ' q3evrpanel
zone_assert "...so the bands stay up and cut it — the 1.0.4.14 device symptom" PANELNOW \
  'regionsdrawn=3 .*statusrows=124 statustop=356 ' q3evrpanel
shot 05i-scoreboard-torn-RED
say '-scores'; sleep 2
say 'q3evrscorehold 1'; sleep 2
zone_assert "the hook goes back on, and the ordinary HUD is unchanged by all this" PANELNOW \
  'regionsdrawn=3 .*scoreboardup=0 scoreshold=0 scoreholdhook=1 ' q3evrpanel

# --- 4b-xx. the crosshair region quad is independently scaled (item 4) -----
# The simulator's OWN "Playing in VR" system ornament sits dead centre of
# every screenshot taken in this environment (confirmed: identical pixels at
# 0.5x and 3.0x in the centre region, which is the system dialog, not our
# crosshair) — a pixel comparison at screen centre cannot see past it here.
# What the simulator CAN prove without a device: the value actually reaches
# the renderer's stored state, via the command's own query form (no engine
# patch involved — same q3evr* seam every other tunable in this family uses).
echo "== 4b-xx. VR crosshair size is independently tunable (R2 item 4)"
# R3.1 item 1: the range is 0.5..1.5 now — the 1.0.4.6 device round found 1.5
# too big and settled on 0.5, so 0.5 is the default and 1.5 is the ceiling. The
# old 3.0 is therefore an OUT-OF-RANGE input, which is the more useful probe:
# it has to come back clamped at the new ceiling rather than accepted.
say 'q3evrxhairsize 0.5'; sleep 2
XS_SMALL=$(ask 'q3evrxhairsize' | grep -Eo 'current: [0-9.]+x' | head -1)
say 'q3evrxhairsize 1.5'; sleep 2
XS_LARGE=$(ask 'q3evrxhairsize' | grep -Eo 'current: [0-9.]+x' | head -1)
say 'q3evrxhairsize 3.0'; sleep 2          # the OLD ceiling, now above the range
XS_OVER=$(ask 'q3evrxhairsize' | grep -Eo 'current: [0-9.]+x' | head -1)
echo "   q3evrxhairsize: 0.5 -> '$XS_SMALL', 1.5 -> '$XS_LARGE', 3.0 -> '$XS_OVER'"
if [ "$XS_SMALL" = "current: 0.50x" ] && [ "$XS_LARGE" = "current: 1.50x" ] &&
   [ "$XS_OVER" = "current: 1.50x" ]; then
  printf '   PASS  the crosshair scale reaches the renderer both directions and clamps at 1.5\n'
else
  printf '   FAIL  q3evrxhairsize did not round-trip/clamp (0.5 -> %s, 1.5 -> %s, 3.0 -> %s)\n' \
         "${XS_SMALL:-none}" "${XS_LARGE:-none}" "${XS_OVER:-none}" >&2
  FAILED=1
fi
say 'q3evrxhairsize 0.75'; sleep 2  # restore the shipped default (R3.4)

# --- 4b-xx-a. HUD Size and HUD Height are two controls (R3.2 item 2) -------
# R2.3 shipped ONE multiplier over every angle the head-locked layer places;
# R3.1 split it into an extent and a spread; R3.2 replaced the spread with a
# POSITION, because that is what the device round was reaching for when it moved
# it. So the pair to check is a multiplier and an angle: both have to reach the
# renderer, both have to clamp at their own limits, and moving one must not move
# the other.
echo "== 4b-xx-a. HUD Size and HUD Height reach the renderer independently"
say 'q3evrhudsize 2.0'; sleep 2
HS_BIG=$(ask 'q3evrhudsize' | grep -Eo 'current: [0-9.]+x' | head -1)
HH_UNMOVED=$(ask 'q3evrhudheight' | grep -Eo 'current: [+-][0-9.]+deg' | head -1)
say 'q3evrhudsize 0.1'; sleep 2           # below the 0.8x floor
HS_CLAMPED=$(ask 'q3evrhudsize' | grep -Eo 'current: [0-9.]+x' | head -1)
say 'q3evrhudsize 1.25'; sleep 2          # a known value, not the 1.10 default
say 'q3evrhudheight 8'; sleep 2
HH_UP=$(ask 'q3evrhudheight' | grep -Eo 'current: [+-][0-9.]+deg' | head -1)
HS_UNMOVED=$(ask 'q3evrhudsize' | grep -Eo 'current: [0-9.]+x' | head -1)
say 'q3evrhudheight -99'; sleep 2         # below the -15 degree floor
HH_CLAMPED=$(ask 'q3evrhudheight' | grep -Eo 'current: [+-][0-9.]+deg' | head -1)
echo "   q3evrhudsize: 2.0 -> '$HS_BIG', 0.1 -> '$HS_CLAMPED' (height stayed '$HH_UNMOVED')"
echo "   q3evrhudheight: 8 -> '$HH_UP', -99 -> '$HH_CLAMPED' (size stayed '$HS_UNMOVED')"
if [ "$HS_BIG" = "current: 2.00x" ] && [ "$HS_CLAMPED" = "current: 0.80x" ] &&
   [ "$HH_UP" = "current: +8.0deg" ] && [ "$HH_CLAMPED" = "current: -15.0deg" ] &&
   [ "$HH_UNMOVED" = "current: +0.0deg" ] && [ "$HS_UNMOVED" = "current: 1.25x" ]; then
  printf '   PASS  both reach the renderer, clamp at their own limits, and do not move each other\n'
else
  printf '   FAIL  the size/height pair did not hold (size 2.0 -> %s, 0.1 -> %s; height 8 -> %s, -99 -> %s; crosstalk %s / %s)\n' \
         "${HS_BIG:-none}" "${HS_CLAMPED:-none}" "${HH_UP:-none}" "${HH_CLAMPED:-none}" \
         "${HH_UNMOVED:-none}" "${HS_UNMOVED:-none}" >&2
  FAILED=1
fi
say 'q3evrhudheight 0'; sleep 2             # a known value (the default is -2)
zone_assert "the placement layer reports both values it is actually using" PANELNOW \
  'hudsize=1.25x hudheight=\+0.0deg' q3evrpanel

# --- 4b-xx-b. the world-space aim marker (R2.3 fix 2) ----------------------
# The flat crosshair is gone from every quad (asserted above); what replaces it
# is a marker drawn in the WORLD, at the distance the aim ray reaches, at a
# constant angular size.
#
# THIS SECTION READS THE SCREEN, and it has to. The donor port shipped a VR
# reticle for three rounds whose diagnostics were all perfectly correct — world
# position, vertex count, on-screen NDC, pixel size — while it put ZERO pixels
# on the display, first because it sampled a transparent texel and then because
# half its quads were back-face culled. Neither failure is visible in any number
# this engine could print about itself. So the numbers are asserted first, and
# then the pixels are counted.
#
# Getting the marker somewhere a screenshot can see it takes one trick: the
# simulator's own "Playing in VR" system ornament sits dead centre of every
# capture taken here, and the marker's whole job is to be dead centre. Turning
# the head-aim hook OFF (the fault-injection switch that already exists) and
# pitching the synthetic head DOWN decouples the two — the game keeps aiming
# level, the eye looks down, and the marker rides up the screen clear of the
# ornament. 14 degrees of pitch puts it at NDC y = tan(14 deg)/0.562 = 0.444,
# i.e. 27.8% down a frame whose vertical tangents are +/-0.562 — computed, not
# eyeballed, so the region below cannot drift out from under the assertion.
echo "== 4b-xx-b. the aim marker traces a real range AND lands on the screen"
zone_assert "the marker is live and its range is a real distance, not zero" AIMNOW \
  'marker=\(valid1,hit[01],range[1-9][0-9]*u,size0\.75x\)' q3evraim
# The order matters, and it cost this section its first run. The game's aim
# pitch is whatever an earlier case left it at (-35 degrees, from the tangent
# probes), and freezing the hook does not change that — so the marker's offset
# from the eye is the DIFFERENCE between the two, not the pose that was just
# injected. Level the head with the hook still ON (which drags the game's aim
# level with it), THEN freeze, THEN pitch: now the offset is exactly the pose,
# by construction, whatever ran before this.
say 'q3evrheadaim 1'; sleep 2
say 'q3evrpose 0 0 0 0 0'; sleep 3
zone_assert "the game's own aim is level before the hook is frozen" AIMNOW \
  'eff=\(p-?0\.00\)' q3evraim
say 'q3evrheadaim 0'; sleep 2
say 'q3evrpose 0 -14 0 0 0'; sleep 3
zone_assert "the head is pitched away from the aim, so the marker clears the ornament" HEADNOW \
  'synth=1 .*pitch=-14\.0deg' q3evrhead
zone_assert "...and the aim itself did NOT follow it down" AIMNOW \
  'eff=\(p-?0\.00\).*hookenabled=0' q3evraim
# R3.1 item 1: the ceiling is 1.5 now, so the differential is 1.5 against 0.5.
# The marker's arms are angular, so its AREA goes as the square of the setting:
# a 3x change in the number is a 9x change in pixels, which is still far more
# than any threshold either side needs to be safe from the other.
say 'q3evrxhairsize 1.5'; sleep 3
shot 05k-marker-large
pixels "the aim marker is ON THE SCREEN, where the geometry says it must be" \
  "$PFX-05k-marker-large.png" marker --regionpct 46,23,54,32 --min 100
say 'q3evrxhairsize 0.5'; sleep 3
shot 05k-marker-small
# Still present, much smaller: the size row drives an ANGULAR size, so a 3x
# change in the setting has to be a large change in area and not a change of
# nothing (a marker whose size cvar is ignored looks identical here).
pixels "...and the size setting really is what it is drawn at (0.5x is far smaller)" \
  "$PFX-05k-marker-small.png" marker --regionpct 46,23,54,32 --min 5 --max 90

# --- 4b-xx-b-ii. THE MARKER IS NOT OCCLUDABLE (R4.5) -----------------------
# the maintainer's 1.0.4.15 report: on some walls the marker simply is not there, and
# sliding the aim along the wall brings it back near the surface's edge. The
# mechanism is a mismatch between two models of the same wall. The marker is
# placed at a COLLISION trace hit, and the collision model is not the model that
# gets drawn: a curved surface is a bezier patch, its collide hull is chorded to
# SUBDIVIDE_DISTANCE (16 units, cm_patch.c) and the rendered mesh to
# r_subdivisions (1 unit). On a convex patch the hull therefore sits up to ~16
# units BEHIND the drawn surface, the trace runs on through the drawn pixels
# before it stops, and the marker lands inside the wall — where the old
# depth-TESTED shader threw it away. At the patch's edges the two models meet
# again, which is why it reappears there.
#
# That geometry is reproduced here deliberately rather than hunted for on a map:
# `q3evrxhairprobe <push> [depthtest]` puts the marker a chosen number of units
# PAST the surface the trace named, and optionally restores the depth test. Four
# frames, one variable moving at a time:
#
#   push 0,  depthtest 1  — the old build on a FLAT wall: visible
#   push 60, depthtest 1  — the old build on a CURVED wall: GONE (the bug)
#   push 60, depthtest 0  — the shipped fix, same aim, same push: visible
#   push 0,  depthtest 0  — shipped, restored
#
# The second frame is what makes the third mean anything: the only difference
# between them is the depth test, so a marker that survives the third has
# survived the exact condition that hides it in the second.
#
# The aim has to be at a SURFACE for any of this to be a test, so the aim is
# pitched 25 degrees down with the hook still on (which drags the game's aim
# with it, into the floor a few dozen units ahead), and only then frozen and the
# eye brought back up to 11 — the marker ends up 14 degrees BELOW the view centre, clear of the simulator's own centred
# "Playing in VR" ornament, at tan(14deg)/0.562 = 0.444 of the half-height, i.e.
# 72.2% down the frame.
#
# THE THRESHOLDS, measured 2026-08-20 on the first end-to-end run this case ever
# got (they were written unrun in R4.5 and were wrong). Two
# things the original numbers did not know:
#   * the region is not dark. The simulator's own "3D / Exit VR / gear" ornament
#     bar sits just above the marker in WHITE, and q3dm1's lit floor speckles
#     near-white too, so `marker` finds ~450-1500 pixels in this region with the
#     marker absent — a `--max 10` on the raw count can never pass, and a
#     `--min 100` on it passes with nothing drawn. Both were vacuous.
#   * the honest statistic is the BUSIEST 64x64 CELL: the marker is a compact
#     cross, the contamination is thin and spread. Region 47,72,53,78 clears the
#     ornament bar and holds the marker in ONE cell for all four frames.
# Measured peaks in that cell, same frozen pose, only the probe changing:
#   flat/depth-tested 235 | pushed 60u behind, depth-tested 82 | fix 290 | shipped 235
# so 82 vs 235 is the differential, and the bounds sit either side of it with
# ~60 counts of margin each way.
MARKERBOX="--regionpct 47,72,53,78"
echo "== 4b-xx-b-ii. the aim marker survives being driven behind the surface it names"
say 'q3evrxhairsize 1.5'; sleep 2
say 'q3evrheadaim 1'; sleep 2
say 'q3evrpose 0 -25 0 0 0'; sleep 3
zone_assert "the aim is at a real surface, so pushing past it means something" AIMNOW \
  'marker=\(valid1,hit1,range[1-9][0-9]*u' q3evraim
say 'q3evrheadaim 0'; sleep 2
say 'q3evrpose 0 -11 0 0 0'; sleep 3
zone_assert "the eye is above the aim, so the marker rides clear of the ornament" AIMNOW \
  'hookenabled=0' q3evraim

say 'q3evrxhairprobe 0 1'; sleep 3
zone_assert "the probe reaches the renderer: no push, depth test restored" AIMNOW \
  'probe=\(push0u,depthtest1\)' q3evraim
shot 05m-marker-depthtest-flat
pixels "depth-TESTED and sitting ON the surface, the marker draws (the flat-wall case)" \
  "$PFX-05m-marker-depthtest-flat.png" marker $MARKERBOX --mincell 160

say 'q3evrxhairprobe 60 1'; sleep 3
zone_assert "...now driven 60 units past that surface, still depth-tested" AIMNOW \
  'probe=\(push60u,depthtest1\)' q3evraim
shot 05m-marker-depthtest-behind
pixels "THE BUG, reproduced: behind the surface and depth-tested, the marker is GONE" \
  "$PFX-05m-marker-depthtest-behind.png" marker $MARKERBOX --maxcell 140

say 'q3evrxhairprobe 60 0'; sleep 3
zone_assert "...same 60-unit push, the shipped shader" AIMNOW \
  'probe=\(push60u,depthtest0\)' q3evraim
shot 05m-marker-unoccluded
pixels "THE FIX: the same marker at the same aim, drawn through the wall" \
  "$PFX-05m-marker-unoccluded.png" marker $MARKERBOX --mincell 160

# ...and the marker is still a WORLD object with real depth, not a flat overlay:
# the range it reports is the trace's, unchanged by any of the above.
say 'q3evrxhairprobe 0 0'; sleep 3
zone_assert "the probe is back at the shipped 0/0, and the range is still the trace's" AIMNOW \
  'marker=\(valid1,hit1,range[1-9][0-9]*u,size1\.50x\) probe=\(push0u,depthtest0\)' q3evraim
shot 05m-marker-shipped
pixels "...and the shipped state draws it" \
  "$PFX-05m-marker-shipped.png" marker $MARKERBOX --mincell 160

say 'q3evrxhairsize 0.75'; sleep 2     # the shipped default (R3.4)
say 'q3evrpose off'; sleep 2
say 'q3evrheadaim 1'; sleep 3
shot 05j-xhair-large
pixels "the world still renders past the ornament while VR crosshair size was exercised" \
  "$PFX-05j-xhair-large.png" nonblack --min 20000

# --- 4b-xx-a. the crosshair SOURCE box now follows cg_crosshairSize/X/Y (fix 7)
# Before this fix the source box was a fixed 288,208,64x64 rect centred on
# Q3's own default crosshair position, blind to a mod (or the stock
# pickup-pulse) drawing somewhere else or bigger. Set the cvars to something
# far from the stock default and require the published box centre/half-size
# to move with them.
echo "== 4b-xx-a. the crosshair SOURCE box follows the actual cg_crosshairSize/X/Y cvars"
say 'seta cg_crosshairSize 24'; sleep 1
say 'seta cg_crosshairX 0'; sleep 1
say 'seta cg_crosshairY 0'; sleep 1
say 'q3evrpanel'; sleep 2
BOX0=$(lastline PANELNOW | grep -Eo 'xhairbox=\([^)]*\)')
say 'seta cg_crosshairSize 60'; sleep 1
say 'seta cg_crosshairX 40'; sleep 1
say 'seta cg_crosshairY -25'; sleep 1
say 'q3evrpanel'; sleep 2
BOX1=$(lastline PANELNOW | grep -Eo 'xhairbox=\([^)]*\)')
echo "   xhairbox at stock cvars: $BOX0   at cg_crosshairSize=60,X=40,Y=-25: $BOX1"
CX1=$(printf '%s' "$BOX1" | sed -E 's/.*cx(-?[0-9]+).*/\1/')
CY1=$(printf '%s' "$BOX1" | sed -E 's/.*cy(-?[0-9]+).*/\1/')
HALF1=$(printf '%s' "$BOX1" | sed -E 's/.*half(-?[0-9]+).*/\1/')
if [ -n "$BOX0" ] && [ "$BOX0" != "$BOX1" ] && [ "${CX1:-0}" -gt 340 ] && \
   [ "${CY1:-0}" -lt 220 ] && [ "${HALF1:-0}" -gt 100 ]; then
  printf '   PASS  the source box centre and half-size follow the crosshair cvars (cx=%s cy=%s half=%s)\n' \
         "$CX1" "$CY1" "$HALF1"
else
  printf '   FAIL  the crosshair source box did not follow cg_crosshairSize/X/Y (%s -> %s)\n' \
         "${BOX0:-none}" "${BOX1:-none}" >&2
  FAILED=1
fi

# --- 4b-xx-a-ii. ...and it never leaves the 640x480 canvas (R2.2 fix 14a) ---
# The values below are LEGAL: 128 is this code's own accepted ceiling for
# cg_crosshairSize and cg_crosshairX/Y are free-form offsets. Unclamped they
# ask for a 264 px half-box centred at (620,240) — off the right edge by 244 px
# and off the top by 24 — and a UV rect outside [0,1] does not sample nothing:
# a clamp-to-edge sampler smears the texture's border rows and columns across
# the quad at the exact centre of the player's gaze, and hands the same
# out-of-range rect to the fallback exclusion mask. The box must come back
# inside the canvas on all four sides, and still be a real box (half >= 4).
say 'seta cg_crosshairSize 128'; sleep 1
say 'seta cg_crosshairX 300'; sleep 1
say 'seta cg_crosshairY 0'; sleep 1
say 'q3evrpanel'; sleep 2
BOX2=$(lastline PANELNOW | grep -Eo 'xhairbox=\([^)]*\)')
CX2=$(printf '%s' "$BOX2" | sed -E 's/.*cx(-?[0-9]+).*/\1/')
CY2=$(printf '%s' "$BOX2" | sed -E 's/.*cy(-?[0-9]+).*/\1/')
HALF2=$(printf '%s' "$BOX2" | sed -E 's/.*half(-?[0-9]+).*/\1/')
echo "   xhairbox at cg_crosshairSize=128,X=300: $BOX2"
if [ -n "$BOX2" ] && [ "${HALF2:-0}" -ge 4 ] && \
   [ $(( CX2 - HALF2 )) -ge 0 ] && [ $(( CX2 + HALF2 )) -le 640 ] && \
   [ $(( CY2 - HALF2 )) -ge 0 ] && [ $(( CY2 + HALF2 )) -le 480 ]; then
  printf '   PASS  the source box stays inside the 640x480 canvas (x %s..%s, y %s..%s)\n' \
         "$(( CX2 - HALF2 ))" "$(( CX2 + HALF2 ))" "$(( CY2 - HALF2 ))" "$(( CY2 + HALF2 ))"
else
  printf '   FAIL  legal crosshair cvars pushed the source box off the canvas: %s\n' "${BOX2:-none}" >&2
  FAILED=1
fi
say 'seta cg_crosshairSize 24'; sleep 1
say 'seta cg_crosshairX 0'; sleep 1
say 'seta cg_crosshairY 0'; sleep 1

# --- 4b-xx-b. the HUD/message/notify bands never overlap (R2.1 fix 10) ------
# The device round found a ~3.5-degree shared band between the statusbar's old
# High position and the message band (14 vs 12 degrees), so the bands' angular
# extents are checked against BOTH neighbours here rather than only the one pair
# the device report named.
#
# R3.2 changes what has to be checked, and makes it a smaller claim rather than
# a bigger one: there is no High/Low any more, and HUD Height translates all
# three bands by the SAME number of degrees, so their relative layout — and
# therefore whether any two of them overlap — cannot depend on the slider at all.
# One configuration to check, and the invariance is the reason why.
echo "== 4b-xx-b. the statusbar, message and notify bands never overlap"
overlap_check () { # overlap_check <label> <pitch1> <halfH1> <pitch2> <halfH2>
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import sys
label, p1, h1, p2, h2 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
lo1, hi1 = p1 - h1, p1 + h1
lo2, hi2 = p2 - h2, p2 + h2
gap = max(lo1, lo2) - min(hi1, hi2)
if gap >= 0:
    print(f"   PASS  {label} (span1=[{lo1:.2f},{hi1:.2f}] span2=[{lo2:.2f},{hi2:.2f}] gap={gap:.2f}deg)")
    sys.exit(0)
else:
    print(f"   FAIL  {label} OVERLAPS by {-gap:.2f}deg (span1=[{lo1:.2f},{hi1:.2f}] span2=[{lo2:.2f},{hi2:.2f}])", file=sys.stderr)
    sys.exit(1)
PYEOF
}
# Half-heights and anchors, degrees, derived the same way the render loop derives
# them (half-extent halfW*rows/640 metres at dist=1.75m, converted through the
# plane) from the shipped box sizes at the default HUD Size of 1.25: statusbar
# 124 rows over a 25*1.25-degree halfW box (R4.2 item 1 grew it from 108 —
# the band still has to clear its neighbour, and by MORE than it used to need
# to, which is exactly what this check is for), message 164 rows over 18*1.25,
# notify 80 rows over 15*1.25. The message and notify anchors carry the layout's
# fixed spread (Q3E_VR_HUD_SPREAD 1.25); the statusbar's is derived from its
# BOTTOM edge at -23.65 degrees, which is where the 1.0.4.7 band's bottom sat.
halfh () { python3 -c "import math,sys; hw=1.75*math.tan(math.radians(float(sys.argv[1])*1.25)); print(math.degrees(math.atan(hw*float(sys.argv[2])/640/1.75)))" "$1" "$2"; }
STATUSBAR_HALFH=$(halfh 25 124)
MESSAGE_HALFH=$(halfh 18 164)
NOTIFY_HALFH=$(halfh 15 80)
# The statusbar's centre, from its bottom edge and its own half-height — the same
# statement Q3EVR.m's q3e_vr_band_pitch makes.
STATUSBAR_PITCH=$(python3 -c "import math,sys; hw=1.75*math.tan(math.radians(25*1.25)); hh=hw*124/640; print(math.degrees(math.atan((1.75*math.tan(math.radians(-23.65))+hh)/1.75)))")
echo "   half-heights (deg): statusbar=$STATUSBAR_HALFH message=$MESSAGE_HALFH notify=$NOTIFY_HALFH"
echo "   statusbar anchor (deg, from its bottom edge): $STATUSBAR_PITCH"
# The live loop's own number for the same thing, so this arithmetic and the
# shipped geometry cannot drift apart silently.
say 'q3evrpanel'; sleep 2
SB_LIVE=$(lastline PANELNOW | grep -Eo 'statuspitch=[+-][0-9.]+deg' | sed -E 's/statuspitch=([+-][0-9.]+)deg/\1/')
if python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<0.05 else 1)" \
     "${SB_LIVE:-999}" "$STATUSBAR_PITCH"; then
  printf '   PASS  the render loop publishes the same statusbar anchor this check computes (%s)\n' "$SB_LIVE"
else
  printf '   FAIL  the loop says statuspitch=%s but the check computes %s\n' \
         "${SB_LIVE:-none}" "$STATUSBAR_PITCH" >&2
  FAILED=1
fi
if ! overlap_check "statusbar vs message (11.25deg)" "$STATUSBAR_PITCH" "$STATUSBAR_HALFH" 11.25 "$MESSAGE_HALFH"; then FAILED=1; fi
if ! overlap_check "statusbar vs notify (22.5deg)" "$STATUSBAR_PITCH" "$STATUSBAR_HALFH" 22.5 "$NOTIFY_HALFH"; then FAILED=1; fi
if ! overlap_check "message (11.25deg) vs notify (22.5deg)" 11.25 "$MESSAGE_HALFH" 22.5 "$NOTIFY_HALFH"; then FAILED=1; fi
# Prove the checker itself can fail: the OLD anchors (statusbar High=14,
# message=12) really did overlap, by the same math.
if overlap_check "PROOF: the OLD anchors (High=14, message=12) really did overlap" 14 "$STATUSBAR_HALFH" 12 "$MESSAGE_HALFH" 2>/dev/null; then
  printf '   FAIL  the overlap checker did not catch the OLD (pre-fix) anchors overlapping — it cannot discriminate\n' >&2
  FAILED=1
else
  printf '   PASS  confirmed: the OLD anchors (14/12 degrees) DO overlap by this same math — the checker discriminates\n'
fi

# --- 4b-xx-c. a missing fallback pipeline degrades, never goes dark (fix 11)
# `q3evruifallbackkill 1` simulates the fallback/scoreboard pipeline failing
# to build, without actually breaking the shader. The dedicated region quads
# keep drawing regardless (uiReady only ever required the region pipeline);
# what this proves is that the FALLBACK content — which a mod's custom HUD
# element or the scoreboard depends on — still shows through the degrade path
# (the whole texture via the region pipeline) instead of silently vanishing
# while uiquad=1 stays green.
echo "== 4b-xx-c. a missing fallback pipeline degrades to content, not to nothing"
say 'q3evruifallbackkill 0'; sleep 2
shot 05k-fallback-normal
say 'q3evruifallbackkill 1'; sleep 3
zone_assert "uiquad stays green even with the fallback pipeline killed" PANELNOW \
  'uiquad=1' q3evrpanel
shot 05k-fallback-killed
pixels "content still renders with the fallback pipeline killed (degrade path)" \
  "$PFX-05k-fallback-killed.png" nonblack --min 20000
say 'q3evruifallbackkill 0'; sleep 3
zone_assert "restores cleanly" PANELNOW 'uiquad=1' q3evrpanel

# --- 4b-xvi. a respawn does not open the head-aim delta (R2 item 1c) -------
# Deliberately LAST among the position-sensitive R2 cases: `kill` moves the
# player through a death/respawn transition (Q3's own death-cam briefly shows
# the scoreboard over the OLD position before the new spawn point settles),
# which would otherwise contaminate the sky/region/crosshair checks above —
# those need a STABLE pose, this one is testing exactly the opposite.
echo "== 4b-xvi. a respawn does not open the head-aim delta"
zone_assert "identity holds before the kill" AIMNOW \
  'active=1 .*delta=-?0\.0000deg' q3evraim
say 'kill'; sleep 6
zone_assert "identity still holds immediately after a respawn" AIMNOW \
  'active=1 .*delta=-?0\.0000deg' q3evraim

# --- 4b-xvi-a. what the frame looks like while the player is DEAD -----------
# R2.2 fixes 14b and 6, on the frame class fix 7 made reachable for the first
# time. With the death overlay up the 2D layer stops being carved into region
# quads and goes onto the fallback quad whole — so the region telemetry must
# read as a frame that drew no regions, in EVERY field. It used to publish
# regionsdrawn=0 next to the last HUD frame's notifyrows=80 / messagerows=164 /
# crosshair box, which is a dump that contradicts itself and, worse, a dump the
# row assertions above could have passed on a frame where the row sizing code
# never ran. The exclusion count is asserted for its own reason: this is the
# frame class that used to reach Metal with a zero-length exclusion-buffer bind
# (fix 6), so this is the line that proves the suite actually visits it. R2.3
# fix 1 makes that count 1 rather than 0 — the crosshair box is carved out of
# the fallback quad even here, where no region drew, because the flat crosshair
# must never be visible in a world frame whatever else is on screen.
#
# The death is made FRESH rather than inherited from the case above: Q3 holds
# the death-cam until a button press or g_forcerespawn seconds, so a death that
# is already most of a minute old may or may not still be one by the time this
# runs. `+attack` takes any pending respawn (and is harmless while alive — it
# fires the gun), then the kill is this case's own.
say '+attack'; sleep 1
say '-attack'; sleep 4
say 'kill'; sleep 3
zone_assert "the death overlay is up (gate: nothing below means anything otherwise)" \
  PANELNOW 'scoreboardup=1' q3evrpanel
zone_assert "...so no region quads drew and NO region telemetry is left over" PANELNOW \
  'regionsdrawn=0 exclcount=1 scoreboardup=1 scoreshold=0 scoreholdhook=1 notifyrows=0 messagerows=0' \
  q3evrpanel

# --- 4b-xvi-b. the aim identity across a respawn taken while PITCHED --------
# R2.2 fix 3, the finding 4b-xvi was blind to by construction. The old
# assertion compared cl.viewangles[PITCH] against the head pitch — an identity
# the code guaranteed by writing one into the other, which is why it stayed
# green through the whole defect. What the GAME aims at is the usercmd's angles
# PLUS the playerstate's delta_angles, and the server rewrites that offset on
# every respawn: die looking 35 degrees up and every shot for the rest of that
# life lands 35 degrees off the crosshair, with the render (which takes pitch
# from the eye poses alone) showing nothing wrong.
#
# The pose is held pitched THROUGH the death so the respawn's own
# SetClientViewAngle installs a real offset, and `+attack` is what actually
# takes the respawn (Q3 holds the death-cam until a button, or 20 s of
# g_forcerespawn). The offset opening at all is a hard GATE: a run where it
# stayed 0 has not tested the fix, and says so instead of passing.
echo "== 4b-xvi-b. the aim identity survives a respawn taken while pitched"
say 'q3evrpose 0 35 0 1.60 0'; sleep 3
say 'kill'; sleep 3        # no-op if the case above left him dead, which it did
say '+attack'; sleep 1     # ...and THIS is the respawn, taken while pitched up
say '-attack'; sleep 6
zone_assert "the respawn really did install a pitch offset (gate)" AIMNOW \
  'deltapitch=-?[1-9][0-9]* ' q3evraim
zone_assert "...and the EFFECTIVE pitch the server computes still equals the head pitch" \
  AIMNOW 'active=1 .*delta=-?0\.0000deg' q3evraim
# Fault injection, in the same breath: with the compensation off the hook
# writes the head pitch absolutely again — the pre-R2.2 behaviour — and the
# identity above measurably opens by the whole offset. An assertion nobody has
# watched fail is a decoration.
say 'q3evrpitchcomp 0'; sleep 3
zone_assert "PROOF: with the compensation off, the same identity opens" AIMNOW \
  'pitchcomp=0' q3evraim
zone_assert "...by a whole degree or more (not a rounding wobble)" AIMNOW \
  'delta=-?[1-9][0-9]*\.[0-9]+deg' q3evraim
say 'q3evrpitchcomp 1'; sleep 3
zone_assert "restoring the compensation closes it again" AIMNOW \
  'active=1 .*delta=-?0\.0000deg .*pitchcomp=1' q3evraim
say 'q3evrpose 0 0 0 1.60 0'; sleep 3

# ===========================================================================
# R3 — HANDS. Everything below runs on INJECTED hands (`q3evrhand`), which enter
# at Q3E_Sense_Poll's OUTPUT: the same boundary a real ARKit anchor lands on, in
# the same tracking space. So the base-frame transform, the aim arbitration, the
# delta-compensated viewangle write, the movement basis, the viewmodel re-base
# and the input consumer are all the shipping code, not a parallel one. The
# simulator has no controllers at all, which is exactly why this exists.
#
# What it CANNOT prove, and what therefore goes on the human checklist: pairing,
# chirality from real hardware, whether the grip defaults put the gun in the
# fist, and whether any of it feels right.
# ===========================================================================

# --- 4b-xxiii. the SpatialGamepad declaration survived into the BUILT product
# The one hardware claim a controllerless simulator CAN answer. Without this key
# the pair enumerates as a single aggregate MFi gamepad and accessory loading
# fails with error 1200 — the failure whose symptom is "the controllers work but
# nothing is ever tracked", which is the most expensive one to debug on glass.
# The backend logs both keys at START, not only on a connect, for this reason.
echo "== 4b-xxiii. the Sense plist declarations are in the built product"
snap r3-plist
need "$BB" "the Sense backend started at all" 'SENSE backend ready'
need "$BB" "GCSupportedGameControllers carries SpatialGamepad" \
  'SENSE backend ready.*GCSupportedGameControllers = .*SpatialGamepad'
need "$BB" "NSAccessoryTrackingUsageDescription is present" \
  'SENSE bundle NSAccessoryTrackingUsageDescription = [A-Za-z]'

# --- 4b-xxiv. an injected hand takes the aim -------------------------------
# The head is held DEAD LEVEL at yaw 0 throughout, so a sent yaw of 60 degrees
# can only have come from the hand. That is the whole discrimination: the R2
# identity (sent == body + aim) holds trivially whichever source `aim` is, and a
# build where the hand never reached cl.viewangles would keep it green.
echo "== 4b-xxiv. a tracked hand owns the aim, and the identity survives it"
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
say 'q3evrhandaim 1'; sleep 1
say 'q3evrhand r 60 -20 0 0.20 1.20 -0.30'; sleep 3
zone_assert "HANDNOW reports the right hand tracked and aiming" HANDNOW \
  'tracked=2 .*aim=\(src=hand,' q3evrhandnow
zone_assert "the aim identity still holds with a HAND driving it" AIMNOW \
  'aimsrc=hand .*active=1 .*delta=-?0\.0000deg' q3evraim
HANDYAW=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
if [ -n "$HANDYAW" ] && awk "BEGIN{v=$HANDYAW; if (v>180) v-=360; if (v<0) v=-v; exit !(v > 40)}"; then
  printf '   PASS  the sent yaw followed the HAND (%s deg) while the head sat at 0\n' "$HANDYAW"
else
  printf '   FAIL  the sent yaw did not follow the injected hand (sent=%s, head yaw 0)\n' "${HANDYAW:-none}" >&2
  FAILED=1
fi

# --- 4b-xxiv-a. PROOF: with hand aim disabled the head takes it back --------
# An assertion nobody has watched fail is a decoration. `q3evrhandaim 0` makes
# the arbitration always answer HEAD, with the injected hand still tracked and
# still pointing 60 degrees away — so the sent yaw must collapse back to the
# head's 0 and the reported source must change with it.
echo "== 4b-xxiv-a. PROOF: q3evrhandaim 0 hands the aim back to the head"
say 'q3evrhandaim 0'; sleep 3
zone_assert "the source really did change back" AIMNOW 'aimsrc=head .*handaim=0' q3evraim
HEADYAW=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
if [ -n "$HEADYAW" ] && [ -n "$HANDYAW" ] && \
   awk "BEGIN{d=$HANDYAW-$HEADYAW; if (d<0) d=-d; if (d>180) d=360-d; exit !(d > 40)}"; then
  printf '   PASS  disabling hand aim moved the sent yaw by %s -> %s deg — the hand WAS driving it\n' \
    "$HANDYAW" "$HEADYAW"
else
  printf '   FAIL  disabling hand aim changed nothing (%s -> %s): the assertion above cannot fail\n' \
    "${HANDYAW:-none}" "${HEADYAW:-none}" >&2
  FAILED=1
fi
say 'q3evrhandaim 1'; sleep 2
zone_assert "...and re-enabling it gives the hand the aim back" AIMNOW \
  'aimsrc=hand .*delta=-?0\.0000deg .*handaim=1' q3evraim

# --- 4b-xxv. the world-space marker follows the HAND ray -------------------
# The marker was built (R2.3) against the head ray and reads the EFFECTIVE aim
# rather than any particular source, so it should follow the hand for free. That
# is a claim, and this is what makes it a measurement: point the hand steeply
# down and then level, and require the traced range to actually move.
echo "== 4b-xxv. the aim marker traces the HAND's ray, not the head's"
say 'q3evrhand r 0 -75 0 0.20 1.20 -0.30'; sleep 3
say 'q3evraim'; sleep 2
RDOWN=$(lastline AIMNOW | sed -E 's/.*range([0-9.]+)u.*/\1/')
say 'q3evrhand r 0 0 0 0.20 1.20 -0.30'; sleep 3
say 'q3evraim'; sleep 2
RLEVEL=$(lastline AIMNOW | sed -E 's/.*range([0-9.]+)u.*/\1/')
zone_assert "the marker is valid while a hand is aiming" AIMNOW \
  'aimsrc=hand .*marker=\(valid1,' q3evraim
if [ -n "$RDOWN" ] && [ -n "$RLEVEL" ] && awk "BEGIN{exit !($RDOWN > 0 && $RLEVEL > 0)}"; then
  if awk "BEGIN{d=$RLEVEL-$RDOWN; if (d<0) d=-d; exit !(d > 16)}"; then
    printf '   PASS  the traced range moved with the hand (down %su -> level %su)\n' "$RDOWN" "$RLEVEL"
  else
    printf '   FAIL  the range did not move when the hand did (down %su, level %su) — the marker\n' "$RDOWN" "$RLEVEL" >&2
    printf '         is not reading the hand ray\n' >&2
    FAILED=1
  fi
else
  printf '   FAIL  no traced range at all (down=%s level=%s)\n' "${RDOWN:-none}" "${RLEVEL:-none}" >&2
  FAILED=1
fi

# --- 4b-xxvi. the movement basis: all three sources now MEAN something ------
# Head at yaw 0, aim hand (right) at 60, off hand (left) at -50. The aim is the
# hand, so cl_vr_view_yaw carries body+60 and MOVENOW's `delta` is
# (chosen - aim): 0 for the aim hand, about -60 for the head, about -110 for the
# off hand. Three distinct numbers no coincidence produces, and `basissrc` says
# which one actually resolved rather than which was asked for.
echo "== 4b-xxvi. Head / Aim hand / Off hand each rotate the move vector differently"
say 'q3evrhand r 60 0 0 0.20 1.20 -0.30'; sleep 2
say 'q3evrhand l -50 0 0 -0.20 1.20 -0.30'; sleep 3
say 'q3evrmovemode head'; sleep 2
zone_assert "Head basis resolves to the head..." MOVENOW 'basis=head basissrc=head ' q3evrmove
zone_assert "...and rotates the vector by about the hand-to-head difference" MOVENOW \
  'delta=-(5[0-9]|6[0-9])\.[0-9]deg' q3evrmove
say 'q3evrmovemode aimhand'; sleep 2
zone_assert "Aim hand basis resolves to the aim hand..." MOVENOW \
  'basis=aimhand basissrc=aimhand ' q3evrmove
zone_assert "...and is the identity, because movement IS where the gun points" MOVENOW \
  'delta=-?0\.0deg' q3evrmove
say 'q3evrmovemode offhand'; sleep 2
zone_assert "Off hand basis resolves to the off hand..." MOVENOW \
  'basis=offhand basissrc=offhand ' q3evrmove
zone_assert "...and rotates by the whole 110 degrees between the two hands" MOVENOW \
  'delta=-(10[0-9]|11[0-9])\.[0-9]deg' q3evrmove
# An untracked hand must FALL BACK to the head, loudly. Standing still is the
# one answer a movement setting can never give.
say 'q3evrhand l off'; sleep 3
zone_assert "an untracked off hand falls back to the head, and says so" MOVENOW \
  'basis=offhand basissrc=head\(fallback\) ' q3evrmove
say 'q3evrmovemode head'; sleep 2

# --- 4b-xxvii. the viewmodel is mounted on the hand ------------------------
# The renderer answers, from what it actually wrote: `entities` counts the
# RF_FIRST_PERSON entities it moved this scene, so a build where the re-base
# never ran reports 0 while every value that went IN still looks right.
echo "== 4b-xxvii. the first-person weapon is re-based onto the aim hand"
zone_assert "the gun is mounted, and something was actually moved" VIEWMODELNOW \
  'handvalid=\(L0,R1\) mounted=1 entities=[1-9][0-9]*' q3evrviewmodel
zone_assert "...and the depth hack stays off in VR (charter D3)" VIEWMODELNOW \
  'depthhack=off' q3evrviewmodel

# R3.5: the RESTING REAR-PLANE ANCHOR. Where a weapon's rear plane ends up is
# the sum of two per-weapon numbers — where the cgame hung the entity (its own
# hands model's `tag_weapon`, a 20.8-unit spread across baseq3) and where the
# model's geometry sits relative to that origin (mins[0], an 8.8-unit spread) —
# and the two are ANTI-CORRELATED, because the artists who placed the tags were
# already compensating. R3.4 corrected the second alone and the rear-plane
# spread went from 16.7 units to 20.7. R3.5 corrects the sum.
#
# Every number below is a prediction from the model files, so this cannot pass
# on a build that measured nothing:
#
#   machinegun  tag_weapon -6.922 + mins[0] -5.766 = -12.688, so the assembly
#               slides 12.688 x the 0.75 Weapon Size = +9.5 units FORWARD to put
#               that rear plane on the hand.
#   gauntlet    tag_weapon +10.391, and its box rotated 27 degrees by that tag
#               puts its rearmost corner at -13.42, so it rests at -3.03 and
#               needs only 3.03 x 0.75 = +2.3 units of the same slide.
#
# R3.6 moved the zero — the anchor point lands ON the hand now rather than at the
# machinegun's resting distance from it, because that point is also what Weapon
# Size pivots about — so both numbers moved by the same 9.5 and their DIFFERENCE,
# 7.2 units, is unchanged from R3.5. That difference is the whole mechanism: it
# is what the two weapons no longer disagree by.
# Two stock spawn weapons, no cheats needed to hold either.
say 'weapon 2'; sleep 3
zone_assert "the machinegun measures as the reference weapon" VIEWMODELNOW \
  'fwd=-[67]\.[0-9]u rear=-5\.8u rest=-12\.[678]u anchor=\+9\.[456]u' q3evrviewmodel
say 'weapon 1'; sleep 3
zone_assert "...and the gauntlet, resting nine units further forward, is slid nine units less" \
  VIEWMODELNOW 'fwd=10\.[0-9]u rear=-13\.[0-9]u rest=-3\.[01]u anchor=\+2\.[23]u' q3evrviewmodel

# The A/B the maintainer runs on glass, run here as this case's own fault injection: with
# the mechanism bypassed the gauntlet's slide must collapse to zero. If it does
# not, the assertion above was passing on something other than the anchor.
say 'q3evranchor 0'; sleep 3
zone_assert "q3evranchor 0 bypasses the mechanism entirely" VIEWMODELNOW \
  'rest=-3\.[01]u anchor=\+0\.0u anch=off' q3evrviewmodel
say 'q3evranchor 1'; sleep 3
zone_assert "...and q3evranchor 1 puts it back, measured the same way" VIEWMODELNOW \
  'rest=-3\.[01]u anchor=\+2\.[23]u anch=on' q3evrviewmodel
say 'weapon 2'; sleep 3

# --- 4b-xxvii-a. WEAPON SIZE PIVOTS AT THE HAND (R3.6) ----------------------
# the maintainer's report from glass: every change to Weapon Size had to be paid for with
# a Grip Right and a Grip Up correction, because the multiply happened about the
# game view's own origin — a point in his face — so a bigger gun slid out of the
# fist along the whole offset between the two. The multiply pivots about the
# ANCHOR POINT now, and this is the measurement of that claim.
#
# `pivot=` is read back off the TRANSFORMED entity — its final origin, its final
# (scale-carrying) axes and the box they belong to — not predicted from the
# inputs, so a build that scaled about the wrong point reports the wrong number.
# With the anchor on it must equal the three Grip offsets exactly, at every size.
#
# R4.0: the sizes are 0.375 and 1.875 — the row's own native ends, since the
# Weapon Size span moved with the display rescale. `q3evrgrip 5` is the
# one-argument form, so forward becomes 5 and right/up stay where the hardcoded
# set left them (-0.5, 0).
echo "== 4b-xxvii-a. Weapon Size scales the gun ABOUT the hand, not away from it"
say 'q3evrgrip 5'; sleep 2
pivot_of () { lastline VIEWMODELNOW | grep -Eo 'pivot=\(f[+-][0-9.]+,r[+-][0-9.]+,u[+-][0-9.]+\)u'; }
read_pivot () { # read_pivot <scale> -> echoes "f r u"
  say "q3evrgunscale $1"; sleep 3
  say 'q3evrviewmodel'; sleep 2
  pivot_of | sed -E 's/pivot=\(f([+-][0-9.]+),r([+-][0-9.]+),u([+-][0-9.]+)\)u/\1 \2 \3/'
}
PIV_SMALL=$(read_pivot 0.375)
PIV_BIG=$(read_pivot 1.875)
echo "   anchor point at 0.375x: [$PIV_SMALL]   at 1.875x: [$PIV_BIG]   (grip was 5,-0.5,0)"
if [ -n "$PIV_SMALL" ] && [ -n "$PIV_BIG" ] && \
   awk "BEGIN{split(\"$PIV_SMALL\",a);split(\"$PIV_BIG\",b);
              g[1]=5;g[2]=-0.5;g[3]=0; bad=0;
              for(i=1;i<=3;i++){d=a[i]-b[i]; if(d<0)d=-d; if(d>0.05)bad=1;
                                e=a[i]-g[i]; if(e<0)e=-e; if(e>0.10)bad=1;}
              exit bad}"; then
  printf '   PASS  the anchor point sat at the grip offsets (5,-0.5,0) at BOTH 0.375x and 1.875x\n'
else
  printf '   FAIL  the anchor point MOVED with Weapon Size (0.375x [%s] vs 1.875x [%s], grip 5,-0.5,0)\n' \
         "${PIV_SMALL:-none}" "${PIV_BIG:-none}" >&2
  FAILED=1
fi

# The fault injection for it, and the A/B the maintainer runs on glass: with the pivot
# bypassed the scale multiplies the whole view-relative offset again, so the same
# two sizes must put the anchor point in two very different places. An assertion
# that cannot fail is a decoration, and this is the failure it is watching for.
say 'q3evranchor 0'; sleep 2
PIV_OFF_SMALL=$(read_pivot 0.375)
PIV_OFF_BIG=$(read_pivot 1.875)
echo "   with q3evranchor 0 — 0.375x: [$PIV_OFF_SMALL]   1.875x: [$PIV_OFF_BIG]"
if [ -n "$PIV_OFF_SMALL" ] && [ -n "$PIV_OFF_BIG" ] && \
   awk "BEGIN{split(\"$PIV_OFF_SMALL\",a);split(\"$PIV_OFF_BIG\",b);
              df=a[1]-b[1]; if(df<0)df=-df; du=a[3]-b[3]; if(du<0)du=-du;
              exit !(df>5 && du>5)}"; then
  printf '   PASS  PROOF: bypassed, the same two sizes move the anchor point (forward AND up) — the check discriminates\n'
else
  printf '   FAIL  the bypass changed nothing (0.375x [%s] vs 1.875x [%s]): the case above cannot fail\n' \
         "${PIV_OFF_SMALL:-none}" "${PIV_OFF_BIG:-none}" >&2
  FAILED=1
fi
say 'q3evranchor 1'; sleep 2
say 'q3evrgunscale 0.75'; sleep 2
say 'q3evrgrip reset'; sleep 2
# R4.0: `reset` is back to the six HARDCODED values, forward included.
zone_assert "the grip is back at this round's hardcoded set" VIEWMODELNOW \
  'grip=\(f-6\.0,r-0\.5,u0\.0\)u gripang=\(p0\.0,y0\.0,r0\.0\)deg' q3evrviewmodel

say 'q3evrhand r off'; sleep 3
zone_assert "with no tracked hand the cgame's own placement stands again" VIEWMODELNOW \
  'mounted=0 entities=0' q3evrviewmodel
say 'q3evrhand r 60 0 0 0.20 1.20 -0.30'; sleep 3

# --- 4b-xxviii. ONE edge detector: a hold does not cross a context boundary --
# Charter D5's partition rule, as a number. A trigger held in gameplay must be
# RELEASED when a menu opens (or the player fires blind through the menu), must
# NOT read as a fresh press on the menu side (or opening a menu activates
# whatever the cursor is on), and must come back when the menu closes — because
# the finger never left the trigger.
echo "== 4b-xxviii. a held button does not cross the gameplay/UI boundary"
say 'q3evrhandctx 1'; sleep 1
say 'q3evrhandbtn r 0'; sleep 2
say 'q3evrhandbtn r 1'; sleep 3
zone_assert "the trigger is held in the GAMEPLAY context" HANDNOW \
  'consumer=\[ctx=play held=\(fire1,' q3evrhandnow
UIENTER_PRE=$(lastline HANDNOW | sed -E 's/.*uienter=([0-9]+).*/\1/')
say 'toggleconsole'; sleep 4
zone_assert "raising the console RELEASES it rather than firing through it" HANDNOW \
  'consumer=\[ctx=menu held=\(fire0,' q3evrhandnow
UIENTER_MID=$(lastline HANDNOW | sed -E 's/.*uienter=([0-9]+).*/\1/')
if [ "${UIENTER_MID:-0}" = "${UIENTER_PRE:-0}" ]; then
  printf '   PASS  ...and the still-held trigger did NOT read as a UI press (uienter %s)\n' "${UIENTER_PRE:-0}"
else
  printf '   FAIL  the held trigger fired a UI ENTER on the way in (uienter %s -> %s)\n' \
    "${UIENTER_PRE:-0}" "${UIENTER_MID:-0}" >&2
  FAILED=1
fi
# A GENUINE press on the UI side still works — the rebase must not deafen the
# context it just entered.
say 'q3evrhandbtn r 0'; sleep 2
say 'q3evrhandbtn r 1'; sleep 3
say 'q3evrhandnow'; sleep 2
UIENTER_POST=$(lastline HANDNOW | sed -E 's/.*uienter=([0-9]+).*/\1/')
if [ "${UIENTER_POST:-0}" -gt "${UIENTER_MID:-0}" ] 2>/dev/null; then
  printf '   PASS  a real press inside the UI context DOES emit (uienter %s -> %s)\n' \
    "${UIENTER_MID:-0}" "${UIENTER_POST:-0}"
else
  printf '   FAIL  a fresh press inside the UI context emitted nothing (uienter %s -> %s) — the\n' \
    "${UIENTER_MID:-0}" "${UIENTER_POST:-0}" >&2
  printf '         boundary rebase deafened the context it entered\n' >&2
  FAILED=1
fi

# --- 4b-xxviii-a. PROOF: the boundary rule can FAIL ------------------------
# `q3evrhandctx 0` makes the boundary do nothing at all — no release, no rebase
# — which is the sibling donor's own bug #25 reproduced deliberately. The held
# trigger then stays latched into the menu, which is exactly what the assertion
# above says cannot happen.
echo "== 4b-xxviii-a. PROOF: with the boundary handoff disabled, the hold sticks"
say 'toggleconsole'; sleep 4          # back to gameplay
say 'q3evrhandctx 0'; sleep 2
say 'q3evrhandbtn r 0'; sleep 2
say 'q3evrhandbtn r 1'; sleep 3
zone_assert "the trigger is held in gameplay again (with the handoff disabled)" HANDNOW \
  'consumer=\[ctx=play held=\(fire1,.*handoff=0' q3evrhandnow
say 'toggleconsole'; sleep 4
zone_assert "PROOF: it CROSSES into the UI context still held — the assertion discriminates" HANDNOW \
  'consumer=\[ctx=menu held=\(fire1,.*handoff=0' q3evrhandnow
say 'q3evrhandctx 1'; sleep 2
say 'toggleconsole'; sleep 4
say 'q3evrhandbtn r 0'; sleep 3
zone_assert "restoring the handoff releases it again" HANDNOW \
  'consumer=\[ctx=play held=\(fire0,.*handoff=1' q3evrhandnow

# --- 4b-xxix. release-on-doff ----------------------------------------------
# Losing the controllers (the headset coming off stops the poll that feeds them)
# must release everything they held and hand the aim back to the head. Never
# leave a doffed player firing.
echo "== 4b-xxix. doffing releases every held input and returns the aim to the head"
say 'q3evrhandbtn r 1'; sleep 3
zone_assert "the trigger is held before the doff" HANDNOW 'held=\(fire1,' q3evrhandnow
say 'q3evrhand r off'; sleep 4
zone_assert "with no hand tracked, everything held is released" HANDNOW \
  'tracked=0 .*held=\(fire0,zoom0,jump0,use0,wprev0,wnext0,crouch0,scores0,esc0\)' q3evrhandnow
zone_assert "...and the aim is the head's again, with no gap in between" AIMNOW \
  'aimsrc=head .*active=1 .*delta=-?0\.0000deg' q3evraim
# Leave the hands OFF: everything after this point is written against head aim.
say 'q3evrhandbtn r 0'; sleep 1
say 'q3evrhandbtn l 0'; sleep 1
say 'q3evrhand l off'; sleep 2
say 'q3evrmovemode head'; sleep 2

# --- 4b-xxx. the Aiming row exists only when an ORDINARY pad is connected ---
# R4.6. UIKit is invisible to every instrument this suite has, so what is
# asserted is the PREDICATE the row lays itself out with — `aimrow=` in
# SETTINGSNOW comes from the same Q3E_VR_PlainPadConnected() call
# -applyContextualVisibility hides the row on, which is the closest a test can
# stand to the row itself (the 4b-xx-c-ii precedent: the sheet is reachable only
# through what the code it runs can be asked).
#
# `auto` is the REAL scan and it cannot be used for the absent case: measured
# 2026-08-20, this simulator answers `q3evrsense controllers=[1 pad(s), 0
# spatial: [MFi 23b/3d]]` — the runtime presents an MFi gamepad to the guest
# whether or not the Mac has one paired, so `auto` legitimately reports a pad and
# the row legitimately shows. That is why `q3evrpad 0|1` exists: BOTH branches of
# the row's visibility are driven through the forced answer, and the real scan's
# spatial filtering stays a device claim, made in 4b-xxiii.
# The spatial case below is therefore honest about its limits — a tracked Sense
# pair does not make the row appear, which is the property that matters, but the
# sim cannot distinguish "a spatial pad was filtered out" from "no pad at all".
# The filter itself is a device claim, and 4b-xxiii is where it is made.
echo "== 4b-xxx. the Aiming row follows an ordinary gamepad's presence"
say 'q3evrpad 0'; sleep 2
zone_assert "with no controller at all the row is hidden" SETTINGSNOW \
  'aimmode=head aimrow=hidden' q3evrsettingsdump
say 'q3evrpad 1'; sleep 2
zone_assert "with a plain pad connected the row is shown" SETTINGSNOW \
  'aimrow=shown' q3evrsettingsdump
# A tracked SPATIAL pair, and nothing else: the row must stay away. The hands
# have their own aim and outrank this row entirely.
say 'q3evrpad 0'; sleep 1
say 'q3evrhand r 0 0 0 0.20 1.20 -0.30'; sleep 3
zone_assert "a tracked Sense pair alone does not bring the row back" SETTINGSNOW \
  'aimrow=hidden' q3evrsettingsdump
zone_assert "...and the hand still owns the aim, whatever the row says" AIMNOW \
  'aimsrc=hand ' q3evraim
# HAND PRECEDENCE, stated as the case it protects: the row set to Gamepad and a
# hand tracked is still HAND aim.
say 'q3evrpad 1'; sleep 1
say 'q3evraimmode gamepad'; sleep 3
zone_assert "Gamepad selected + a tracked hand = the HAND still aims" AIMNOW \
  'aimsrc=hand .*padaim=\(mode=gamepad,active=0' q3evraim
say 'q3evrhand r off'; sleep 4

# --- 4b-xxx-a. GAMEPAD AIM: the stick turns the view, the head does not ------
# R4.7 REWRITES this case against the corrected composition (D-VR-R4.7): the
# stick TURNS THE VIEW — body yaw, continuously, at the flat game's look rate —
# and the crosshair stays at the centre of the game's forward direction. The
# R4.6 cone the earlier version of this case was written around is gone, so the
# numbers it read are different numbers:
#
#   - `sent=(...,y)` is cl.viewangles[YAW] = body + aim, and with the aim pinned
#     at the body's forward it IS the body. A stick that turns the view moves
#     this; a head that only glances must not.
#   - `padaim=(...yaw...)` is the aim's offset from the body, and the invariant
#     is that it stays ZERO. That is the closest a dump can stand to
#     "crosshair at the centre of the view", and it is the one number that would
#     move if the cone (or any other offset mechanism) came back.
echo "== 4b-xxx-a. in Gamepad mode the stick turns the view and the head does not"
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
say 'q3evraimmode gamepad'; sleep 3
zone_assert "the stick is aiming, and the aim is the body's forward" AIMNOW \
  'aimsrc=pad .*padaim=\(mode=gamepad,active=1,yaw-?0\.0deg' q3evraim
PADYAW0=$(lastline AIMNOW | sed -E 's/.*padaim=\(mode=[a-z]+,active=[01],yaw(-?[0-9.]+)deg.*/\1/')
SENTYAW0=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
# THE HEAD MOVES — 15 degrees — and the AIM must not follow it. The camera does
# (that is the VR part, and the eye cases measure it); the game's aim does not,
# which is what "the head can glance around freely" means.
say 'q3evrpose 15 0 0 1.60 0'; sleep 3
say 'q3evraim'; sleep 2
SENTYAW1=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
if [ -n "$SENTYAW0" ] && [ -n "$SENTYAW1" ] && \
   awk "BEGIN{d=($SENTYAW1)-($SENTYAW0); if (d<0) d=-d; if (d>180) d=360-d; exit !(d < 2)}"; then
  printf '   PASS  a 15-degree head turn left the game aim where it was (%s -> %s deg)\n' \
    "$SENTYAW0" "$SENTYAW1"
else
  printf '   FAIL  the head moved the game aim (%s -> %s deg): this is gaze aim wearing the\n' \
    "${SENTYAW0:-none}" "${SENTYAW1:-none}" >&2
  printf '         other row s name\n' >&2
  FAILED=1
fi
# THE STICK MOVES — half deflection for a third of a second, ~20 degrees of body
# turn at the 140 deg/s rate the curve scales. There is no cone to stay inside
# any more; what is asserted is that the VIEW went with it.
say 'q3evrpadstick 0.5 0 0.35'; sleep 3
say 'q3evraim'; sleep 2
PADYAW2=$(lastline AIMNOW | sed -E 's/.*padaim=\(mode=[a-z]+,active=[01],yaw(-?[0-9.]+)deg.*/\1/')
SENTYAW2=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
if [ -n "$SENTYAW1" ] && [ -n "$SENTYAW2" ] && \
   awk "BEGIN{d=($SENTYAW2)-($SENTYAW1); if (d>180) d-=360; if (d<-180) d+=360; if (d<0) d=-d; exit !(d > 4)}"; then
  printf '   PASS  the stick turned the view (%s -> %s deg) with the head held still\n' \
    "$SENTYAW1" "$SENTYAW2"
else
  printf '   FAIL  the injected stick did not turn the view (%s -> %s deg)\n' \
    "${SENTYAW1:-none}" "${SENTYAW2:-none}" >&2
  FAILED=1
fi
# ...and the CROSSHAIR never left the centre while it did: the aim offset is
# still zero after a turn AND after a head move, which is the whole correction.
if [ -n "$PADYAW0" ] && [ -n "$PADYAW2" ] && \
   awk "BEGIN{a=$PADYAW0; if (a<0) a=-a; b=$PADYAW2; if (b<0) b=-b; exit !(a < 0.5 && b < 0.5)}"; then
  printf '   PASS  the aim stayed at the body forward throughout (%s, %s deg offset)\n' \
    "$PADYAW0" "$PADYAW2"
else
  printf '   FAIL  the aim wandered off the view centre (%s -> %s deg): the R4.6 cone is back\n' \
    "${PADYAW0:-none}" "${PADYAW2:-none}" >&2
  FAILED=1
fi
# PITCH, R4.8: the same claim on the other axis, and the one the second device
# round was about. The stick's Y must pitch the CAMERA, not walk the crosshair up
# the screen — so the published eye forward's up component (HEADNOW `eyefwdup=`,
# sin of the world pitch with a level head) has to move with the aim pitch, and
# the aim pitch has to be what cl.viewangles carries (negated: ARKit up-positive
# vs Quake down-positive). Both halves, or a crosshair that drifts off centre
# passes as a camera that pitched.
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
say 'q3evrhead'; sleep 2
EYEUP0=$(lastline HEADNOW | sed -E 's/.*eyefwdup=(-?[0-9.]+).*/\1/')
# cl.viewangles[PITCH] is an ACCUMULATOR, not a readout: patch 0014 writes the
# pitch as a delta, so its absolute value carries whatever the session has done
# to it already (this run reaches here at -35 deg from the earlier pose cases).
# Only the CHANGE across the stick push can be compared to the aim pitch — the
# absolute comparison this case used to make was unrun and could only pass from a
# zeroed history. Same for the pad's own pitch, which is the axis's accumulator.
say 'q3evraim'; sleep 2
SENTPITCH0=$(lastline AIMNOW | sed -E 's/.*sent=\(p(-?[0-9.]+),y.*/\1/')
PADPITCH0=$(lastline AIMNOW | sed -E 's/.*padaim=\(mode=[a-z]+,active=[01],yaw-?[0-9.]+deg,pitch(-?[0-9.]+)deg.*/\1/')
say 'q3evrpadstick 0 0.5 0.35'; sleep 3
say 'q3evraim'; sleep 1
say 'q3evrhead'; sleep 2
PADPITCH=$(lastline AIMNOW | sed -E 's/.*padaim=\(mode=[a-z]+,active=[01],yaw-?[0-9.]+deg,pitch(-?[0-9.]+)deg.*/\1/')
SENTPITCH=$(lastline AIMNOW | sed -E 's/.*sent=\(p(-?[0-9.]+),y.*/\1/')
EYEUP1=$(lastline HEADNOW | sed -E 's/.*eyefwdup=(-?[0-9.]+).*/\1/')
if [ -n "$PADPITCH" ] && [ -n "$EYEUP0" ] && [ -n "$EYEUP1" ] && \
   awk "BEGIN{p=$PADPITCH; if (p<0) p=-p; exit !(p > 4)}" && \
   awk "BEGIN{want=sin(($PADPITCH)*3.14159265/180.0); d=($EYEUP1)-want; if (d<0) d=-d;
              m=($EYEUP1)-($EYEUP0); if (m<0) m=-m; exit !(d < 0.08 && m > 0.05)}"; then
  printf '   PASS  the stick pitched the CAMERA %s deg (eye forward up %s -> %s = sin of it)\n' \
    "$PADPITCH" "$EYEUP0" "$EYEUP1"
else
  printf '   FAIL  the aim pitched %s deg but the camera did not follow (eye forward up %s -> %s):\n' \
    "${PADPITCH:-none}" "${EYEUP0:-none}" "${EYEUP1:-none}" >&2
  printf '         this is the R4.7 defect on the other axis — the crosshair leaves the centre\n' >&2
  FAILED=1
fi
# ...and the SHOT goes where the camera looks: cl.viewangles carries the same
# angle in Quake's own sign, which is what puts the marker at the view centre.
if [ -n "$PADPITCH" ] && [ -n "$SENTPITCH" ] && [ -n "$PADPITCH0" ] && [ -n "$SENTPITCH0" ] && \
   awk "BEGIN{d=(($SENTPITCH)-($SENTPITCH0))+(($PADPITCH)-($PADPITCH0)); if (d<0) d=-d; exit !(d < 2)}"; then
  printf '   PASS  cl.viewangles pitch moved by the world pitch, negated (%s -> %s vs pad %s -> %s deg)\n' \
    "$SENTPITCH0" "$SENTPITCH" "$PADPITCH0" "$PADPITCH"
else
  printf '   FAIL  the aim pitch and the world pitch disagree (sent %s -> %s vs pad %s -> %s deg): the crosshair is\n' \
    "${SENTPITCH0:-none}" "${SENTPITCH:-none}" "${PADPITCH0:-none}" "${PADPITCH:-none}" >&2
  printf '         off the view centre vertically by their difference\n' >&2
  FAILED=1
fi
say 'q3evrpadstick 0 -0.5 0.35'; sleep 3   # back to level for what follows
zone_assert "the marker is valid while the STICK is aiming" AIMNOW \
  'aimsrc=pad .*marker=\(valid1,' q3evraim
# The movement basis stays coherent: with no hand to be, "Aim" resolves to the
# stick aim (walk where you point — the flat game's own controls) instead of
# silently meaning "Head".
say 'q3evrmovemode aimhand'; sleep 3
zone_assert "Movement Direction Aim resolves to the STICK aim in this mode" MOVENOW \
  'basis=aimhand basissrc=padaim ' q3evrmove
zone_assert "...and is the identity, exactly as it is for a hand" MOVENOW \
  'delta=-?0\.0deg' q3evrmove
say 'q3evrmovemode head'; sleep 2

# --- 4b-xxx-b. ...and in HEAD mode the stick does NOT move the aim ----------
# The other direction of the same claim. Same injected stick, same head, row
# back on Head: the aim must be the gaze and nothing but the gaze. The synthetic
# stick is the PAD-AIM injection, so in Head mode it reaches no seam at all —
# which is the property, stated as a number: the sent yaw does not move.
echo "== 4b-xxx-b. in Head mode the same injected stick moves no aim"
say 'q3evraimmode head'; sleep 3
say 'q3evrpose 15 0 0 1.60 0'; sleep 3
say 'q3evraim'; sleep 2
HEADMODE0=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
say 'q3evrpadstick 0.9 0 1.0'; sleep 4
say 'q3evraim'; sleep 2
HEADMODE1=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
zone_assert "the head is aiming again, and the pad seam is inert" AIMNOW \
  'aimsrc=head .*padaim=\(mode=head,active=0' q3evraim
if [ -n "$HEADMODE0" ] && [ -n "$HEADMODE1" ] && \
   awk "BEGIN{d=$HEADMODE1-$HEADMODE0; if (d>180) d-=360; if (d<-180) d+=360; if (d<0) d=-d; exit !(d < 2)}"; then
  printf '   PASS  a full-deflection stick moved the aim by nothing in Head mode (%s -> %s deg)\n' \
    "$HEADMODE0" "$HEADMODE1"
else
  printf '   FAIL  the stick reached the aim in HEAD mode (%s -> %s deg)\n' \
    "${HEADMODE0:-none}" "${HEADMODE1:-none}" >&2
  FAILED=1
fi

# --- 4b-xxx-c. PROOF: the Gamepad case above can FAIL ----------------------
# `q3evrpadaim 0` disables the seam with the row still set to Gamepad and the
# stick still injected, so the aim must collapse back to the gaze — and the gaze
# is 15 degrees off the body forward the stick aim sits on, which is the whole
# measurement (R4.7: the sent yaw is body+0 while the pad aims, body+head after,
# so disabling the seam is exactly a 15-degree step). An assertion nobody has
# watched fail is a decoration.
echo "== 4b-xxx-c. PROOF: q3evrpadaim 0 hands the aim back to the head"
say 'q3evraimmode gamepad'; sleep 2
say 'q3evrpadstick 0.5 0 0.35'; sleep 3
say 'q3evraim'; sleep 2
PROOFPAD=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
say 'q3evrpadaim 0'; sleep 3
zone_assert "the source really did change back" AIMNOW \
  'aimsrc=head .*padaim=\(mode=gamepad,active=0,.*hook0' q3evraim
PROOFHEAD=$(lastline AIMNOW | sed -E 's/.*sent=\(p[^,]+,y(-?[0-9.]+)\).*/\1/')
if [ -n "$PROOFPAD" ] && [ -n "$PROOFHEAD" ] && \
   awk "BEGIN{d=$PROOFPAD-$PROOFHEAD; if (d>180) d-=360; if (d<-180) d+=360; if (d<0) d=-d; exit !(d > 4)}"; then
  printf '   PASS  disabling the seam moved the sent yaw %s -> %s deg — the STICK was driving it\n' \
    "$PROOFPAD" "$PROOFHEAD"
else
  printf '   FAIL  disabling the pad seam changed nothing (%s -> %s): the cases above cannot fail\n' \
    "${PROOFPAD:-none}" "${PROOFHEAD:-none}" >&2
  FAILED=1
fi
# Leave the head aiming, the pad gone and the stick still, as everything after
# this point expects.
say 'q3evrpadaim 1'; sleep 1
say 'q3evrpadstick 0 0 0'; sleep 1
say 'q3evraimmode head'; sleep 2
say 'q3evrpad auto'; sleep 1
say 'q3evrpose 0 0 0 1.60 0'; sleep 2

# --- 4b-xxi. the settings sheet's own dump (R2 item 6) ----------------------
# --- 4b-xx-c. the sky diagnostics stay out of the public build -------------
# R2.3 fix 5 ships two DIFFERENTIAL toggles and a dump for the device-only sky
# symptom. They are diagnostics with a real frame cost (the cull bypass draws
# the whole map), so they are gated on Q3E_DEV_BUILD — and this suite builds the
# app in its PUBLIC configuration, which makes it the one place that can prove
# the gate holds. The dev build the maintainer runs registers them; this one must not.
echo "== 4b-xx-c. the sky diagnostics are absent from a public-configuration build"
SKY_PUB=$(ask 'q3evrskyacc' 2>/dev/null | grep -c 'DIAGNOSTIC' || true)
# R3.1 item 3 adds two more of them — the draw-state fingerprint and the
# depth-test bypass — and the depth bypass is the one that would matter most if
# it escaped: a public build that could be told to draw the sky over the world
# is a public build with a cheat in it. Every member of the family is named
# here, so a new one added behind the gate is covered by this case and a new one
# added in FRONT of it is caught by it.
SKY_PUB_DRAW=$(ask 'q3evrskydraw' 2>/dev/null | grep -c 'SKYDRAW' || true)
SKY_PUB_DEPTH=$(ask 'q3evrskydepth' 2>/dev/null | grep -c 'DIAGNOSTIC' || true)
if [ "${SKY_PUB:-0}" -eq 0 ] && [ "${SKY_PUB_DRAW:-0}" -eq 0 ] && [ "${SKY_PUB_DEPTH:-0}" -eq 0 ]; then
  printf '   PASS  no q3evrsky* diagnostic is registered in a public-configuration build\n'
else
  printf '   FAIL  a dev-only sky diagnostic answered in a PUBLIC build (acc %s, draw %s, depth %s)\n' \
         "${SKY_PUB:-0}" "${SKY_PUB_DRAW:-0}" "${SKY_PUB_DEPTH:-0}" >&2
  FAILED=1
fi
# R4.1: the three checks above are ABSENCE checks, and an absence check passes
# for free the moment the thing doing the asking stops working — a bridge that
# returned nothing at all would report a perfectly gated build with every
# diagnostic wide open. The control below is what makes them mean something: an
# UNGATED q3evr command asked through the same `ask`, in the same run. If the
# bridge is mute, this fails and the three above are known to be worthless.
# `q3evranchor` is the right control because R3.5 left it ungated deliberately,
# precisely so the public build this suite runs can still move it.
#
# NOT the engine's "Unknown command" print, which was the obvious choice and is
# unobservable here: CL_ForwardCommandToServer only prints it below CA_CONNECTED,
# and this case runs inside a live local game, so an unregistered name is
# silently forwarded to the server instead. Measured, first run of this case.
DEVGATE_CONTROL=$(ask 'q3evranchor' 2>/dev/null | grep -c 'q3evranchor' || true)
if [ "${DEVGATE_CONTROL:-0}" -ge 1 ]; then
  printf '   PASS  the detector is not mute: an ungated q3evr command answered through the same path\n'
else
  printf '   FAIL  the gate checks above prove nothing — an UNGATED command answered nothing either\n' >&2
  FAILED=1
fi

# --- 4b-xx-c-ii. no dev-only SETTINGS ROW reached the public product --------
# The console family above is only half the gate. The other half is a UIKit row
# — "Remote Console (port 27999)", which opens an unauthenticated console to the
# local network — and no dump can see it: UIKit is invisible to every
# instrument this suite has (the charter's own rule, learned by trying).
#
# What IS visible is the built binary. The row's label is a string literal
# inside `#ifdef Q3E_DEV_BUILD`, so it exists in the dev build the maintainer runs and
# must not exist in this one. Checked in BOTH directions in the same command, so
# a `strings` that silently returned nothing (wrong path, stripped binary)
# cannot read as a clean build: a label from an UNGATED row of the same sheet
# has to be found.
echo "== 4b-xx-c-ii. the dev-only settings row is absent from the public product"
BIN="$APP/Quake3e"
DEVROW=$(strings -a "$BIN" 2>/dev/null | grep -Fc 'Remote Console (port 27999)' || true)
PUBROW=$(strings -a "$BIN" 2>/dev/null | grep -Fc 'Enter VR' || true)
if [ "${PUBROW:-0}" -lt 1 ]; then
  printf '   FAIL  the string scan found no PUBLIC settings row either — it is measuring nothing (%s)\n' \
         "$BIN" >&2; FAILED=1
elif [ "${DEVROW:-0}" -eq 0 ]; then
  printf '   PASS  no Remote Console row in the built product (public rows present: %s)\n' "$PUBROW"
else
  printf '   FAIL  the dev-only Remote Console row is compiled into a PUBLIC build (%s hits)\n' \
         "$DEVROW" >&2; FAILED=1
fi

# --- 4b-xx-d. the eye blit's depth floor (R3.1 item 3, THE SKY FIX) --------
# The engine draws sky at reverse-Z depth exactly 0, and 0 is also what the
# drawable's depth attachment is cleared to, so a compositor reprojecting
# against depth cannot tell sky from empty space. The blit now floors the depth
# it hands over, which makes the sky picture instead of absence.
#
# The simulator cannot judge the RESULT — there is no reprojection here, which
# is precisely why five rounds of sim probes never reproduced the symptom. What
# it can prove, and what this asserts, is that the number is live, reaches the
# dump, moves on command, clamps at both ends, and comes back to a default that
# is NOT zero. A default that silently regressed to zero would put the black sky
# back on glass with nothing else looking any different.
echo "== 4b-xx-d. the eye blit's depth floor is live, tunable and non-zero by default"
zone_assert "EYENOW carries a non-zero depth floor out of the box" EYENOW \
  'depthfloor=0\.000122' q3evreye
say 'q3evrdepthfloor 0'; sleep 2
DF_OFF=$(ask 'q3evrdepthfloor' | grep -Eo 'current: [0-9.]+' | head -1)
say 'q3evrdepthfloor 1.0'; sleep 2          # far above the 0.01 ceiling
DF_CLAMP=$(ask 'q3evrdepthfloor' | grep -Eo 'current: [0-9.]+' | head -1)
say 'q3evrdepthfloor 0.000122'; sleep 2     # back to the shipped default
echo "   q3evrdepthfloor: 0 -> '$DF_OFF', 1.0 -> '$DF_CLAMP'"
if [ "$DF_OFF" = "current: 0.000000" ] && [ "$DF_CLAMP" = "current: 0.010000" ]; then
  printf '   PASS  the depth floor switches off for an A/B and clamps at its ceiling\n'
else
  printf '   FAIL  q3evrdepthfloor did not round-trip/clamp (0 -> %s, 1.0 -> %s)\n' \
         "${DF_OFF:-none}" "${DF_CLAMP:-none}" >&2
  FAILED=1
fi
zone_assert "...and the dump follows it back to the default" EYENOW \
  'depthfloor=0\.000122' q3evreye

# --- 4b-xx-e. R4.3's three donor-parity rows --------------------------------
# Show Hands, Sharpen and Damage Flash. All three ship at what the previous
# build already did, so the FIRST claim in each case is the shipped default —
# a round that adds picture-affecting rows has to prove it did not move the
# picture for anyone who never touches them.
#
# Each row is driven from the console (the native seam) and read back in TWO
# places that are computed independently: EYENOW off the live engine globals,
# SETTINGSNOW out of the preference store. A row that reached one and not the
# other is the exact defect the R2.1 write-back fixes were about.
# R4.5 moves ONE of the three: Sharpen ships at 50% now, the maintainer's number off
# the 1.0.4.15 build (and the donor's own). The other two are unchanged, and
# the shape of the case is the same — drive the row, read it back in two
# independently computed places.
echo "== 4b-xx-e. Show Hands / Sharpen / Damage Flash sit at their shipped defaults"
say 'q3evrhands 0'; sleep 1
say 'q3evrsharpen 50'; sleep 1
say 'q3evrdamageflash 1'; sleep 2
zone_assert "EYENOW: hands hidden, sharpen at the shipped 50%, the flash drawn" EYENOW \
  'hands=off sharpen=50% dmgflash=on ' q3evreye
zone_assert "SETTINGSNOW agrees, out of the store" SETTINGSNOW \
  'hands=off sharpen=50% dmgflash=on ' q3evrsettingsdump

echo "== 4b-xx-e-i. Show Hands round-trips through the console and both dumps"
HANDS_ON=$(ask 'q3evrhands 1' | grep -Eo 'q3evrhands: (on|off)' | tail -1)
say 'q3evreye'; sleep 2
zone_assert "...and the live engine reads it back on" EYENOW 'hands=on ' q3evreye
zone_assert "...and so does the store" SETTINGSNOW 'hands=on ' q3evrsettingsdump
HANDS_OFF=$(ask 'q3evrhands 0' | grep -Eo 'q3evrhands: (on|off)' | tail -1)
echo "   q3evrhands 1 -> '$HANDS_ON'   q3evrhands 0 -> '$HANDS_OFF'"
if [ "$HANDS_ON" = 'q3evrhands: on' ] && [ "$HANDS_OFF" = 'q3evrhands: off' ]; then
  printf '   PASS  Show Hands round-trips in both directions\n'
else
  printf '   FAIL  q3evrhands did not round-trip (1 -> %s, 0 -> %s)\n' \
         "${HANDS_ON:-none}" "${HANDS_OFF:-none}" >&2
  FAILED=1
fi
zone_assert "...and the default is what the dump ends on" EYENOW 'hands=off ' q3evreye

echo "== 4b-xx-e-ii. Sharpen takes percent, clamps to the row, and refuses nonsense"
say 'q3evrsharpen 50'; sleep 2
zone_assert "50% reaches the live blit" EYENOW 'sharpen=50% ' q3evreye
SH_HI=$(ask 'q3evrsharpen 400' | grep -Eo 'q3evrsharpen: [0-9]+%' | tail -1)
SH_LO=$(ask 'q3evrsharpen -30' | grep -Eo 'q3evrsharpen: [0-9]+%' | tail -1)
SH_BAD=$(ask 'q3evrsharpen banana' | grep -Eo 'must be a number' | tail -1)
echo "   400 -> '$SH_HI'   -30 -> '$SH_LO'   banana -> '$SH_BAD'"
if [ "$SH_HI" = 'q3evrsharpen: 100%' ] && [ "$SH_LO" = 'q3evrsharpen: 0%' ] &&
   [ "$SH_BAD" = 'must be a number' ]; then
  printf '   PASS  the sharpen row clamps at both ends and rejects a non-number\n'
else
  printf '   FAIL  q3evrsharpen clamp/parse: 400 -> %s, -30 -> %s, banana -> %s\n' \
         "${SH_HI:-none}" "${SH_LO:-none}" "${SH_BAD:-nothing}" >&2
  FAILED=1
fi
say 'q3evrsharpen 50'; sleep 2   # back to the shipped default, not to zero

echo "== 4b-xx-e-iii. Damage Flash round-trips, and the gate reports what it sees"
DF_OFF2=$(ask 'q3evrdamageflash 0' | grep -Eo 'q3evrdamageflash: (on|off)' | tail -1)
zone_assert "...the live engine holds the gate shut" EYENOW 'dmgflash=off ' q3evreye
DF_ON2=$(ask 'q3evrdamageflash 1' | grep -Eo 'q3evrdamageflash: (on|off)' | tail -1)
echo "   q3evrdamageflash 0 -> '$DF_OFF2'   1 -> '$DF_ON2'"
if [ "$DF_OFF2" = 'q3evrdamageflash: off' ] && [ "$DF_ON2" = 'q3evrdamageflash: on' ]; then
  printf '   PASS  Damage Flash round-trips in both directions\n'
else
  printf '   FAIL  q3evrdamageflash did not round-trip (0 -> %s, 1 -> %s)\n' \
         "${DF_OFF2:-none}" "${DF_ON2:-none}" >&2
  FAILED=1
fi
zone_assert "...and the dump carries the seen/dropped pair" EYENOW \
  'dmgflash=on dmgblends=[0-9]+/[0-9]+' q3evreye

echo "== 4b-xxi. SETTINGSNOW reports the Vision Pro VR section"
zone_assert "SETTINGSNOW answers with the VR section and a migration stamp" SETTINGSNOW \
  "section='Vision Pro VR'.*mig=12" q3evrsettingsdump
zone_assert "...including the R3 hand rows it grew this round" SETTINGSNOW \
  'aimhand=(Left|Right) movebasis=(Head|AimHand|OffHand|Off) aimtrim=[+-][0-9.]+deg gunscale=[0-9.]+x.*haptics=[01]' \
  q3evrsettingsdump
# R4.0: the dump carries Weapon Size in BOTH units — native for the console,
# the row for what is on screen — the way it already does for the crosshair, and
# it carries the LIVE grip, read off the engine's globals rather than out of a
# store that no longer holds one.
zone_assert "...and R4.0's Weapon Size row unit and the live hardcoded grip" SETTINGSNOW \
  'gunscale=0\.75x gunrow=1\.00x grip=\(f-6\.0,r-0\.5,u0\.0\)u gripang=\(p0\.0,y0\.0,r0\.0\)deg' \
  q3evrsettingsdump

# --- 4b-xxi-b. THE WEAPON SIZE ROW'S DISPLAY MAPPING (R4.0) ------------------
# The maintainer: the shipped native 0.75 should read as 1.00x. The crosshair row's
# pattern, applied a second time — the ROW divides by 0.75 and everything below
# the sheet keeps native units. The pair of fields above is what makes the claim
# readable: `gunscale=` never moves off native, `gunrow=` is what the slider
# shows, and they must track each other across the row's whole travel.
#
# Driven through the CONSOLE, which is the native seam, so a build that had
# quietly started storing display units would show it here as a doubled mapping.
echo "== 4b-xxi-b. Weapon Size: the row displays native/0.75, at both ends and the default"
say 'q3evrgunscale 0.375'; sleep 2
zone_assert "the row's LOW end: native 0.375 displays as 0.50x" SETTINGSNOW \
  'gunscale=0\.38x gunrow=0\.50x' q3evrsettingsdump
say 'q3evrgunscale 1.875'; sleep 2
zone_assert "the row's HIGH end: native 1.875 displays as 2.50x" SETTINGSNOW \
  'gunscale=1\.88x gunrow=2\.50x' q3evrsettingsdump
# The clamp is the other half of "every value the slider reaches is one the
# console accepts, and vice versa": the console must refuse to leave the span
# the row can show, at both ends.
GS_HI=$(ask 'q3evrgunscale 9' | grep -Eo 'q3evrgunscale: [0-9.]+x' | tail -1)
GS_LO=$(ask 'q3evrgunscale 0.01' | grep -Eo 'q3evrgunscale: [0-9.]+x' | tail -1)
echo "   q3evrgunscale 9 -> '$GS_HI'   q3evrgunscale 0.01 -> '$GS_LO'"
if [ "$GS_HI" = 'q3evrgunscale: 1.88x' ] && [ "$GS_LO" = 'q3evrgunscale: 0.38x' ]; then
  printf '   PASS  the console clamps to the same native span the row can display\n'
else
  printf '   FAIL  q3evrgunscale accepted a value the row cannot show (9 -> %s, 0.01 -> %s)\n' \
         "${GS_HI:-none}" "${GS_LO:-none}" >&2
  FAILED=1
fi
say 'q3evrgunscale 0.75'; sleep 2
zone_assert "...and the shipped default is the 1.00x the maintainer asked for" SETTINGSNOW \
  'gunscale=0\.75x gunrow=1\.00x' q3evrsettingsdump

# --- 4b-xxii. console/ornament tuning writes back to the sheet's own store
# (R2.1 fix 6b). Before this fix the q3evr* commands changed the live engine
# state but never told NSUserDefaults — so the NEXT time ApplyAll ran (the
# sheet opening, an unrelated slider anywhere in it, or the next launch) the
# sheet's own stale stored value silently overwrote whatever had just been
# tuned live. Distinct, no-coincidence values (turn speed 233, snap-45, HUD
# High) driven purely through the CONSOLE seam the ornament also uses, then
# read back through the SAME dump the sheet itself builds from
# (Q3E_VR_SettingsDumpString) — if that dump still shows the OLD default, the
# write-back did not happen.
echo "== 4b-xxii. a console/ornament change writes back to the sheet's own NSUserDefaults store"
say 'q3evrturn 45 233'; sleep 1
say 'q3evrhud off'; sleep 1
say 'q3evrxhairsize 1.25'; sleep 1
say 'q3evrrenderscale 1.85'; sleep 1
# R3.1 item 1: xhairrow is the SAME value in the row's own 1x..5x units, so a
# reader can check the dump against the console and against the screen without
# doing the arithmetic. 1.25 native is 1 + (1.25-0.5)*4 = 4.0 on the row.
zone_assert "the sheet's own dump reflects the console-driven values, not stale defaults" \
  SETTINGSNOW "snapturn=45.*turnspeed=233deg/s.*xhairsize=1.25x xhairrow=4.0x.*hud=Off" q3evrsettingsdump
# R3.2 item 2: HUD Size (a multiplier) and HUD Height (degrees of pitch) are
# different quantities in different units, so this is no longer "both halves of
# one split" — it is two independent controls that must not move each other.
say 'q3evrhudsize 1.75'; sleep 1
say 'q3evrhudheight -9'; sleep 1
zone_assert "...including HUD Size and HUD Height, separately and in their own units" SETTINGSNOW \
  "hudsize=1.75x hudheight=-9.0deg" q3evrsettingsdump
say 'q3evrhudsize 1.25'; sleep 1
say 'q3evrhudheight 0'; sleep 1
zone_assert "...including render scale" SETTINGSNOW "renderscale=1.85x" q3evrsettingsdump
# Restore the shipped defaults through the same console seam, and confirm
# THAT write-back too — not just that the mechanism can move away from
# defaults, but that it tracks a change back to them just as faithfully.
say 'q3evrturn smooth 140'; sleep 1
say 'q3evrhud on'; sleep 1
say 'q3evrxhairsize 0.5'; sleep 1
say 'q3evrrenderscale 1.25'; sleep 1
zone_assert "restoring the defaults via console also writes back" SETTINGSNOW \
  "renderscale=1.25x.*snapturn=Smooth.*turnspeed=140deg/s.*xhairsize=0.50x xhairrow=1.0x.*hud=On.*hudsize=1.25x hudheight=\\+0.0deg" q3evrsettingsdump

# --- 4b-xxii-b. the VR Crosshair on/off row (R3.2 item 7, donor parity) -----
# Off is expressed as the scale the renderer holds (it already declines to draw
# the marker at zero), so the property to prove is that turning it off does not
# eat the SIZE that was dialled in — the size has to come back exactly.
echo "== 4b-xxii-b. VR Crosshair on/off keeps the size it was turned off with"
say 'q3evrxhairsize 1.25'; sleep 1
say 'q3evrxhair 0'; sleep 1
zone_assert "off is reported by the sheet's own dump, size untouched" SETTINGSNOW \
  "xhairsize=1.25x .*xhair=off" q3evrsettingsdump
zone_assert "...and the placement layer agrees the marker is off" PANELNOW \
  'xhair=off' q3evrpanel
say 'q3evrxhair 1'; sleep 1
zone_assert "back on, at the same 1.25x it was turned off with" SETTINGSNOW \
  "xhairsize=1.25x .*xhair=on" q3evrsettingsdump
say 'q3evrxhairsize 0.5'; sleep 1

# --- 4b-xxii-a. an out-of-range value CLAMPS, and the store says the same
# thing the engine does (R2.2 fixes 7/12). Three tunables had two different
# answers for "outside the range": the console clamped, the sheet's own quiet
# setters silently dropped. That is what made the Height slider's own end
# positions apply nothing (19.7 in = 0.50038 m against a 0.50 m limit) and what
# let the sheet's last-applied cache, SETTINGSNOW and the sheet itself all
# report a value the engine had never taken — with the cache equality
# guaranteeing no later pass would retry it. One rule now: clamp the magnitude,
# and record what the engine actually holds.
echo "== 4b-xxii-a. out-of-range tuning clamps, and the store agrees with the engine"
say 'q3evrturn smooth 20'; sleep 1        # below the 60 deg/s floor
say 'q3evrrenderscale 9'; sleep 1         # above the 2.0x ceiling (R3.3)
say 'q3evrxhairsize 0.1'; sleep 1         # below the 0.5x floor
zone_assert "the store holds the CLAMPED values, not the asked-for ones or the old ones" \
  SETTINGSNOW "renderscale=2.00x.*turnspeed=60deg/s.*xhairsize=0.50x" q3evrsettingsdump
# The same numbers read back from the ENGINE's own side (each command with no
# argument prints its live value), so a store and an engine that quietly
# disagree cannot both look right.
RS_LIVE=$(ask 'q3evrrenderscale' | grep -Eo 'current: [0-9.]+x' | head -1)
XH_LIVE=$(ask 'q3evrxhairsize' | grep -Eo 'current: [0-9.]+x' | head -1)
echo "   live engine values after clamping: renderscale $RS_LIVE | xhairsize $XH_LIVE"
if [ "$RS_LIVE" = 'current: 2.00x' ] && [ "$XH_LIVE" = 'current: 0.50x' ]; then
  printf '   PASS  the live engine holds the same clamped values the store reports\n'
else
  printf '   FAIL  engine/store disagree after a clamp: renderscale %s, xhairsize %s\n' \
         "${RS_LIVE:-none}" "${XH_LIVE:-none}" >&2
  FAILED=1
fi
# NaN is the one input that is still REFUSED rather than clamped — it has no
# nearest legal value, and one of them in this state is unrecoverable.
say 'q3evrrenderscale nan'; sleep 1
zone_assert "...but NaN is refused outright, and the clamped value stands" SETTINGSNOW \
  "renderscale=2.00x" q3evrsettingsdump
say 'q3evrturn smooth 140'; sleep 1
say 'q3evrxhairsize 0.5'; sleep 1
say 'q3evrrenderscale 1.25'; sleep 1
zone_assert "the shipped defaults are back" SETTINGSNOW \
  "renderscale=1.25x.*turnspeed=140deg/s.*xhairsize=0.50x" q3evrsettingsdump

# --- 4c. THE DEVICE FAILURE, as a simulator case ----------------------------
# On the device, opening a full immersive space deactivates the 2D window's scene
# and visionOS stops delivering its CADisplayLink callbacks. Everything entry
# needed then stopped happening at once: the queued r_stereo3d never drained (so
# the renderer skipped the backend while minimized and every surface stuck on the
# entry frame), the queued vid_restart never drained (so phase 2 polled for an
# extent change that could not happen and aborted 6.5 s later), and the audio
# mixer stopped being ticked. The simulator's window scene does NOT deactivate,
# so nothing here could reach it — until this hook, which pins the link down for
# the whole entry.
echo "== 4c. entry survives a DEAD display link (the device's failure mode)"
say 'q3evr 0'; sleep 6
BEFORE_RENDERED=$(lastline FRAMENOW | grep -Eo 'renderedid=[0-9]+' | cut -d= -f2)
say 'q3evrlinkfreeze 1'; sleep 2
need "$BB" "the link-freeze hook is armed" 'link: freeze hook ARMED'
say 'q3evr 1'; sleep 12
alive || die "the app stopped answering with the display link frozen"
need "$BB" "the frame owner moves to the engine thread BEFORE the space opens" \
  'frame owner -> engine thread BEFORE opening the space'
zone_assert "VR entry completed with the link dead" MODENOW 'mode=VR .*owner=vr'
POLLS=$(grep -Eo 'VR: phase 2 settled after [0-9]+ poll' "$BB" | tail -1 | grep -Eo '[0-9]+' | tail -1)
if [ -n "$POLLS" ] && [ "$POLLS" -le 30 ]; then
  printf '   PASS  the queued restart still drained (settled after %s poll(s)) with no link\n' "$POLLS"
else
  printf '   FAIL  entry did not settle with the link frozen (polls=%s)\n' "${POLLS:-none}" >&2; FAILED=1
fi
if grep -q 'VR: ENTRY ABORTED' "$BB"; then
  printf '   FAIL  the entry aborted with the link frozen — the device failure is still live\n' >&2; FAILED=1
else
  printf '   PASS  the entry did not abort\n'
fi
# The engine has to be RENDERING, not merely ticking: renderedid only advances
# when the engine thread completes a pose it was handed.
sleep 4
AFTER_RENDERED=$(lastline FRAMENOW | grep -Eo 'renderedid=[0-9]+' | cut -d= -f2)
say 'q3evrframe'; sleep 2
AFTER_RENDERED=$(lastline FRAMENOW | grep -Eo 'renderedid=[0-9]+' | cut -d= -f2)
if [ "${AFTER_RENDERED:-0}" -gt "${BEFORE_RENDERED:-0}" ]; then
  printf '   PASS  the engine rendered %s VR frames with the display link dead\n' \
         "$((AFTER_RENDERED - BEFORE_RENDERED))"
else
  printf '   FAIL  the engine rendered nothing with the link dead (%s -> %s)\n' \
         "${BEFORE_RENDERED:-0}" "${AFTER_RENDERED:-0}" >&2; FAILED=1
fi
shot 05c-linkfrozen
pixels "and it is a real world frame, not the frozen entry frame" "$PFX-05c-linkfrozen.png" nonblack --min 20000
say 'q3evrlinkfreeze 0'; sleep 2
say 'q3evr 0'; sleep 8
zone_assert "back to 2D with the link running again" MODENOW 'mode=2D .*owner=link'

# --- 4d. an aborted entry leaves NOTHING queued behind ----------------------
# The device capture showed the entry's own vid_restart executing AFTER the
# rollback had already put the render size back: a full renderer restart to the
# VR extent, in 2D, undone by a second one. Two RE_Shutdown/R_Init cycles with
# the audio ring starving through both.
echo "== 4d. a rolled-back entry cancels its own queued restart"
EXT_BEFORE=$(lastline EYENOW | grep -Eo 'engine=[0-9]+x[0-9]+px' | head -1)
RGEN_BEFORE=$(lastline EYENOW | grep -Eo 'rgen=[0-9]+' | cut -d= -f2)
[ -n "$EXT_BEFORE" ] || die "could not read the 2D render extent before the forced abort"
echo "   pre-abort: $EXT_BEFORE rgen=$RGEN_BEFORE"
say 'q3evrfailentry 1'; sleep 2
say 'q3evr 1'; sleep 12
need "$BB" "the forced entry aborted" 'VR: ENTRY ABORTED'
need "$BB" "the teardown accounted for the entry queue" 'cancelled [0-9]+ queued restart'
need "$BB" "the teardown waited for the restores to EXECUTE, not just dequeue" 'restores EXECUTED after'
sleep 6
say 'q3evreye'; sleep 2
EXT_AFTER=$(lastline EYENOW | grep -Eo 'engine=[0-9]+x[0-9]+px' | head -1)
RGEN_AFTER=$(lastline EYENOW | grep -Eo 'rgen=[0-9]+' | cut -d= -f2)
echo "   post-rollback: $EXT_AFTER rgen=$RGEN_AFTER"
if [ "$EXT_AFTER" = "$EXT_BEFORE" ]; then
  printf '   PASS  the 2D render extent is untouched by the aborted entry\n'
else
  printf '   FAIL  the 2D extent was %s and is %s after a rolled-back entry\n' "$EXT_BEFORE" "$EXT_AFTER" >&2
  FAILED=1
fi
# And nothing restarts LATE: the generation must be stable once rollback is done.
sleep 4
say 'q3evreye'; sleep 2
RGEN_LATE=$(lastline EYENOW | grep -Eo 'rgen=[0-9]+' | cut -d= -f2)
if [ "$RGEN_LATE" = "$RGEN_AFTER" ]; then
  printf '   PASS  no renderer restart executed after the rollback completed (rgen stable at %s)\n' "$RGEN_LATE"
else
  printf '   FAIL  a late restart ran after rollback (rgen %s -> %s)\n' "$RGEN_AFTER" "$RGEN_LATE" >&2
  FAILED=1
fi
need "$BB" "the extent ownership went back to the window" "render extent: RELEASED by 'vr'"
zone_assert "...and the dump agrees who owns it" EYENOW 'extentowner=window'
say 'q3evrfailentry 0'; sleep 2
zone_assert "still in 2D after the rolled-back entry" MODENOW 'mode=2D .*owner=link'
say 'q3evr 1'; sleep 12
zone_assert "and VR still enters normally afterwards" MODENOW 'mode=VR .*owner=vr'

# --- 4e. a window-geometry STORM during entry -------------------------------
# THE GEOMETRY RACE. Opening a `.full` space fires real scene-geometry events at
# the 2D window, so the window's own resize path can run WHILE entry is in
# flight, and whichever re-size landed last would decide the render extent. This
# is NOT what pinned the extent on the device — case 4f is — but it is the same
# defect class, it was the leading suspect until 4f's mechanism was reproduced,
# and the simulator delivers none of those events, so nothing here could reach
# it. `q3evrwindowchurn` drives the shell's OWN handlers (a real geometry request
# plus the settled-resize handler), never a stand-in.
echo "== 4e. a window-geometry storm during entry cannot move the render extent"
say 'q3evr 0'; sleep 8
zone_assert "in 2D before the churn case" MODENOW 'mode=2D .*owner=link'
say 'q3evreye'; sleep 2
RGEN_PRE=$(lastline EYENOW | grep -Eo 'rgen=[0-9]+' | cut -d= -f2)
OWNER_PRE=$(lastline EYENOW | grep -Eo 'extentowner=[a-z]+' | cut -d= -f2)
REFUSE_PRE=$(lastline EYENOW | grep -Eo 'resizerefused=[0-9]+' | cut -d= -f2)
ABORTS_PRE=$(grep -c 'VR: ENTRY ABORTED' "$BB" 2>/dev/null || true)
[ "$OWNER_PRE" = "window" ] || die "the render extent is still owned by '$OWNER_PRE' in 2D"
echo "   pre-entry: rgen=$RGEN_PRE extentowner=$OWNER_PRE"
say 'q3evr 1'; sleep 2            # entry in flight — the space is opening
say 'q3evrwindowchurn 3'; sleep 14
need "$BB" "the churn ran the shell's own resize handlers three times" 'window churn 3/3 delivered'
need "$BB" "a window resize path was REFUSED by name while VR owned the extent" \
  "window: resize from '(applyResize|viewDidLayoutSubviews)' REFUSED"
A_NOW=$(grep -c 'VR: ENTRY ABORTED' "$BB" 2>/dev/null || true)
if [ "${A_NOW:-0}" -le "${ABORTS_PRE:-0}" ]; then
  printf '   PASS  the entry did not abort under the churn\n'
else
  printf '   FAIL  the entry aborted under window churn (%s -> %s)\n' "$ABORTS_PRE" "$A_NOW" >&2; FAILED=1
fi
POLLS=$(grep -Eo 'VR: phase 2 settled after [0-9]+ poll' "$BB" | tail -1 | grep -Eo '[0-9]+' | tail -1)
if [ -n "$POLLS" ] && [ "$POLLS" -le 30 ]; then
  printf '   PASS  entry still settled promptly under the churn (%s poll(s))\n' "$POLLS"
else
  printf '   FAIL  entry did not settle under window churn (polls=%s)\n' "${POLLS:-none}" >&2; FAILED=1
fi
WANT=$(grep -Eo 'per-eye target [0-9]+x[0-9]+px' "$BB" | tail -1 | grep -Eo '[0-9]+x[0-9]+')
[ -n "$WANT" ] || die "the VR loop never published a per-eye target to compare against"
zone_assert "the VR per-eye extent LANDED ($WANT)" EYENOW "engine=${WANT}px"
zone_assert "...and the VR path is armed" EYENOW 'vr=on'
zone_assert "...and the extent is owned by VR while it is" EYENOW 'extentowner=vr'
zone_assert "...and the world is what is presented" MODENOW 'present=world reason=0\(world\)'
# COUNTED, not just pinned: the refusals have to show up in the dump the next
# device round will read, and a gate that stopped being called would leave this
# number standing still while the log still looked plausible.
REFUSE_MID=$(lastline EYENOW | grep -Eo 'resizerefused=[0-9]+' | cut -d= -f2)
if [ "${REFUSE_MID:-0}" -gt "${REFUSE_PRE:-0}" ]; then
  printf '   PASS  the refused resizes are counted in the dump (resizerefused %s -> %s)\n' \
         "$REFUSE_PRE" "$REFUSE_MID"
else
  printf '   FAIL  the churn was refused but nothing counted it (resizerefused %s -> %s)\n' \
         "${REFUSE_PRE:-none}" "${REFUSE_MID:-none}" >&2; FAILED=1
fi
# STICKS: a late window resize landing after the commit would move it back.
sleep 6
zone_assert "the extent STUCK after the churn settled" EYENOW "engine=${WANT}px"
say 'q3evreye'; sleep 2
RGEN_POST=$(lastline EYENOW | grep -Eo 'rgen=[0-9]+' | cut -d= -f2)
# One renderer restart, and exactly one: the shell's note, the teardown of the old
# renderer and the new init each bump the generation, so an entry is +3. A second
# restart from the window path would read as +6.
if [ "$((RGEN_POST - RGEN_PRE))" = "3" ]; then
  printf '   PASS  exactly ONE renderer restart across the entry (rgen %s -> %s = +3)\n' \
         "$RGEN_PRE" "$RGEN_POST"
else
  printf '   FAIL  expected +3 render generations for one restart, got %s -> %s\n' \
         "$RGEN_PRE" "$RGEN_POST" >&2; FAILED=1
fi
shot 05e-churn
pixels "the churned entry still renders a world" "$PFX-05e-churn.png" nonblack --min 20000

# --- 4f. an archived render-size cvar cannot re-pin the extent ---------------
# THE OTHER HALF OF THE SAME DEVICE BUG, and the one that actually held the
# extent down: r_renderScale / r_renderWidth / r_renderHeight (and
# r_ext_supersample) are CVAR_ARCHIVE_ND|CVAR_LATCH, so a value set once lives in
# the player's config forever and re-derives glConfig on EVERY renderer init,
# after the platform layer has already applied VR's per-eye size. Invisible while
# it happens to match the window; on the device it pinned every VR entry to
# 3840x2160 and phase 2 aborted six seconds later, three times in a row.
echo "== 4f. an archived render-size cvar cannot re-pin the extent VR claimed"
say 'q3evr 0'; sleep 8
say 'q3evreye'; sleep 2
CVREF_PRE=$(lastline EYENOW | grep -Eo 'cvarrefused=[0-9]+' | cut -d= -f2)
ABORTS_PRE=$(grep -c 'VR: ENTRY ABORTED' "$BB" 2>/dev/null || true)
say 'seta r_renderWidth 1600'; sleep 1
say 'seta r_renderHeight 900'; sleep 1
say 'seta r_renderScale 4'; sleep 1
say 'vid_restart'; sleep 14
# THE CONTROL. Without this the case proves nothing: it has to be shown that
# these cvars really do move the extent when VR is not holding it.
zone_assert "the latent cvars DO re-pin the 2D extent (control)" EYENOW 'engine=1600x900px'
say 'q3evr 1'; sleep 16
WANT=$(grep -Eo 'per-eye target [0-9]+x[0-9]+px' "$BB" | tail -1 | grep -Eo '[0-9]+x[0-9]+')
[ -n "$WANT" ] || die "the VR loop never published a per-eye target to compare against"
zone_assert "VR's per-eye extent lands anyway ($WANT)" EYENOW "engine=${WANT}px"
zone_assert "...with the VR path armed" EYENOW 'vr=on'
A_NOW=$(grep -c 'VR: ENTRY ABORTED' "$BB" 2>/dev/null || true)
if [ "${A_NOW:-0}" -le "${ABORTS_PRE:-0}" ]; then
  printf '   PASS  the entry did not abort with the archived cvars set\n'
else
  printf '   FAIL  the entry aborted with archived render-size cvars set (%s -> %s)\n' \
         "$ABORTS_PRE" "$A_NOW" >&2; FAILED=1
fi
say 'q3evreye'; sleep 2
CVREF_POST=$(lastline EYENOW | grep -Eo 'cvarrefused=[0-9]+' | cut -d= -f2)
# IDENTITY, not just outcome: the renderer must say it refused the cvar, so a
# future extent that happens to look right for another reason cannot pass here.
if [ "${CVREF_POST:-0}" -gt "${CVREF_PRE:-0}" ]; then
  printf '   PASS  the renderer refused the archived cvar by name (cvarrefused %s -> %s)\n' \
         "$CVREF_PRE" "$CVREF_POST"
else
  printf '   FAIL  the renderer never recorded refusing r_renderScale (%s -> %s)\n' \
         "${CVREF_PRE:-none}" "${CVREF_POST:-none}" >&2; FAILED=1
fi
say 'q3evr 0'; sleep 8
say 'seta r_renderScale 0'; sleep 1
say 'seta r_renderWidth 800'; sleep 1
say 'seta r_renderHeight 600'; sleep 1
say 'vid_restart'; sleep 14
say 'q3evreye'; sleep 2
EXT_RESTORED=$(lastline EYENOW | grep -Eo 'engine=[0-9]+x[0-9]+px' | head -1)
if [ "$EXT_RESTORED" != "engine=1600x900px" ] && [ -n "$EXT_RESTORED" ]; then
  printf '   PASS  the 2D extent follows the window again (%s)\n' "$EXT_RESTORED"
else
  printf '   FAIL  the 2D extent is still the cvar-pinned one (%s)\n' "${EXT_RESTORED:-none}" >&2
  FAILED=1
fi

# --- 4g. THE STATES A SERVER OWNS (R4.1) ------------------------------------
# Every VR case above this line runs inside a world the app itself started and
# never leaves. Multiplayer is the first thing this port does where someone else
# decides when the world exists: the connect handshake, the map the server
# picked, the round ending, and the disconnect are all states in which there is
# no world to draw, and until R4.1 the dump family had no word for any of them.
# A VR frame taken during one could only be described as "the world did not
# render", which is also what a bug looks like.
#
# The whole section runs against a LOCAL listen server. The public master
# servers work (scripts/zz-probe-mp.sh proves that, and joined a real one), but
# a suite that fails when someone else's server reboots is a suite that gets
# ignored, so nothing here touches the internet — the one address it dials is a
# loopback port with nothing behind it, on purpose.
echo "== 4g. the connection states, from the panel side"
say 'q3evr 1'; sleep 12
say 'q3evrpose 0 0 0 1.60 0'; sleep 2

# 4g-i. The live local game, described. This is also the CONTROL for everything
# below it: `intermission=0` and `state=active` here are what make the
# intermission and disconnect assertions mean something rather than describing a
# client that was never connected in the first place.
zone_assert "NETNOW describes a live local game" NETNOW \
  'state=active\(8\) .*map=maps/q3dm1\.bsp snapvalid=1 ' q3evrnet
zone_assert "...as ordinary play, not an intermission" NETNOW \
  'pmtype=0\(normal\) intermission=0 ' q3evrnet
# The simulation is ADVANCING, which is a different claim from being connected:
# a client receiving nothing reads as active with a frozen snapshot counter.
say 'q3evrnet'; sleep 2
MP_SNAP1=$(lastline NETNOW | grep -Eo 'snapnum=-?[0-9]+' | cut -d= -f2)
sleep 6
say 'q3evrnet'; sleep 2
MP_SNAP2=$(lastline NETNOW | grep -Eo 'snapnum=-?[0-9]+' | cut -d= -f2)
if [ "${MP_SNAP2:-0}" -gt "${MP_SNAP1:-0}" ] 2>/dev/null; then
  printf '   PASS  snapshots advance while connected (%s -> %s)\n' "$MP_SNAP1" "$MP_SNAP2"
else
  printf '   FAIL  the snapshot counter did not advance (%s -> %s)\n' \
         "${MP_SNAP1:-none}" "${MP_SNAP2:-none}" >&2; FAILED=1
fi

# 4g-ii. THE CONNECT SCREEN. CL_Connect_f clears the key catcher, so a client
# dialling a server is not "a menu is up" — it is the one state whose present
# reason is genuinely `not-connected`, and it is the state a player spends
# several seconds in every time they join. It must be a PANEL frame: presenting
# `world` here means handing the compositor whatever imagery the eye textures
# happen to still hold, which in full immersion is the previous map or black.
#
# Deterministic without a server: a loopback port with nothing listening leaves
# the client retrying in CA_CONNECTING for as long as this needs.
echo "== 4g-ii. the connect screen is a panel frame, not a stale world"
say 'disconnect'; sleep 6
say 'connect 127.0.0.1:27961'; sleep 4
zone_assert "the client is dialling" NETNOW 'state=(connecting\(3\)|challenging\(4\))' q3evrnet
zone_assert "...and the eyes are shown the panel, named as not-connected" MODENOW \
  'mode=VR .*present=panel reason=2\(not-connected\)'
shot 05b-vr-connecting
say 'disconnect'; sleep 6

# 4g-iii. INTERMISSION. The round ends, cgame swaps the player into an
# intermission camera and puts the scoreboard up, and the frame is STILL a world
# frame — Quake III draws the intermission from a camera inside the map, so
# `present=world` here is correct and a panel would be the regression. What
# changes is the playerstate, which is the only signal a shell that cannot ask
# cgame anything ever gets: it is what already drives the scoreboard quad.
#
# Reached by lowering the frag limit and letting a bot earn one frag against a
# player who is standing still. `fraglimit` is read live by the game, so no map
# reload is needed to arm it.
echo "== 4g-iii. an intermission is a world frame with the scoreboard up"
say 'fraglimit 1'; sleep 2
say 'devmap q3dm1'; sleep 28
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
say 'addbot sarge 5'; sleep 4
MP_INTER=0
for _i in $(seq 1 30); do
  say 'q3evrnet'; sleep 2
  # Printed every poll, not just at the end: a silent wait that eventually
  # fails says only "no intermission", when the answer worth having is whether
  # the bot ever spawned, whether the player was ever killed, and whether the
  # connection was healthy the whole time.
  printf '   poll %2s: %s\n' "$_i" \
    "$(lastline NETNOW | grep -Eo 'state=[a-z]+\([0-9]+\) .*pmtype=[0-9-]+\([a-z?]+\)')"
  if lastline NETNOW | grep -q 'intermission=1'; then MP_INTER=1; break; fi
  sleep 2
done
if [ "$MP_INTER" = 1 ]; then
  printf '   PASS  the round reached an intermission (%s)\n' \
         "$(lastline NETNOW | grep -Eo 'pmtype=[0-9]+\([a-z]+\)')"
else
  printf '   FAIL  no intermission after ~2 minutes with fraglimit 1 and a bot\n' >&2
  FAILED=1
fi
zone_assert "the intermission still presents the WORLD, not the panel" MODENOW \
  'mode=VR .*present=world reason=0\(world\)'
zone_assert "...and the shell knows the scoreboard is up" PANELNOW 'scoreboardup=1' q3evrpanel
shot 05c-vr-intermission
pixels "the intermission frame is not black" "$PFX-05c-vr-intermission.png" nonblack --min 20000

# 4g-iv. DISCONNECT. Back to the main menu, in VR, with nothing left over: the
# state reads disconnected rather than a stale active, the address and map are
# gone (a stale address is how a reconnect goes to yesterday's server), and the
# frame is the panel again — named `menu-up` this time, not `not-connected`,
# because the menu really is up.
echo "== 4g-iv. disconnecting lands back on the menu panel, clean"
say 'disconnect'; sleep 8
zone_assert "the connection is fully torn down" NETNOW \
  'state=disconnected\(1\) addr=none map=none snapvalid=0 snapnum=-1 ' q3evrnet
zone_assert "...and the eyes are on the menu panel" MODENOW \
  'mode=VR .*present=panel reason=3\(menu-up\)'
zone_assert "...with no scoreboard left standing" PANELNOW 'scoreboardup=0' q3evrpanel

# 4g-v. RE-ENTER VR AFTER A DISCONNECT. The exit/re-enter cycles in section 5
# all happen inside a live game; this is the other order, and it is the one a
# player actually performs (leave the server, take the headset off, come back).
# The thing being checked is that a VR session begun with no world to draw can
# still take one when the next map arrives.
echo "== 4g-v. VR re-entered from the menu can still take a world"
say 'q3evr 0'; sleep 8
zone_assert "left VR from the disconnected menu" MODENOW 'mode=2D .*owner=link'
say 'q3evr 1'; sleep 12
zone_assert "re-entered VR with no server" MODENOW 'mode=VR .*present=panel'
zone_assert "...having presented no world frame blind" FRAMENOW 'blindworld=0 ' q3evrframe
# The state this section borrowed has to be given back: section 5 onward is
# written against the live q3dm1 the earlier sections established, and a frag
# limit of 1 would drop the next section into an intermission mid-assertion.
say 'fraglimit 20'; sleep 2
say 'map q3dm1'; sleep 28
say 'q3evrpose 0 0 0 1.60 0'; sleep 2
zone_assert "a fresh map after the disconnect renders the world again" MODENOW \
  'mode=VR .*present=world reason=0\(world\)'
zone_assert "...and the frag limit is back where the later sections expect it" NETNOW \
  'state=active\(8\) .*intermission=0 ' q3evrnet
shot 05d-vr-world-again
pixels "the re-taken world is not black" "$PFX-05d-vr-world-again.png" nonblack --min 20000
snap 05e-after-mp
say 'q3evr 0'; sleep 8

# --- 5. exit / re-enter x3 ---------------------------------------------------
# R2.1 fix 8: `q3evrpose off` first — this section's own re-entries must not
# inherit a synthetic pose left active by an earlier section (that would
# mask exactly the thing being checked, since a fresh synthetic injection
# recomputes the head pose every frame regardless of what carried over). With
# it off, the simulator's own tracked pose answers with a flat identity, so a
# clean re-entry's head yaw/pitch has a deterministic zero to be checked
# against.
say 'q3evrpose off'; sleep 2
echo "== 5. exit and re-enter VR three times"
for i in 1 2 3; do
  say 'q3evr 0'; sleep 6
  alive || die "the app died leaving VR (cycle $i)"
  zone_assert "cycle $i: back to 2D" MODENOW 'mode=2D .*owner=link'
  say 'q3evr 1'; sleep 8
  alive || die "the app died re-entering VR (cycle $i)"
  zone_assert "cycle $i: back in VR" MODENOW 'mode=VR .*owner=vr'
  # Re-entering DURING A LIVE GAME is the case that inherits the previous
  # session's arbitration. A WORLD verdict with no eye copy to show is a black
  # frame in full immersion, so it is counted rather than assumed.
  zone_assert "cycle $i: no world frame was presented blind" FRAMENOW 'blindworld=0 ' q3evrframe
  # R2.1 fix 8: the head pose is carried inside the mutex-protected pair now
  # and zeroed on both ends of a session, specifically so a fresh entry does
  # not start from the PREVIOUS session's final head orientation and visibly
  # slew away from it. A clean re-entry with no tracked head motion (the
  # simulator's own identity pose, `q3evrpose off` above) must read a clean
  # zero, not whatever cycle i-1 last saw. This is a regression guard on the
  # observable behaviour the fix targets — the underlying race itself (a
  # cross-thread read/write with no lock between them) is not something a
  # single deterministic run can prove absent; it is closed by the mutex
  # refactor itself (Q3EVR.m), reviewed as a code change, not detected here.
  zone_assert "cycle $i: head yaw/pitch are clean on re-entry, not carried over" HEADNOW \
    'yaw=-?0\.[0-4]deg pitch=-?0\.[0-4]deg' q3evrhead
  # And the AIMNOW identity — always an identity by construction, but a
  # mutex refactor that broke the plumbing between the compositor and engine
  # threads would show up here as a stuck or garbage sent angle.
  zone_assert "cycle $i: the head-aim identity holds immediately on re-entry" AIMNOW \
    'active=1 .*delta=-?0\.0000deg hookenabled=1' q3evraim
done
shot 06-vr-reentered
say 'q3evr 0'; sleep 6

# --- 6. the 3D panel mode is unregressed ------------------------------------
echo "== 6. 2D -> 3D -> 2D still works"
say 'stereo'; sleep 8
alive || die "the app died entering 3D"
zone_assert "3D panel mode is entered" MODENOW 'mode=3D'
shot 07-3d-panel
pixels "the 3D panel is not a black screen" "$PFX-07-3d-panel.png" nonblack --min 20000
say 'stereo'; sleep 6
zone_assert "and back to 2D" MODENOW 'mode=2D .*owner=link'
snap 08-after-3d

# --- 6b. the archived cvars VR overrode came back ---------------------------
# VR sets r_ext_multisample 0 (single-sample snapshots are what make the depth
# handoff valid) and flattens the 3D HUD icons. Both are ARCHIVED, so a config
# write with them still overridden bakes them into the player's own config
# permanently. cg_drawGun is no longer one of them (R2 item 3: VR stopped
# overriding it) — the check below is now really "it was never touched",
# which is the correct assertion now that there is nothing to restore.
echo "== 6b. archived cvars are restored after VR"
# The seeded value was 4, and r_ext_multisample is LATCHED — so the number that
# must survive VR is the one the player asked for, not the one that happened to
# be live before the restart. Anything else (0, or VR's old override) means the
# override leaked into the player's choice.
MSAA_AFTER=$(ask 'r_ext_multisample' | tr -d '\r' | grep -Eo 'is:"[^"^]*' | head -1)
echo "   post-VR: $MSAA_AFTER (seeded 4)"
if [ "$MSAA_AFTER" = 'is:"4' ]; then
  printf '   PASS  the player 4x MSAA choice survived VR (VR forces single-sample internally)\n'
else
  printf '   FAIL  r_ext_multisample was seeded to 4 and reads %s after VR\n' "$MSAA_AFTER" >&2
  FAILED=1
fi
GUN_AFTER=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
echo "   post-VR: $GUN_AFTER (seeded $GUN_BEFORE)"
if [ "$GUN_AFTER" = "$GUN_BEFORE" ]; then
  printf '   PASS  cg_drawGun is unchanged by a VR session (R2: nothing to stash — it was never overridden)\n'
else
  printf '   FAIL  cg_drawGun was %s before VR and is %s after — something is still touching it\n' "$GUN_BEFORE" "$GUN_AFTER" >&2
  FAILED=1
fi

# --- 6c. VR settings migration is a no-op once stamped (R2 item 6) ---------
# v1 has nothing to migrate FROM (six brand-new rows), so what is testable
# here is the property that actually matters for every LATER round too: once
# Q3E_VR_MigrateSettings has stamped q3e_vr_mig, it must never touch a value
# again — a build that re-ran migration on every launch would keep stamping
# over a value the player deliberately chose. A distinct sentinel (177, not
# the 140 default, not a round number anyone would pick by coincidence) seeded
# with the stamp ALREADY set to 1 must survive a full relaunch unchanged.
#
# R2.1: seeded through the CONSOLE (`q3evrturn`, the same seam a real
# player's own setting change goes through, which fix 6b made persist via
# Q3E_VR_PersistTuning) rather than `simctl spawn defaults write` — see the
# q3e_prefs_* helpers' own comment for why: once the LIVE APP has written a
# key, the simulator's cfprefsd caches it, and an external `defaults write`
# for that SAME key can report success while a later app launch still reads
# what the app itself last wrote. Seeding through the app sidesteps the
# mismatch instead of fighting it, and is arguably the MORE honest test of
# "a value the player deliberately chose" — an actual player never runs
# `defaults write` by hand either. `mig` needs no seeding at all: every
# earlier section in this run has already booted the app at least once, and
# Q3E_VR_MigrateSettings stamps it on the very first boot of any run.
echo "== 6c. VR settings migration is idempotent (sentinel survives a relaunch)"
say 'q3evrturn smooth 177'; sleep 2
zone_assert "the sentinel is live before the relaunch" SETTINGSNOW \
  "turnspeed=177deg/s.*mig=12" q3evrsettingsdump
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back after the migration-sentinel relaunch"
sleep 6
zone_assert "the sentinel turn speed survived the relaunch untouched" SETTINGSNOW \
  "turnspeed=177deg/s.*mig=12" q3evrsettingsdump
# R2.1 fix 14: the seeded sentinel (turnspeed=177, mig=12) does its job the
# moment the assertion above reads it — leaving it in the container past
# that point serves nothing and actively hurts: this app process keeps
# running for the REST of this suite (sections 7+), and — the actual
# incident this finding names — the container survives after the suite
# exits, so the very next person to launch the app by hand (feel-testing on
# a project whose acceptance bar IS feel parity) boots with turn speed 177
# and no idea why. Cleaned immediately, not just at the TOP of the next
# suite run (the boot-time sweep near the top of this script also cleans
# every q3e_vr_* key, which is what protects the NEXT automated run from a
# leftover — this protects a hand session between now and then). The app
# ITSELF just wrote this key, so — per the q3e_prefs_* helpers' own comment
# — only editing its OWN container-scoped plist and kicking cfprefsd
# actually clears what the next launch will see; `simctl spawn defaults
# delete` was verified NOT to (the exact mechanism behind this finding, one
# layer further down: a delete that reports success and does nothing).
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch after sentinel cleanup failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back after the sentinel cleanup relaunch"
sleep 6
zone_assert "the sentinel is GONE — the sheet's own default (140), not 177, is what boots now" \
  SETTINGSNOW "turnspeed=140deg/s" q3evrsettingsdump

# --- 6d. the v2 migration actually runs for the people it was written for ---
# (R2.2 fix 2.) The height-trim fold-in shipped in R2.1 UNDER a `stamp >= 1`
# guard the previous build had already satisfied — so on every install that had
# run that build (the only builds that ever wrote the retired q3e_vr_height
# key) migration returned before reaching it, the key was never folded in, and
# the player's height trim silently reset to 0 on upgrade: exactly the data
# loss the fold-in was added to prevent, invisible because a migration that
# runs for nobody reads as done. The suite could not see it either — it wipes
# every q3e_vr_* key, the stamp included, at the top of every run.
#
# Both halves seed a v1-SHAPED store (a real trim in the retired key, no
# metres-side trim, and a stamp) directly in the app's own container plist,
# with a verified write. The two differ only in the stamp, which is the thing
# under test — and that makes the pair its own fault injection: at stamp 2 the
# step is correctly skipped and the trim does NOT appear, at stamp 1 it must.
echo "== 6d. the settings migration folds a retired key in, once, at the right stamp"
# R3: THE POSITIVE CASE RUNS FIRST, and the order is the whole point.
#
# The v2 fold is guarded on `!Q3E_VR_HasPersistedHeightTrim()` — it declines to
# overwrite a trim that already exists, which is correct. But the app WRITES
# that key on every boot (q3e_vr_apply_tuning pushes the persisted trim back
# through its own setter), so ANY preceding launch in this section leaves it
# behind, and the fold then correctly declines for a reason that has nothing to
# do with what the case is testing. The delete before the seed is a race against
# the runtime's preference daemon that this script's own header explains cannot
# be won reliably for a key the app itself has written.
#
# So the fold case goes first, against the store the section-top sweep left
# clean, and nothing in this run has launched the app since. Deterministic by
# construction rather than by winning a race.
# THE SEED IS VERIFIED THROUGH THE APP, not through the file.
#
# Measured with a standalone probe (both plists printed on either side of a
# launch): once the runtime's preference daemon is warm for this bundle, editing
# the container plist and killing cfprefsd does NOT reliably change what the next
# launch reads. The probe seeded stamp 2 into a file that read back 2, and the
# app reported 3 — the value the PREVIOUS launch had written — while the file
# still said 2. A file-side check cannot see that, so a case that seeds a stamp
# and asserts on the result can pass or fail for reasons that have nothing to do
# with the migration.
#
# So: seed, launch, and ask the APP what stamp it actually read. Retry the whole
# cycle if it read something else. Only once the app is provably looking at the
# seeded store does the migration assertion below mean anything — and a seed that
# never lands after three tries is a harness failure that says so, loudly, rather
# than a migration verdict.
q3e_seed_v1_store () { # -> 0 when the APP is provably reading the seeded store
  local attempt line
  for attempt in 1 2 3; do
    xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
    sleep 2
    q3e_prefs_delete_vr_keys
    q3e_prefs_delete_keys Q3EVRHeightTrimMetres
    q3e_prefs_kick_cfprefsd
    sleep 1
    q3e_prefs_set q3e_vr_mig real 1
    q3e_prefs_set q3e_vr_height real 12.0
    SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
    SIMCTL_CHILD_Q3E_CONSOLE=1 \
      xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null ||
        die "relaunch for the v1 upgrade case failed"
    ok=0
    for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
    [ "$ok" = 1 ] || die "the app did not come back for the v1 upgrade case"
    sleep 6
    say 'q3evrsettingsdump'; sleep 2
    line=$(lastline SETTINGSNOW)
    # The app read a v1 store iff it MIGRATED off it: a store it saw as already
    # stamped current is one where the seed never arrived.
    if printf '%s' "$line" | grep -Eq 'height=\+12\.0in'; then
      printf '   the app is reading the seeded v1 store (attempt %s)\n' "$attempt"
      return 0
    fi
    printf '   the seeded stamp did not reach the app (attempt %s) — re-seeding\n' "$attempt"
  done
  return 1
}
if q3e_seed_v1_store; then
  zone_assert "a v1 store's saved trim survives the upgrade, in the one store that is left" \
    SETTINGSNOW 'height=\+12\.0in' q3evrsettingsdump
  zone_assert "...and the stamp moved to the current one, so it will not run again" SETTINGSNOW \
    'mig=12' q3evrsettingsdump
else
  printf '   FAIL  the v1 migration store could not be seeded in three tries — the simulator'"'"'s\n' >&2
  printf '         preference daemon kept serving a cached value, so this case tested nothing.\n' >&2
  printf '         (The migration path itself is verified by a cold-daemon probe; see the R3 decision record.)\n' >&2
  FAILED=1
fi

# ...and the NEGATIVE half second. Seeded at stamp 2, the v2 step is already
# past, so the retired key must NOT be folded in and the trim must stay 0. The
# stamp assertion is what stops this passing vacuously: reading 3 back proves
# migration RAN (so the seeded 2 was really what it saw) rather than that a
# stale 3 was sitting there — at a stale 3 migration returns immediately and
# never rewrites anything, but so does an unseeded store, which is why the trim
# and the stamp are both required.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_delete_keys_verified Q3EVRHeightTrimMetres || FAILED=1
q3e_prefs_set q3e_vr_mig real 2
q3e_prefs_set q3e_vr_height real 12.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the already-migrated case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the already-migrated case"
sleep 6
zone_assert "PROOF the assertion above can fail: at stamp 2 the v2 step is already past and the trim stays 0" \
  SETTINGSNOW 'height=\+0\.0in.*mig=12' q3evrsettingsdump

# --- 6c-iv. the v6/v7 steps: a stored value DELETED so a new default lands ---
# Two rounds of tuning on glass turned stored numbers into shipped defaults, and
# the migration for that is a DELETE: an install that already has the old value
# stored would read its own tuning back and never see the default it was the
# source of. v6 (R3.3) does it for Render Quality, HUD Size, HUD Height, Weapon
# Size and the grip rig; v7 (R3.4) for Crosshair Size, Aim Pitch Trim, Grip
# Right, Grip Up and Grip Pitch — and for the trim the delete is load-bearing
# rather than cosmetic, because +2 is built into the aim path now and a stored
# +2 on top of it would aim four degrees high.
#
# GRIP FORWARD used to be the key this case watched SURVIVE — v7 spared it and
# R3.6's v9 mapped it. R4.0 ends that: the grip is six hardcoded constants, and
# v11 deletes every grip key there has ever been. So the seeded 10.0 is here now
# as the thing that must NOT come back, and the live grip must read the shipped
# hardcode whatever the store says. Its own dedicated case (6c-iv.3, with the
# fault injection) proves the DELETE; this one proves the store cannot reach the
# weapon even for the one launch before the delete lands.
#
# HUD Size is seeded too and must SURVIVE, because v6 is past — the same launch
# therefore proves the delete steps are scoped to their own keys rather than a
# wipe.
#
# (This case used to test the v4 step — a stored q3e_vr_hudscale becoming HUD
# Size. That path is dead: v6 deletes the key v4 seeds, so the old assertion
# would now be asserting the default and proving nothing.)
#
# 1.85 / +7 / 3.5 are deliberate non-defaults, none of them a value any of these
# rows ships or clamps to, so a number that arrived by some other route is
# visible as itself.
echo "== 6c-iv. the delete-migrations land the new defaults, and spare the one key that is kept"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_delete_keys Q3EVRHeightTrimMetres
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 6
q3e_prefs_set q3e_vr_hudsize real 1.85
q3e_prefs_set q3e_vr_aimtrim real 7.0
q3e_prefs_set q3e_vr_xhairsize real 1.5
q3e_prefs_set q3e_vr_grip_f real 10.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v6 upgrade case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v6 upgrade case"
sleep 6
zone_assert "the seeded crosshair size and aim trim are gone, and the HUD Size v6 already passed is not" \
  SETTINGSNOW 'xhairsize=0\.75x xhairrow=2\.0x.*hudsize=1\.85x.*aimtrim=\+0\.0deg.*mig=12' q3evrsettingsdump
GRIP_KEPT=$(ask 'q3evrgrip' | grep -Eo 'offset=\(f[+-]?[0-9.]+' | head -1)
echo "   grip forward after the upgrade: '$GRIP_KEPT' (seeded 10.0, expected the hardcoded -6.0)"
if [ "$GRIP_KEPT" = 'offset=(f-6.0' ]; then
  printf '   PASS  a stored Grip Forward of 10.0 did not reach the weapon — the hardcode is what boots\n'
else
  printf '   FAIL  Grip Forward was seeded 10.0 and reads %s — expected offset=(f-6.0\n' \
         "${GRIP_KEPT:-none}" >&2
  FAILED=1
fi
zone_assert "...and the whole grip is this round's hardcoded set, not a store's opinion of it" \
  VIEWMODELNOW 'grip=\(f-6\.0,r-0\.5,u0\.0\)u gripang=\(p0\.0,y0\.0,r0\.0\)deg' q3evrviewmodel

# ...and the NEGATIVE half, which is what stops the assertion above passing on a
# store it never read: seeded at the CURRENT stamp the steps are already past, so
# the very same values must survive untouched. If the positive case were passing
# by accident — the app never seeing the seed, or the defaults arriving from
# somewhere else — this one would report the defaults too.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 10
q3e_prefs_set q3e_vr_xhairsize real 1.5
q3e_prefs_set q3e_vr_aimtrim real 7.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the already-migrated case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the already-migrated case"
sleep 6
zone_assert "PROOF the assertions above can fail: at stamp 10 the same seeded values are left alone" \
  SETTINGSNOW 'xhairsize=1\.50x.*aimtrim=\+7\.0deg.*mig=12' q3evrsettingsdump

# --- 6c-iv.1. the v8 step: Grip Right's travel narrows to +/-2.5 (R3.5) -----
# v7 shipped -3.0 and persisted it, so every install that ran 1.0.4.10 holds a
# stored value now OUTSIDE its own row's range. The step deletes the key so the
# new -2.5 default lands at once, instead of the slider sitting pinned at an end
# it cannot represent until some unrelated drag makes the setter clamp it.
echo "== 6c-iv.1. a stored Grip Right of -3.0 is replaced by the new default (v8)"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 7
q3e_prefs_set q3e_vr_grip_r real -3.0
q3e_prefs_set q3e_vr_grip_f real 10.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v8 upgrade case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v8 upgrade case"
sleep 6
# R4.0: both the seeded -3.0 and the seeded 10.0 are gone, and the answer is the
# hardcoded set — v8's own delete is now subsumed by v11's, which is what this
# assertion reads. Kept because the SEED is the point: a store carrying a stale
# out-of-range grip must not reach the weapon by any route.
zone_assert "neither seeded grip value reached the weapon — the hardcoded set did" VIEWMODELNOW \
  'grip=\(f-6\.0,r-0\.5,u0\.0\)u gripang=\(p0\.0,y0\.0,r0\.0\)deg' q3evrviewmodel
# The session override still clamps, which is what keeps `q3evrgrip` an
# instrument rather than a way to lose the weapon in the next room.
GRIP_CLAMPED=$(ask 'q3evrgrip -80 -9 4 2' | grep -Eo 'offset=\(f[+-]?[0-9.]+,r[+-]?[0-9.]+')
echo "   q3evrgrip -80 -9 4 2 answered: '$GRIP_CLAMPED'"
# R4.0: the override clamps every offset to +/-20u and every angle to +/-20deg,
# and it no longer FORCES right/up/pitch — forcing them was R3.7's way of
# defending a hardcode that the store could still argue with, and there is no
# store to argue any more. So -80 clamps to -20 and -9 lands as -9.
if [ "$GRIP_CLAMPED" = 'offset=(f-20.0,r-9.0' ]; then
  printf '   PASS  the session override clamps -80 to the -20 floor and takes an in-range -9 as itself\n'
else
  printf '   FAIL  the grip override accepted a value outside its span: %s\n' "${GRIP_CLAMPED:-none}" >&2
  FAILED=1
fi
say 'q3evrgrip reset'; sleep 2

# --- 6c-iv.2. what is LEFT of the v9 step: the Aim Pitch Trim delete ---------
# R3.6's v9 mapped the three grip offsets into the anchor-point frame — the only
# MAPPING migration this function ever had. R4.0 REMOVED that half: every store
# it fires for (stamp < 9) also satisfies v11 (stamp < 11), which deletes all six
# grip keys, so the arithmetic mapped a value and the next step dropped it in the
# same launch. A migration that runs for nobody reads as done, so it went.
#
# What survives is the DELETE that rode with it, and it is the load-bearing half:
# Q3E_VR_AIM_PITCH_BIAS went from +2 to 0, so the -2 the 1.0.4.11 round dialled
# on top of that +2 would now be applied to a raw axis and aim two degrees low.
# The seed is that exact -2. Weapon Size is seeded too and must SURVIVE — no step
# touches it at this stamp — which is what stops this case reading as a wipe.
echo "== 6c-iv.2. the v9 step deletes an aim trim the zeroed bias makes wrong"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 8
q3e_prefs_set q3e_vr_gunscale real 0.5
q3e_prefs_set q3e_vr_grip_f real 10.0
q3e_prefs_set q3e_vr_grip_r real -2.5
q3e_prefs_set q3e_vr_grip_u real 4.0
q3e_prefs_set q3e_vr_aimtrim real -2.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v9 upgrade case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v9 upgrade case"
sleep 6
zone_assert "the stored Weapon Size survived — the step is scoped, not a wipe" \
  SETTINGSNOW 'gunscale=0\.50x gunrow=0\.67x' q3evrsettingsdump
zone_assert "the stored aim trim, which the zeroed bias makes wrong, is gone" \
  SETTINGSNOW 'aimtrim=\+0\.0deg' q3evrsettingsdump
zone_assert "...and none of the three seeded grip offsets reached the weapon" \
  VIEWMODELNOW 'grip=\(f-6\.0,r-0\.5,u0\.0\)u' q3evrviewmodel

# The negative half: the identical store seeded at the CURRENT stamp must come
# back untouched. Without it, a build whose v9 step had quietly stopped running
# and one that ran it on everybody would look the same from here.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 11
q3e_prefs_set q3e_vr_gunscale real 0.5
q3e_prefs_set q3e_vr_grip_f real 10.0
q3e_prefs_set q3e_vr_grip_r real -2.5
q3e_prefs_set q3e_vr_grip_u real 4.0
q3e_prefs_set q3e_vr_aimtrim real -2.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the already-mapped case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the already-mapped case"
sleep 6
zone_assert "PROOF the v9 assertion can fail: at stamp 11 the stored aim trim is left alone" \
  SETTINGSNOW 'aimtrim=-2\.0deg' q3evrsettingsdump
# ...and the grip still reads the hardcode, because that has nothing to do with
# the stamp: the store is not consulted at any stamp.
zone_assert "...and the grip is the hardcoded set even where no migration ran" \
  VIEWMODELNOW 'grip=\(f-6\.0,r-0\.5,u0\.0\)u' q3evrviewmodel

# --- 6c-iv.3. the v11 step: every grip key leaves the store (R4.0) ----------
# the maintainer's verdict off the R3.7 dialling row was a single number, not a span, so
# the whole grip became six constants and the settings sheet's temporary tuning
# rig came out with the row. That makes a stored grip key pure hazard: nothing
# reads it, so it changes no behaviour, and it holds a real number somebody
# dialled that will read as authoritative to whoever finds it next.
#
# A DELETE with no behavioural consequence is the hardest kind of migration to
# test — which is why SETTINGSNOW carries `gripkeys=`, the count of retired grip
# keys the store still holds. Two keys are seeded: grip_f, the one R3.7
# deliberately spared, and gripang_y, which no step has EVER deleted (v6 wiped
# it, then PersistTuning wrote it back on the next console command and it has sat
# there since R3.2). Both must be gone.
echo "== 6c-iv.3. the v11 step deletes every grip key there has ever been"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 10
q3e_prefs_set q3e_vr_grip_f real 10.0
q3e_prefs_set q3e_vr_gripang_y real 3.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v11 upgrade case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v11 upgrade case"
sleep 6
zone_assert "both seeded grip keys are gone from the store, and the stamp moved" SETTINGSNOW \
  'gripkeys=0 haptics=[01] .*mig=12' q3evrsettingsdump
zone_assert "...and the live grip is the hardcoded set the constants state" VIEWMODELNOW \
  'grip=\(f-6\.0,r-0\.5,u0\.0\)u gripang=\(p0\.0,y0\.0,r0\.0\)deg' q3evrviewmodel
# The keys must STAY gone. This is the assertion that stands in for "the sheet's
# grip row is removed", which no console can see directly: every settings apply
# runs Q3E_VR_PersistTuning, and R3.2's version of it wrote all six keys on every
# call — so a build that had removed the ROW but left the write-back (or left the
# row, whose -changed handler writes it too) puts them straight back. A console
# tuning command is the same seam, so one is enough to catch it.
say 'q3evrturn smooth 155'; sleep 2
zone_assert "...and a settings apply does not write any of them back" SETTINGSNOW \
  'turnspeed=155deg/s.*gripkeys=0' q3evrsettingsdump
say 'q3evrgrip -3'; sleep 2
zone_assert "...nor does the session override, which is not persisted either" SETTINGSNOW \
  'grip=\(f-3\.0,r-0\.5,u0\.0\)u.*gripkeys=0' q3evrsettingsdump
say 'q3evrgrip reset'; sleep 2

# THE FAULT INJECTION. An assertion that cannot fail is a decoration, and
# `gripkeys=0` is exactly the shape that passes vacuously — an empty store reads
# 0 whether the step ran or not. Seeding the SAME two keys at the CURRENT stamp
# bypasses migration entirely: the guard returns before v11, nothing is deleted,
# and the count must come back 2. If it comes back 0 here, something other than
# the migration is clearing those keys and the case above proves nothing.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 11
q3e_prefs_set q3e_vr_grip_f real 10.0
q3e_prefs_set q3e_vr_gripang_y real 3.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the already-stamped v11 case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the already-stamped v11 case"
sleep 6
zone_assert "PROOF the delete can fail: bypassed by the stamp, both seeded keys SURVIVE" \
  SETTINGSNOW 'gripkeys=2 haptics=[01] .*mig=12' q3evrsettingsdump
# ...and the weapon is in the same place regardless, which is the whole point of
# hardcoding it: the surviving keys are clutter, not a second opinion.
zone_assert "...and the surviving keys still do not move the weapon" VIEWMODELNOW \
  'grip=\(f-6\.0,r-0\.5,u0\.0\)u' q3evrviewmodel

# --- 6c-iv.4. the v12 step: two DEFAULTS move, so two stored keys go (R4.5) --
# the maintainer's 1.0.4.15 verdicts: Sharpen ships at 50% and the HUD cluster sits at
# 0 degrees, not the R3.3 -2. Both rows have been on the shipped sheet for at
# least one build, so every install is holding a stored value for them — written
# by the first apply, not by the player — and a stored value beats a default
# forever. Without the delete the new numbers reach nobody who has already
# launched the app, which is everybody.
#
# Unlike v11's grip keys, this delete IS behaviourally visible: the two fields
# come back as the new defaults rather than as a count. The seeds are values no
# row ships or clamps to (90% and -9.0 degrees), so a number arriving by any
# other route is visible as itself.
echo "== 6c-iv.4. a stored Sharpen and HUD Height are deleted so the new defaults land (v12)"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 11
q3e_prefs_set q3e_vr_sharpen real 0.9
q3e_prefs_set q3e_vr_hudheight real -9.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v12 upgrade case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v12 upgrade case"
sleep 6
zone_assert "both seeded values are gone and the R4.5 defaults are what the store reports" \
  SETTINGSNOW 'hudheight=\+0\.0deg.*sharpen=50% .*mig=12' q3evrsettingsdump
# ...and the LIVE engine holds the same two numbers, which is the half a store
# read cannot prove: the apply path has to have carried the new defaults into
# the blit and the HUD placement, not just left them in NSUserDefaults.
zone_assert "...and the live blit really is sharpening at 50%" EYENOW 'sharpen=50% ' q3evreye
zone_assert "...and the live HUD cluster sits at the layout's own centre" PANELNOW \
  'hudheight=\+0\.0deg' q3evrpanel

# THE FAULT INJECTION. `sharpen=50%` and `hudheight=+0.0deg` are exactly the
# shape that passes vacuously — an empty store reports both defaults whether the
# step ran or not. Seeding the SAME two values at the CURRENT stamp bypasses
# migration entirely: the guard returns before v12, nothing is deleted, and both
# seeded values must come back as themselves.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 12
q3e_prefs_set q3e_vr_sharpen real 0.9
q3e_prefs_set q3e_vr_hudheight real -9.0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the already-stamped v12 case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the already-stamped v12 case"
sleep 6
zone_assert "PROOF the delete can fail: bypassed by the stamp, both seeded values SURVIVE" \
  SETTINGSNOW 'hudheight=-9\.0deg.*sharpen=90% .*mig=12' q3evrsettingsdump

# --- 6c-v. the v5 step: HUD High/Low/Off becomes HUD On/Off (R3.2 item 4) ---
# The stored number keeps parsing and changes meaning, which is the case a stamp
# exists for. 1 meant Low — the HUD SHOWN, and the shipped default — and now
# means Off. Without the step, every install that had ever touched that row
# would come back from the upgrade with no HUD at all.
#
# The seed is stamp 4 with q3e_vr_hud = 1 (Low), and 2 (Off) is checked in the
# same pass through a second launch, because "both old positions become On" and
# "Off stays Off" are two different claims and one of them passing does not
# imply the other.
echo "== 6c-v. a stored HUD position becomes the right side of On/Off (v5)"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 4
q3e_prefs_set q3e_vr_hud real 1
q3e_prefs_set q3e_vr_panelsize real 1.85
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v4 upgrade case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v4 upgrade case"
sleep 6
zone_assert "a stored Low becomes On, not Off — the HUD does not vanish on upgrade" \
  SETTINGSNOW 'hud=On.*hudheight=\+0\.0deg.*mig=12' q3evrsettingsdump

# The other side: Off must stay Off. Same seed, one different number.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_kick_cfprefsd
sleep 1
q3e_prefs_set q3e_vr_mig real 4
q3e_prefs_set q3e_vr_hud real 2
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch for the v4 HUD-Off case failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back for the v4 HUD-Off case"
sleep 6
zone_assert "...and a stored Off stays Off — the step maps, it does not blanket-enable" \
  SETTINGSNOW 'hud=Off.*mig=12' q3evrsettingsdump

# Leave nothing behind (R2.1 fix 14's lesson, one key over): the seeded trim
# would otherwise be the height every hand session after this run starts at.
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_vr_keys
q3e_prefs_delete_keys Q3EVRHeightTrimMetres Q3EVRHeightBaselineMetres
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch after the migration cleanup failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back after the migration cleanup"
sleep 6
zone_assert "the seeded trim is gone — a fresh store, freshly stamped" SETTINGSNOW \
  'height=\+0\.0in.*mig=12' q3evrsettingsdump

# --- 7. killed mid-VR, relaunched clean -------------------------------------
echo "== 7. killed mid-VR, relaunch is clean"
say 'q3evr 1'; sleep 8
alive || die "the app died entering VR for the kill test"
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 3
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back after being killed in VR"
sleep 6
zone_assert "relaunch comes up in 2D, not stuck in VR" MODENOW 'mode=2D .*owner=link'
shot 08-relaunch
[ -f "$DOCS/blackbox-prev.log" ] || { echo "   FAIL  the previous session's black box was not kept" >&2; FAILED=1; }
grep -q 'PINNED' "$DOCS/blackbox-prev.log" 2>/dev/null \
  && printf '   PASS  the killed session left a readable pinned region\n' \
  || { printf '   FAIL  the killed session left no pinned region\n' >&2; FAILED=1; }
snap 09-relaunch

# --- 7b. what the stash sweep does with what it finds (R2.2 fixes 1/10/11/13)
# Two halves, because the sweep now has two answers and only one of them was
# ever tested.
#
# (i) MARK PRESENT — the last session died inside VR. Both stashed values come
#     back, including one this build's own compiled-in list no longer names
#     (R1 shipped {cg_drawGun, cg_draw3dIcons}; this build stashes only
#     cg_draw3dIcons), because an orphan left unrestored is the override it was
#     protecting against, baked into the player's config forever.
#
# (ii) MARK ABSENT — value keys with no mark are the RESIDUE OF A COMPLETED
#     cycle: R1's restore removed the mark and left both value keys behind, so
#     every clean R1 session left this exact shape on disk. Applying them is not
#     recovery — it silently reverts the player's current settings to a
#     months-old backup and writes the config. They must be DELETED and NOT
#     applied, which is what this half requires.
#
# Both halves seed through the app's own container plist with a verified,
# die-on-failure write (R2.2 fix 10 — `simctl spawn defaults write` plus no
# check at all could report a false RED against healthy code), and the section
# ends by restoring BOTH cvars and clearing the dotted stash keys (fix 11).
echo "== 7b. the stash sweep: an active mark restores, a stale one is cleared"
say 'seta cg_drawGun 1'; sleep 2
say 'seta cg_draw3dIcons 1'; sleep 2
# ARCHIVED cvars: what the next launch starts at is what q3config.cfg says, not
# what is live now — and the suite only ever KILLS this app, which never writes
# one. Without this the halves below would each start from whatever the
# PREVIOUS half's own recovery baked into the config, and "the stale value was
# applied" would be indistinguishable from "it was already 0".
say 'writeconfig q3config.cfg'; sleep 2
GUN_PRE7B=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
ICONS_PRE7B=$(ask 'cg_draw3dIcons' | grep -Eo 'is:"[^"^]*' | head -1)
echo "   pre-seed (both should read 1): $GUN_PRE7B | $ICONS_PRE7B"
[ "$GUN_PRE7B" = 'is:"1' ] && [ "$ICONS_PRE7B" = 'is:"1' ] ||
  die "7b could not put both cvars at 1 before seeding — the halves below would prove nothing"

# --- 7b-i. mark + both values: both restored --------------------------------
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_set q3e.vrStashActive bool true
q3e_prefs_set "q3e.vrStash.cg_drawGun" string 0
q3e_prefs_set "q3e.vrStash.cg_draw3dIcons" string 0
# R2.2 fix 13: and one key whose NAME is not a cvar name. The sweep builds a
# console command out of the key it finds, and this store is a file on disk
# that outlives every build — `set x;quit "0"` is two commands to Cbuf, and the
# second one closes the game on the player. The proof is threefold: the sweep
# must report it DROPPED rather than restored, the black box must say it was
# refused, and the app must still be answering the bridge afterwards, which it
# would not be if the name had been executed.
q3e_prefs_set "q3e.vrStash.x;quit" string 0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch after seeding an active stash failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back after seeding an active stash"
sleep 6
GUN_POST7B=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
ICONS_POST7B=$(ask 'cg_draw3dIcons' | grep -Eo 'is:"[^"^]*' | head -1)
echo "   post-recovery (both should now read 0, the stashed value): $GUN_POST7B | $ICONS_POST7B"
if [ "$GUN_POST7B" = 'is:"0' ] && [ "$ICONS_POST7B" = 'is:"0' ]; then
  printf '   PASS  BOTH the current-list entry AND the orphaned pre-list entry were restored\n'
else
  printf '   FAIL  recovery restored gun=%s icons=%s — expected both "0" (the stashed value)\n' \
         "${GUN_POST7B:-none}" "${ICONS_POST7B:-none}" >&2
  FAILED=1
fi
# The sweep's own accounting, from the black box — NOT from `simctl spawn
# defaults read` after the fact. Investigated directly (a targeted diagnostic
# session, not guessed): an in-app NSUserDefaults removeObjectForKey/synchronize
# is NOT reliably visible to an EXTERNAL `simctl spawn defaults read` in this
# simulator (confirmed with a plain, pre-existing, unrelated write —
# Q3E_VR_PersistHeight — which showed the identical gap; a foregrounded process
# the suite only ever kills, never backgrounds, may simply never hit the OS's
# own flush-to-disk moment). That is an environment limitation, not a claim
# about the sweep's logic, so the sweep's correctness is asserted from what the
# app itself commits to a channel that IS reliably read back — its own
# black-box log — via the EXACT counts it reports.
say 'q3evrdiag'; sleep 2
CONT_STASH="$(xcrun simctl get_app_container "$UDID" $BUNDLE data)/Documents/blackbox.log"
if grep -q 'stash sweep of q3e\.vrStash\.\* — mark=1 restored=2 dropped=1' "$CONT_STASH" 2>/dev/null; then
  printf '   PASS  the sweep reports mark=1 restored=2 dropped=1 (both real entries restored, the hostile one dropped, the mark counted as neither)\n'
else
  printf '   FAIL  the black box does not show the sweep restoring exactly 2 entries and dropping the hostile one\n' >&2
  FAILED=1
fi
if grep -q 'stash entry REFUSED' "$CONT_STASH" 2>/dev/null; then
  printf '   PASS  the hostile key name was refused by name, before any command was built from it\n'
else
  printf '   FAIL  nothing in the black box says the hostile stash key was refused\n' >&2
  FAILED=1
fi
alive && printf '   PASS  ...and the app is still answering — `set x;quit "0"` was never executed\n' \
       || { printf '   FAIL  the app is gone: the injected key name appears to have run as a command\n' >&2; FAILED=1; }

# --- 7b-ii. values with NO mark: cleared, never applied ---------------------
# The half that would have shipped a silent settings revert. Both cvars are put
# back to 1 first, so "the stale value was applied" and "nothing happened" are
# different observable states rather than the same one.
say 'seta cg_drawGun 1'; sleep 2
say 'seta cg_draw3dIcons 1'; sleep 2
say 'writeconfig q3config.cfg'; sleep 2   # the launch baseline, as above
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1
sleep 2
q3e_prefs_delete_one q3e.vrStashActive
# ...and the hostile key 7b-i seeded, which the sweep REFUSES by name rather
# than consumes — so it is still in the store, and whether it survives to be
# counted here decides between dropped=2 and dropped=3. That is state leaking
# from one sub-case into the next one's arithmetic: this half is about two
# markless entries, so exactly two is what it must find.
q3e_prefs_delete_stash_keys
q3e_prefs_set "q3e.vrStash.cg_drawGun" string 0
q3e_prefs_set "q3e.vrStash.cg_draw3dIcons" string 0
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_Q3E_CONSOLE=1 \
  xcrun simctl launch --terminate-running-process "$UDID" $BUNDLE >/dev/null || die "relaunch after seeding a STALE stash failed"
ok=0
for i in $(seq 1 60); do nc -z -G 1 127.0.0.1 $PORT 2>/dev/null && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || die "the app did not come back after seeding a stale stash"
sleep 6
GUN_STALE=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
ICONS_STALE=$(ask 'cg_draw3dIcons' | grep -Eo 'is:"[^"^]*' | head -1)
echo "   after a MARKLESS stash (both must still read 1): $GUN_STALE | $ICONS_STALE"
if [ "$GUN_STALE" = 'is:"1' ] && [ "$ICONS_STALE" = 'is:"1' ]; then
  printf '   PASS  stale stash values were NOT applied over the live settings\n'
else
  printf '   FAIL  a markless stash overwrote live settings: gun=%s icons=%s (expected both 1)\n' \
         "${GUN_STALE:-none}" "${ICONS_STALE:-none}" >&2
  FAILED=1
fi
say 'q3evrdiag'; sleep 2
if grep -q 'stash sweep of q3e\.vrStash\.\* — mark=0 restored=0 dropped=2' "$CONT_STASH" 2>/dev/null; then
  printf '   PASS  the sweep reports mark=0 restored=0 dropped=2 — the stale keys were cleared, not honoured\n'
else
  printf '   FAIL  the black box does not show the markless stash being cleared without restoring\n' >&2
  FAILED=1
fi

# --- 7b teardown. Symmetric, and it cleans up after itself ------------------
# R2.2 fix 11: BOTH cvars go back to what this section found them at, and the
# config is written while they are — these are ARCHIVED cvars, and 7b-i's own
# recovery queues a config write with them at 0, so leaving the live values
# tidy but the config stale would still hand the next hand session
# cg_draw3dIcons 0 with no explanation. The dotted stash keys go too: nothing
# else in this script has ever matched them.
say "seta cg_drawGun ${GUN_PRE7B#is:\"}"; sleep 1
say "seta cg_draw3dIcons ${ICONS_PRE7B#is:\"}"; sleep 2
say 'writeconfig q3config.cfg'; sleep 2
GUN_END=$(ask 'cg_drawGun' | grep -Eo 'is:"[^"^]*' | head -1)
ICONS_END=$(ask 'cg_draw3dIcons' | grep -Eo 'is:"[^"^]*' | head -1)
if [ "$GUN_END" = "$GUN_PRE7B" ] && [ "$ICONS_END" = "$ICONS_PRE7B" ]; then
  printf '   PASS  both cvars restored to what 7b found them at, and the config written with them\n'
else
  printf '   FAIL  7b teardown left gun=%s icons=%s (found %s | %s)\n' \
         "${GUN_END:-none}" "${ICONS_END:-none}" "$GUN_PRE7B" "$ICONS_PRE7B" >&2
  FAILED=1
fi
q3e_prefs_delete_stash_keys

# ===========================================================================
# 4h. R4.3/R4.4 — the picture rows measured, and a real mod played (charter §2)
# ===========================================================================
# Everything above this line asserts STATE. Two of the three rows this round
# adds change the PICTURE, and a row that is perfectly wired and draws nothing
# passes every state dump ever written (donor bug #15, three rounds lost to a
# geometrically-perfect invisible reticle). So Sharpen is measured off the
# frame, and the Damage Flash gate is watched actually dropping draws.
#
# Then the mod. CPMA is the charter's own acceptance mod, installed the way a
# player installs one — copied into the container's Documents, never baked into
# the bundle — and it is also where the Damage Flash gate's MOD SAFETY is
# decided: the gate keys on the shader name id's cgame registers, and the claim
# that CPMA keeps that name is worth nothing until CPMA's own blend is seen
# arriving at it.
echo "== 4h. a live baseq3 world frame to measure against"
# This section runs last, after the entry/exit cycles, so it says what state it
# needs rather than inheriting one: a re-entry that is already in VR is a no-op
# to the mode machine, and a HUD left off by an earlier case would silently
# empty the band assertions below.
say 'q3evr 1'; sleep 10
say 'q3evrhud on'; sleep 2
say 'disconnect'; sleep 5
say 'devmap q3dm1'; sleep 30
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "the eyes are being shown a baseq3 world" MODENOW \
  'mode=VR .*present=world reason=0\(world\)' q3evrzones

# --- 4h-i. Sharpen is visible in the frame ---------------------------------
# The instrument is the donor's own (§15 #23): the mean magnitude of a
# four-neighbour Laplacian over the presented frame — "edge energy". It is used
# rather than a pixel diff because the frame is never twice identical (torches
# animate, and roughly a fifth of the pixels differ between two consecutive
# shots at IDENTICAL settings), while edge energy over the whole frame is
# stable to about 1% across those same two shots.
#
# The case therefore proves two things with three shots, and the first is what
# keeps the second honest: two shots at 0% must agree, or the measurement is
# noise and no verdict read off it means anything.
echo "== 4h-i. Sharpen raises the frame's edge energy, and 0% is a pass-through"
say 'q3evrsharpen 0'; sleep 3
shot 06a-sharpen-off-a
sleep 2
shot 06b-sharpen-off-b
say 'q3evrsharpen 100'; sleep 3
shot 06c-sharpen-full
SHARP_VERDICT=$(python3 - "$PFX-06a-sharpen-off-a.png" "$PFX-06b-sharpen-off-b.png" \
                          "$PFX-06c-sharpen-full.png" <<'PYEOF'
import sys
import numpy as np
from PIL import Image
def energy(p):
    a = np.asarray(Image.open(p).convert('L'), dtype=np.float32)
    lap = np.abs(4*a[1:-1,1:-1] - a[:-2,1:-1] - a[2:,1:-1] - a[1:-1,:-2] - a[1:-1,2:])
    return float(lap.mean())
a, b, c = (energy(p) for p in sys.argv[1:4])
base = (a + b) / 2.0
stable = abs(a - b) <= 0.05 * base
raised = c >= 1.30 * base
print("%.3f %.3f %.3f %s %s" % (a, b, c, "stable" if stable else "NOISY",
                                "raised" if raised else "FLAT"))
PYEOF
)
echo "   edge energy off/off/full: $SHARP_VERDICT"
case "$SHARP_VERDICT" in
  *"stable raised")
    printf '   PASS  0%% is a pass-through and 100%% measurably sharpens the frame\n' ;;
  *)
    printf '   FAIL  the sharpen measurement did not separate: %s\n' "$SHARP_VERDICT" >&2
    FAILED=1 ;;
esac
say 'q3evrsharpen 50'; sleep 2   # the shipped default (R4.5), not zero

# --- 4h-ii. the Damage Flash gate, watched working -------------------------
# Damage is taken from a bot rather than manufactured: `kill` is instant death
# and a dead player is never sent damage feedback, so the blend is never drawn.
# The counters are cumulative for the session, which is what makes the polls
# below independent of when the damage actually lands.
echo "== 4h-ii. the Damage Flash gate sees baseq3's blend and can drop it"
say 'q3evrdamageflash 1'; sleep 2
DMG_BASE=$(lastline EYENOW | grep -Eo 'dmgblends=[0-9]+/[0-9]+' | cut -d/ -f2)
say 'addbot sarge 5'; sleep 4
say 'addbot major 5'; sleep 4
DMG_SEEN=0
for _i in $(seq 1 8); do
  sleep 12; say 'q3evreye'; sleep 2
  n=$(lastline EYENOW | grep -Eo 'dmgblends=[0-9]+/[0-9]+' | cut -d/ -f2)
  if [ "${n:-0}" -gt "${DMG_BASE:-0}" ] 2>/dev/null; then DMG_SEEN=$n; break; fi
done
if [ "${DMG_SEEN:-0}" -gt "${DMG_BASE:-0}" ] 2>/dev/null; then
  printf '   PASS  the gate sees the cgame drawing its damage blend (%s -> %s)\n' \
         "$DMG_BASE" "$DMG_SEEN"
else
  printf '   FAIL  no damage blend ever reached the gate (seen stuck at %s)\n' \
         "${DMG_BASE:-none}" >&2
  FAILED=1
fi
# The other direction, which is this assertion's own fault injection: with the
# row off, DROPPED has to start climbing. An OFF that drops nothing and an OFF
# that is never asked are the same number without this pair.
say 'q3evrdamageflash 0'; sleep 2
DMG_DROP0=$(lastline EYENOW | grep -Eo 'dmgblends=[0-9]+/' | tr -d 'dmgblens=/')
DMG_DROP=0
for _i in $(seq 1 8); do
  sleep 12; say 'q3evreye'; sleep 2
  n=$(lastline EYENOW | grep -Eo 'dmgblends=[0-9]+/' | tr -d 'dmgblens=/')
  if [ "${n:-0}" -gt "${DMG_DROP0:-0}" ] 2>/dev/null; then DMG_DROP=$n; break; fi
done
if [ "${DMG_DROP:-0}" -gt "${DMG_DROP0:-0}" ] 2>/dev/null; then
  printf '   PASS  with the row off the gate actually drops the draw (%s -> %s)\n' \
         "$DMG_DROP0" "$DMG_DROP"
else
  printf '   FAIL  the row is off but nothing was dropped (stuck at %s)\n' \
         "${DMG_DROP0:-none}" >&2
  FAILED=1
fi
say 'q3evrdamageflash 1'; sleep 2

# --- 4h-iii. a game_restart no longer kills the eye path (R4.4) ------------
# R4.3 found and DOCUMENTED this one; R4.4 fixes it, and this is where the fix
# is proved. Com_GameRestart runs Cvar_Restart(qtrue), which unsets every
# user-created and VM-created cvar — and `r_stereo3d`, the gate the whole
# per-eye path hangs off, is created by the SHELL, so a mod switch deleted it
# and the eye pairs stopped for the rest of the session.
#
# The case runs RED FIRST. `q3evrrearm 0` disables the re-assert and nothing
# else, so what follows is precisely the pre-R4.4 build, and the frozen-pairs
# measurement below is the defect itself reproduced on demand. Only then is the
# invariant switched back on — with NO `q3evr` bounce anywhere in the sequence,
# because the bounce is exactly what R4.4 removed the need for. It needs no mod
# to run: `game_restart ""` is a full game restart onto baseq3.
echo "== 4h-iii. a game_restart keeps the eye path alive, proved against its own fault injection"
say 'disconnect'; sleep 5
say 'q3evrrearm 0'; sleep 2
say 'game_restart ""'; sleep 25
zone_assert "with the re-assert off, the restart cleared VR's own stereo gate" MODENOW \
  'mode=VR .*rearm=armed rearmhook=0 rearms=[0-9]+ stereo3d=0' q3evrzones
pairs_move frozen "...and the eye pairs freeze — the R4.3 defect, on demand"
say 'q3evrrearm 1'; sleep 5
zone_assert "re-arming puts the gate back without ever leaving VR" MODENOW \
  'mode=VR .*rearm=armed rearmhook=1 rearms=[1-9][0-9]* stereo3d=1' q3evrzones
pairs_move advance "...and the engine produces eye pairs again, with no q3evr bounce"

# --- 4h-iv. CPMA, installed and played in VR -------------------------------
# Skipped LOUDLY, never silently, when the tree is not there: the suite has to
# stay runnable on a clean checkout, and a case that quietly disappears is a
# case that quietly stops covering anything (work/cpma-PROVENANCE.md says how
# to fetch it).
MODSRC="$ROOT/work/cpma"
if [ ! -f "$MODSRC/z-cpma-pak153.pk3" ]; then
  echo "== 4h-iv. SKIPPED — no CPMA tree at work/cpma (see work/cpma-PROVENANCE.md)"
  echo "   This is a REAL gap in this run, not a pass: the mods case did not execute."
else
echo "== 4h-iv. CPMA installs through the drop-in path, boots, and plays in VR"
rsync -a "$MODSRC" "$DOCS/" || die "could not stage CPMA into the container"
[ -f "$DOCS/cpma/z-cpma-pak153.pk3" ] || die "CPMA staged but the pak is not in Documents"
n=$(ls "$DOCS/cpma"/map_*.pk3 2>/dev/null | wc -l | tr -d ' ')
echo "   staged CPMA: 1 mod pak + $n map paks in Documents/cpma"
# CPMA's qagame validates its whole map list at Game Initialization and refuses
# to start without it, so the map paks are not optional decoration here.
[ "$n" -ge 30 ] || die "CPMA needs its map pack ($n map paks staged, expected 30+)"
say 'disconnect'; sleep 5
# `game_restart` and not `fs_game cpma`: fs_game is CVAR_INIT, so the console
# cannot set it and neither can a VM — game_restart is the shipped path.
say 'game_restart cpma'; sleep 30
MOD_GAME=$(ask 'fs_game' | grep -Eo 'is:"[^"^]*' | head -1)
if [ "$MOD_GAME" = 'is:"cpma' ]; then
  printf '   PASS  fs_game is cpma after a game restart taken from inside VR\n'
else
  printf '   FAIL  fs_game did not become cpma (reads %s)\n' "${MOD_GAME:-none}" >&2
  FAILED=1
fi
# R4.4: NO `q3evr 0` / `q3evr 1` bounce here any more. R4.3 needed one because
# the restart deleted r_stereo3d; the mode machine now re-asserts it on the next
# engine frame, and the mod switch is expected to be invisible to the eye path.
# Asserted on the REAL mod switch and not only on the synthetic `game_restart ""`
# above: this is the switch a player actually makes.
zone_assert "...with VR's stereo gate re-asserted through the mod switch" MODENOW \
  'mode=VR .*rearm=armed rearmhook=1 rearms=[1-9][0-9]* stereo3d=1' q3evrzones
pairs_move advance "...and the eye pairs never stopped across the switch into CPMA"
say 'devmap q3dm1'; sleep 35
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "a CPMA map is presented to the eyes as a world frame" MODENOW \
  'mode=VR .*present=world reason=0\(world\)' q3evrzones
zone_assert "...on a live connection to the mod's own game" NETNOW \
  'state=active\(8\) .*map=maps/q3dm1\.bsp snapvalid=1 ' q3evrnet
# CPMA draws its own HUD on its own layout. The claim is not that it looks like
# baseq3's — it does not — but that the R4.2 band geometry still partitions it:
# three bands drawn, four exclusion rects, and the statusbar band where it was.
zone_assert "...and the band geometry still holds over an unfamiliar HUD" PANELNOW \
  'regionsdrawn=3 exclcount=4 .*statusrows=124 statustop=356 ' q3evrpanel
shot 07a-cpma-world
pairs_move advance "the engine keeps producing eye pairs under the mod, in world"

# --- 4h-v. the Damage Flash gate is MOD-SAFE -------------------------------
# The whole reason the gate keys on a shader name rather than on anything
# baseq3-specific. CPMA's cgame.qvm carries the same "viewBloodBlend" string,
# and this is where that stops being a grep and becomes a measurement.
echo "== 4h-v. CPMA's own damage blend arrives at the same gate"
MOD_SEEN0=$(lastline EYENOW | grep -Eo 'dmgblends=[0-9]+/[0-9]+' | cut -d/ -f2)
say 'addbot sarge 5'; sleep 4
say 'addbot major 5'; sleep 4
MOD_SEEN=0
for _i in $(seq 1 8); do
  sleep 12; say 'q3evreye'; sleep 2
  n=$(lastline EYENOW | grep -Eo 'dmgblends=[0-9]+/[0-9]+' | cut -d/ -f2)
  if [ "${n:-0}" -gt "${MOD_SEEN0:-0}" ] 2>/dev/null; then MOD_SEEN=$n; break; fi
done
if [ "${MOD_SEEN:-0}" -gt "${MOD_SEEN0:-0}" ] 2>/dev/null; then
  printf '   PASS  a third-party cgame'"'"'s damage blend reaches the gate (%s -> %s)\n' \
         "$MOD_SEEN0" "$MOD_SEEN"
else
  printf '   FAIL  CPMA drew no blend the gate could see (stuck at %s)\n' \
         "${MOD_SEEN0:-none}" >&2
  FAILED=1
fi
shot 07b-cpma-hud

# --- 4h-vi. and back to baseq3, with nothing left over ---------------------
echo "== 4h-vi. the return to baseq3 is clean"
say 'disconnect'; sleep 5
say 'game_restart ""'; sleep 30
# The OTHER direction of the switch, and the reason this is asserted twice: the
# restart out of a mod loads a different cgame from the one that was running,
# and "it survived going in" is not a claim about coming back.
pairs_move advance "the eye pairs survive the restart back out of the mod too"
BASE_GAME=$(ask 'fs_game' | grep -Eo 'is:"[^"^]*' | head -1)
say 'devmap q3dm1'; sleep 32
say 'q3evrpose 0 0 0 1.60 0'; sleep 3
zone_assert "baseq3 is presented to the eyes again" MODENOW \
  'mode=VR .*present=world reason=0\(world\)' q3evrzones
if [ "$BASE_GAME" = 'is:"' ]; then
  printf '   PASS  fs_game is empty again — the mod left nothing behind\n'
else
  printf '   FAIL  fs_game did not return to baseq3 (reads %s)\n' "${BASE_GAME:-none}" >&2
  FAILED=1
fi
shot 07c-baseq3-again
fi

# The invariant is not a case of its own: it rides every omnibus dump the suite
# reads. Reported here so a run in which it was never evaluated (a checker that
# quietly stopped being called) cannot look like a run in which it held.
if [ "$INVARIANT_CHECKS" -ge 20 ]; then
  printf '   PASS  present=world => vr=on held on all %s dump pairs read\n' "$INVARIANT_CHECKS"
else
  printf '   FAIL  the invariant was only evaluated %s time(s) — it is no longer riding the dumps\n' \
         "$INVARIANT_CHECKS" >&2
  FAILED=1
fi

echo "== artifacts: $PFX-*"
