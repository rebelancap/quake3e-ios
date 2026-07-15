#!/bin/bash
# build-spike.sh — compile the quake3e engine (vulkan renderer, interpreter
# VM, no SDL) for iphoneos/arm64 into libq3e.a, then build+sign the spike
# app with xcodegen/xcodebuild.
#
# The engine source list is derived mechanically from the object files of
# the PROVEN macOS oracle-vk build, minus desktop-only files — so the two
# builds cannot silently diverge in file coverage.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OVERLAY=$ROOT/build/src-overlay
SPIKE=$ROOT/ios
OBJDIR=$ROOT/build/ios/obj
LIBOUT=$ROOT/build/ios/libq3e.a
REF=$ROOT/build/oracle-vk/release-darwin-aarch64

[ -d "$OVERLAY/code" ] || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh"; exit 1; }
[ -d "$REF/client" ] || { echo "FATAL: reference macOS vk build missing — run scripts/build-oracle.sh"; exit 1; }

SDKPATH=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
BASEFLAGS="-isysroot $SDKPATH -arch arm64 -miphoneos-version-min=16.0 -O2 -DNDEBUG -fvisibility=hidden -pipe -Wno-implicit-function-declaration"
# MACOS_X selects the Apple branch in unix_shared.c (homepath under
# Library/Application Support — the Linux branch mkdirs ~/.q3a, which the
# iOS container root forbids). The macOS oracle compiles with it too.
DEFS="-DNO_VM_COMPILED -DUSE_VULKAN_API -DUSE_OGG_VORBIS -DMACOS_X -DUSE_CURL -DQ3E_MVK_BRIDGE"
INCS="-I$ROOT/build/ios-deps/prefix/include -I$OVERLAY/code/libogg/include -I$OVERLAY/code/libvorbis/include -I$OVERLAY/code/libvorbis/lib"

# desktop-only objects not compiled for iOS (shell/glue replaces them)
EXCLUDE="unix_main linux_signals sdl_glimp sdl_input sdl_snd sdl_gamma vm_aarch64"

resolve() { # $1=basename, rest=candidate dirs under code/
  local b=$1; shift
  local matches n
  matches=$(for d in "$@"; do find "$OVERLAY/code/$d" -maxdepth 2 -name "$b.c" 2>/dev/null; done | sort -u)
  n=$(echo "$matches" | grep -c . || true)
  if [ "$n" != 1 ]; then
    echo "FATAL: source resolve for '$b' matched $n candidates:" >&2
    echo "$matches" >&2
    exit 1
  fi
  echo "$matches"
}

