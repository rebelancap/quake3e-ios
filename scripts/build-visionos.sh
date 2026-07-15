#!/bin/bash
# build-visionos.sh — compile the quake3e engine for visionOS (xrOS/arm64)
# into libq3e-xros.a, then build+sign the native visionOS app target.
#
# Mirrors build-ios.sh (same oracle-derived source list so coverage can't
# silently diverge) with three deltas: the xrOS SDK/target, no libcurl
# (USE_CURL off for v1 — UDP downloads still work, HTTP downloads don't), and
# it drives the Quake3e-visionOS xcodegen target. The iOS build path is
# untouched. MoltenVK's xros-arm64 slice comes from vendor/moltenvk (fetched
# by fetch-moltenvk.sh); Vulkan headers are the platform-agnostic set already
# vendored under moltenvk-ios.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OVERLAY=$ROOT/build/src-overlay
APP=$ROOT/ios
OBJDIR=$ROOT/build/visionos/obj
LIBOUT=$ROOT/build/visionos/libq3e-xros.a
REF=$ROOT/build/oracle-vk/release-darwin-aarch64
MVK=$ROOT/vendor/moltenvk/MoltenVK.xcframework/xros-arm64

[ -d "$OVERLAY/code" ] || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh"; exit 1; }
[ -d "$REF/client" ]   || { echo "FATAL: reference macOS vk build missing — run scripts/build-oracle.sh"; exit 1; }
[ -f "$MVK/libMoltenVK.a" ] || "$ROOT/scripts/fetch-moltenvk.sh"
[ -f "$MVK/libMoltenVK.a" ] || { echo "FATAL: MoltenVK xros slice still missing after fetch"; exit 1; }
[ -f "$ROOT/build/visionos-deps/prefix/lib/libcurl.a" ] || "$ROOT/scripts/build-visionos-deps.sh"

SDKPATH=$(xcrun --sdk xros --show-sdk-path)
CC=$(xcrun --sdk xros -f clang)
BASEFLAGS="-isysroot $SDKPATH -target arm64-apple-xros1.0 -O2 -DNDEBUG -fvisibility=hidden -pipe -Wno-implicit-function-declaration"
# MACOS_X: the Apple homepath branch in unix_shared.c (Library/Application
# Support), same as iOS. USE_CURL for HTTP/HTTPS map downloads (static libcurl
# built for xrOS by build-visionos-deps.sh, SecureTransport TLS).
DEFS="-DNO_VM_COMPILED -DUSE_VULKAN_API -DUSE_OGG_VORBIS -DMACOS_X -DUSE_CURL -DQ3E_MVK_BRIDGE"
INCS="-I$ROOT/build/visionos-deps/prefix/include -I$OVERLAY/code/libogg/include -I$OVERLAY/code/libvorbis/include -I$OVERLAY/code/libvorbis/lib"

# desktop-only objects not compiled for the port (shell/glue replaces them)
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

echo "== compiling ${#srcs[@]} engine sources for xros/arm64"
mkdir -p "$OBJDIR"
rm -f "$OBJDIR"/*.o

GEN="$ROOT/build/visionos/gen"
mkdir -p "$GEN"
STAMP="$(grep '^commit' "$ROOT/upstream.pin" | awk '{print substr($3,1,8)}')+p$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l | tr -d ' ')-xros $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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
echo "== libq3e-xros.a: $(du -h "$LIBOUT" | cut -f1) ($count objects)"

(cd "$APP" && xcodegen generate --quiet)

# Force the linker to re-run. xcodebuild links -lq3e-xros from a search path and
# does NOT track the .a as a dependency, so when ONLY the engine lib changes (the
# common case — any patch/overlay/stamp edit with no shell .m change) it decides
# the app is "up to date" and ships a STALE binary. Deleting the linked product
# forces Ld to re-run against the freshly-built lib; the stamp assertion below is
# the backstop that proves it worked.
APPOUT="$ROOT/build/visionos/xcode/Release-xros/Quake3e.app"
rm -f "$APPOUT/Quake3e"
xcodebuild -project "$APP/Quake3e.xcodeproj" -target Quake3e-visionOS -configuration Release \
  -sdk xros -allowProvisioningUpdates ONLY_ACTIVE_ARCH=NO \
  SYMROOT="$ROOT/build/visionos/xcode" build > "$ROOT/build/visionos/xcodebuild.log" 2>&1 \
  || { echo "FATAL: xcodebuild failed — tail:"; tail -30 "$ROOT/build/visionos/xcodebuild.log"; exit 1; }

# xcodebuild's exit code is NOT trustworthy here: it has been observed to exit 0
# while printing "** BUILD FAILED **" (a compile error in a shell .m left the app
# unlinked but exit==0, so a stale binary shipped as "OK"). Assert on artifacts,
# not on $?: require BUILD SUCCEEDED, and require the freshly-generated stamp to
# actually be present in the linked binary (a stale/failed link keeps the old one).
grep -q "BUILD SUCCEEDED" "$ROOT/build/visionos/xcodebuild.log" \
  || { echo "FATAL: xcodebuild did not report BUILD SUCCEEDED — tail:"; tail -30 "$ROOT/build/visionos/xcodebuild.log"; exit 1; }

[ -d "$APPOUT" ] || { echo "FATAL: app bundle not produced"; exit 1; }
# grep -c (not -q): -q closes the pipe on first match, giving strings SIGPIPE,
# which under pipefail false-fails the check. Count-and-compare reads all input.
n=$(strings "$APPOUT/Quake3e" | grep -cF "$STAMP" || true)
[ "${n:-0}" -gt 0 ] \
  || { echo "FATAL: fresh stamp not in app binary (stale/failed link): $STAMP"; exit 1; }
echo "VISIONOS APP OK: $APPOUT (stamp verified in binary)"
codesign -dv "$APPOUT" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true
