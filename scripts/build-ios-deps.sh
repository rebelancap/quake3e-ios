#!/bin/bash
# build-ios-deps.sh — prebuilt static dependencies for the iOS app.
# Currently: libcurl (HTTP/HTTPS map downloads — quake3e's dlopen path
# is dead on iOS, so we static-link; SecureTransport TLS keeps it
# dependency-free and, being raw sockets, outside ATS entirely).
#
# Output: build/ios-deps/prefix/{include,lib}
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CURL_VER=8.11.1
DEPS=$ROOT/build/ios-deps
PREFIX=$DEPS/prefix
SRC=$DEPS/src

mkdir -p "$SRC" "$PREFIX"

if [ -f "$PREFIX/lib/libcurl.a" ]; then
  echo "libcurl.a already built — rm -rf build/ios-deps to force rebuild"
  exit 0
fi

cd "$SRC"
if [ ! -d "curl-$CURL_VER" ]; then
  echo "== fetching curl $CURL_VER"
  curl -sLO "https://curl.se/download/curl-$CURL_VER.tar.gz"
  tar xf "curl-$CURL_VER.tar.gz"
fi

cd "curl-$CURL_VER"

SDKPATH=$(xcrun --sdk iphoneos --show-sdk-path)
export CC="$(xcrun --sdk iphoneos -f clang)"
export CFLAGS="-isysroot $SDKPATH -arch arm64 -miphoneos-version-min=16.0 -O2"
export LDFLAGS="-isysroot $SDKPATH -arch arm64"
# cross-compile: configure can't runtime-probe the target — answer for
# it; and preprocessor-only checks use CPPFLAGS alone, so the sysroot
# must live here too or every header/prototype probe fails silently.
export CPPFLAGS="-isysroot $SDKPATH -DHAVE_FCNTL_O_NONBLOCK=1"

echo "== configuring curl (static, HTTP/HTTPS only, SecureTransport)"
./configure --host=arm-apple-darwin \
  --prefix="$PREFIX" \
  --disable-shared --enable-static \
  --with-secure-transport \
  --enable-http --disable-ftp --disable-file --disable-ldap --disable-ldaps \
  --disable-rtsp --disable-proxy --disable-dict --disable-telnet \
  --disable-tftp --disable-pop3 --disable-imap --disable-smb \
  --disable-smtp --disable-gopher --disable-mqtt --disable-manual \
  --disable-docs --disable-libcurl-option --disable-unix-sockets \
  --disable-ntlm --disable-tls-srp --disable-alt-svc --disable-hsts \
  --without-libpsl --without-libidn2 --without-nghttp2 --without-ngtcp2 \
  --without-zstd --without-brotli --without-librtmp --with-zlib \
  > "$DEPS/curl-configure.log" 2>&1 \
  || { echo "FATAL: curl configure failed — tail:"; tail -20 "$DEPS/curl-configure.log"; exit 1; }

echo "== building curl"
make -j"$(sysctl -n hw.ncpu)" -C lib > "$DEPS/curl-make.log" 2>&1 \
  || { echo "FATAL: curl make failed — tail:"; tail -20 "$DEPS/curl-make.log"; exit 1; }
make -C lib install >> "$DEPS/curl-make.log" 2>&1
make -C include install >> "$DEPS/curl-make.log" 2>&1

[ -f "$PREFIX/lib/libcurl.a" ] || { echo "FATAL: libcurl.a not produced"; exit 1; }
lipo -info "$PREFIX/lib/libcurl.a"
echo "IOS DEPS OK: $PREFIX"