srcs=()
for o in "$REF"/client/*.o; do
  b=$(basename "$o" .o)
  case " $EXCLUDE " in *" $b "*) continue ;; esac
  srcs+=("$(resolve "$b" client qcommon server botlib unix sdl)")
done
for o in "$REF"/client/jpeg/*.o;   do srcs+=("$(resolve "$(basename "$o" .o)" libjpeg)"); done
for o in "$REF"/client/ogg/*.o;    do srcs+=("$(resolve "$(basename "$o" .o)" libogg/src)"); done
for o in "$REF"/client/vorbis/*.o; do srcs+=("$(resolve "$(basename "$o" .o)" libvorbis/lib)"); done
for o in "$REF"/client/qvm/*.o; do
  b=$(basename "$o" .o)
  case " $EXCLUDE " in *" $b "*) continue ;; esac
  srcs+=("$(resolve "$b" qcommon)")
done
for o in "$REF"/rendv/*.o; do srcs+=("$(resolve "$(basename "$o" .o)" renderervk renderercommon)"); done

echo "== compiling ${#srcs[@]} engine sources for iphoneos/arm64"
mkdir -p "$OBJDIR"
rm -f "$OBJDIR"/*.o

# build stamp: upstream sha + patch count + UTC build time, printed by the
# shell at boot (Q3E_STAMP line) so an install can always be identified
GEN="$ROOT/build/ios/gen"
mkdir -p "$GEN"
STAMP="$(grep '^commit' "$ROOT/upstream.pin" | awk '{print substr($3,1,8)}')+p$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l | tr -d ' ') $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'const char *q3e_ios_stamp = "%s";\n' "$STAMP" > "$GEN/ios_stamp.c"
srcs+=("$GEN/ios_stamp.c")
echo "== stamp: $STAMP"
for s in "${srcs[@]}"; do
  b=$(basename "$s" .c)
  extra=""
  case "$s" in */botlib/*) extra="-DBOTLIB" ;; esac
  $CC $BASEFLAGS $DEFS $INCS $extra -c "$s" -o "$OBJDIR/$b.o" \
    || { echo "FATAL: compile failed: $s"; exit 1; }
done
count=$(ls "$OBJDIR"/*.o | wc -l | tr -d ' ')
[ "$count" = "${#srcs[@]}" ] || { echo "FATAL: produced $count of ${#srcs[@]} objects"; exit 1; }

libtool -static -o "$LIBOUT" "$OBJDIR"/*.o
echo "== libq3e.a: $(du -h "$LIBOUT" | cut -f1) ($count objects)"

# app icon: legacy CFBundleIconFiles PNGs (Xcode 26 actool rejects classic
# single-size asset catalogs — q2repro-ios verified fact). Sizes generated
# from the 1024px master at build time.
ICON_SRC="$SPIKE/icon/q3_icon_big.png"
ICON_GEN="$SPIKE/icon/generated"
[ -f "$ICON_SRC" ] || { echo "FATAL: icon master missing at $ICON_SRC"; exit 1; }
mkdir -p "$ICON_GEN"
sips -z 120 120 "$ICON_SRC" --out "$ICON_GEN/AppIcon60x60@2x.png" > /dev/null
sips -z 180 180 "$ICON_SRC" --out "$ICON_GEN/AppIcon60x60@3x.png" > /dev/null
sips -z 152 152 "$ICON_SRC" --out "$ICON_GEN/AppIcon76x76@2x~ipad.png" > /dev/null
sips -z 167 167 "$ICON_SRC" --out "$ICON_GEN/AppIcon83.5x83.5@2x~ipad.png" > /dev/null

(cd "$SPIKE" && xcodegen generate --quiet)

# Force the linker to re-run. xcodebuild links -lq3e from a search path and does
# NOT track the .a as a dependency, so when ONLY the engine lib changes (any
# patch/overlay/stamp edit with no shell .m change) it decides the app is "up to
# date" and ships a STALE binary. Deleting the linked product forces Ld to re-run
# against the freshly-built lib; the stamp assertion below is the backstop.
APP="$ROOT/build/ios/xcode/Release-iphoneos/Quake3e.app"
rm -f "$APP/Quake3e"
xcodebuild -project "$SPIKE/Quake3e.xcodeproj" -target Quake3e -configuration Release \
  -sdk iphoneos -allowProvisioningUpdates ONLY_ACTIVE_ARCH=NO \
  SYMROOT="$ROOT/build/ios/xcode" build > "$ROOT/build/ios/xcodebuild.log" 2>&1 \
  || { echo "FATAL: xcodebuild failed — tail:"; tail -30 "$ROOT/build/ios/xcodebuild.log"; exit 1; }

# xcodebuild's exit code is NOT trustworthy: it can exit 0 while printing
# "** BUILD FAILED **" (e.g. a shell .m compile error leaves the app unlinked but
# $?==0, shipping a stale binary as "OK"). Assert on artifacts: require BUILD
# SUCCEEDED and the freshly-generated stamp actually present in the linked binary.
grep -q "BUILD SUCCEEDED" "$ROOT/build/ios/xcodebuild.log" \
  || { echo "FATAL: xcodebuild did not report BUILD SUCCEEDED — tail:"; tail -30 "$ROOT/build/ios/xcodebuild.log"; exit 1; }

[ -d "$APP" ] || { echo "FATAL: app bundle not produced"; exit 1; }
# grep -c (not -q): -q closes the pipe on first match, giving strings SIGPIPE,
# which under pipefail false-fails the check. Count-and-compare reads all input.
n=$(strings "$APP/Quake3e" | grep -cF "$STAMP" || true)
[ "${n:-0}" -gt 0 ] \
  || { echo "FATAL: fresh stamp not in app binary (stale/failed link): $STAMP"; exit 1; }
echo "SPIKE APP OK: $APP (stamp verified in binary)"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true
