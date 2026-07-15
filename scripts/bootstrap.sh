#!/bin/bash
# bootstrap.sh — the one command from clean checkout to an installed,
# running device app (charter Phase 1 acceptance).
#
# Prereqs on a fresh machine: Xcode + command line tools, Homebrew with
# molten-vk + vulkan-loader + xcodegen, a clone of upstream at the
# commit in upstream.pin under vendor/Quake3e, game data in gamedata/
# (or import on-device via the onboarding screen), and a provisioned
# iPhone (UDID in scripts/deploy.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d vendor/Quake3e/code ] || {
  echo "== cloning upstream at pin"
  URL=$(grep '^url' upstream.pin | awk '{print $3}')
  COMMIT=$(grep '^commit' upstream.pin | awk '{print $3}')
  git clone "$URL" vendor/Quake3e
  git -C vendor/Quake3e checkout "$COMMIT"
}

./scripts/build-ios-deps.sh
./scripts/build-oracle.sh
./scripts/deploy.sh
echo "BOOTSTRAP OK — launch with scripts/ios-console.sh or tap the icon"
