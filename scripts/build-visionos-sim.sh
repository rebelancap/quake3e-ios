#!/bin/bash
# build-visionos-sim.sh — visionOS SIMULATOR build (unsigned) of the app.
#
# Mirrors build-visionos.sh with the simulator deltas: xrsimulator SDK +
# arm64-apple-xros1.0-simulator target, NO libcurl (deps are built device-only;
# the engine compiles without USE_CURL and an empty stub libcurl.a satisfies the
# project's hardcoded -lcurl), and no code signing. MoltenVK's simulator slice
# comes from the same vendored xcframework (xcodebuild picks it by SDK).
#
# Simulator runtime knobs (from NOTES-FROM-VKQUAKE.md — apply at LAUNCH):
#   SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0   (else black screen)
# renderervk uses no indirect draws, so vkQuake's r_indirect trap doesn't apply.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OVERLAY=$ROOT/build/src-overlay
APP=$ROOT/ios
OBJDIR=$ROOT/build/visionos-sim/obj
LIBDIR=$ROOT/build/visionos-sim
LIBOUT=$LIBDIR/libq3e-xros.a
REF=$ROOT/build/oracle-vk/release-darwin-aarch64
MVKSIM=$ROOT/vendor/moltenvk/MoltenVK.xcframework/xros-arm64_x86_64-simulator

[ -d "$OVERLAY/code" ] || { echo "FATAL: overlay missing — run scripts/sync-overlay.sh"; exit 1; }
[ -d "$REF/client" ]   || { echo "FATAL: reference macOS vk build missing — run scripts/build-oracle.sh"; exit 1; }
[ -f "$MVKSIM/libMoltenVK.a" ] || { echo "FATAL: MoltenVK simulator slice missing (fetch-moltenvk.sh)"; exit 1; }

SDKPATH=$(xcrun --sdk xrsimulator --show-sdk-path)
CC=$(xcrun --sdk xrsimulator -f clang)
BASEFLAGS="-isysroot $SDKPATH -target arm64-apple-xros1.0-simulator -O2 -DNDEBUG -fvisibility=hidden -pipe -Wno-implicit-function-declaration"
# No USE_CURL: visionos-deps' libcurl is device-only; UDP downloads still work.
DEFS="-DNO_VM_COMPILED -DUSE_VULKAN_API -DUSE_OGG_VORBIS -DMACOS_X -DQ3E_MVK_BRIDGE"
INCS="-I$OVERLAY/code/libogg/include -I$OVERLAY/code/libvorbis/include -I$OVERLAY/code/libvorbis/lib"

EXCLUDE="unix_main linux_signals sdl_glimp sdl_input sdl_snd sdl_gamma vm_aarch64"

resolve() {
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

echo "== compiling ${#srcs[@]} engine sources for xrsimulator/arm64"
mkdir -p "$OBJDIR"
rm -f "$OBJDIR"/*.o

GEN=$LIBDIR/gen
mkdir -p "$GEN"
STAMP="$(grep '^commit' "$ROOT/upstream.pin" | awk '{print substr($3,1,8)}')+p$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l | tr -d ' ')-xrsim $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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
echo "== libq3e-xros.a (sim): $(du -h "$LIBOUT" | cut -f1) ($count objects)"

# Empty stub so the project's hardcoded -lcurl resolves (no curl symbols are
# referenced without USE_CURL, so nothing is pulled from it). libtool refuses an
# archive with zero inputs, so feed it one empty object.
printf '// intentionally empty: -lcurl stub for the simulator build\n' > "$GEN/curl_stub.c"
$CC $BASEFLAGS -c "$GEN/curl_stub.c" -o "$GEN/curl_stub.o"
libtool -static -o "$LIBDIR/libcurl.a" "$GEN/curl_stub.o" 2>/dev/null
[ -f "$LIBDIR/libcurl.a" ] || { echo "FATAL: stub libcurl.a not produced"; exit 1; }

(cd "$APP" && xcodegen generate --quiet)

APPOUT="$ROOT/build/visionos-sim/xcode/Release-xrsimulator/Quake3e.app"
rm -f "$APPOUT/Quake3e"
xcodebuild -project "$APP/Quake3e.xcodeproj" -target Quake3e-visionOS -configuration Release \
  -sdk xrsimulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  LIBRARY_SEARCH_PATHS="$LIBDIR" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  SYMROOT="$ROOT/build/visionos-sim/xcode" build > "$ROOT/build/visionos-sim/xcodebuild.log" 2>&1 \
  || { echo "FATAL: xcodebuild failed — tail:"; tail -30 "$ROOT/build/visionos-sim/xcodebuild.log"; exit 1; }

grep -q "BUILD SUCCEEDED" "$ROOT/build/visionos-sim/xcodebuild.log" \
  || { echo "FATAL: xcodebuild did not report BUILD SUCCEEDED — tail:"; tail -30 "$ROOT/build/visionos-sim/xcodebuild.log"; exit 1; }

[ -d "$APPOUT" ] || { echo "FATAL: app bundle not produced"; exit 1; }
n=$(strings "$APPOUT/Quake3e" | grep -cF "$STAMP" || true)
[ "${n:-0}" -gt 0 ] \
  || { echo "FATAL: fresh stamp not in app binary (stale/failed link): $STAMP"; exit 1; }
echo "VISIONOS SIM APP OK: $APPOUT (stamp verified in binary)"
