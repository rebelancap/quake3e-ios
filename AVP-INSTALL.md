# Installing Quake3e on Apple Vision Pro

This is an iOS and visionOS build of [Quake3e](https://github.com/ec-/Quake3e), the maintained, performance-focused ioquake3 engine, running its native Vulkan renderer on Metal. On Apple Vision Pro it plays in a freely resizable 2D window, in a stereoscopic 3D mode on a world-locked panel, and in a full VR mode where you stand inside the arena, head-tracked and at real scale.

## What you need

- Apple Vision Pro on visionOS 2 or later
- Your own Quake III Arena game files
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: macOS with Xcode, plus `xcodegen` (`brew install xcodegen`). The macOS reference build also wants `brew install molten-vk vulkan-loader`.
- Optional: a gamepad, or PS VR2 Sense controllers for hand aiming in VR. VR can also aim with your gaze.

## Your game files

Neither this repository nor the app contains any game content. You must own Quake III Arena and provide your own files.

1. Copy your `baseq3` folder (the important file is `pak0.pk3`) from Steam, GOG or the original CD.
2. Add it at first launch with the built-in picker (it works with iCloud and OneDrive folders), or later in the Files app: *On My Vision Pro → Quake3e* → drop in your `baseq3` folder.

The demo's `pak0.pk3` is detected, but the demo license doesn't permit its use here. **Quake III: Team Arena** is optional: drop your `missionpack` folder in the same way and launch it from the mods menu. Other mods go in their own folders next to `baseq3` (for example `cpma`, `osp`, `defrag`, or `q3ut4` for Urban Terror) and appear in the in-game MODS menu.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). iloader installs SideStore itself; apps are then installed and kept refreshed by SideStore.
2. In SideStore, go to *Sources → +* and paste this source, then install Quake III Arena:

   ```
   https://raw.githubusercontent.com/rebelancap/quake-ports/main/apps-visionos.json
   ```

   The app updates from this source when new versions ship. The source also carries Quake and Quake II.

To install by hand instead, download `Quake3e-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/quake3e-ios/releases/latest) and sideload it with SideStore or AltStore. Xcode and a Dev Strap are not required.

## Build from source

From a checkout of this repo, first set your Apple Developer team in `ios/project.yml` (`DEVELOPMENT_TEAM`). Then fetch the pinned upstream engine (the same first step `scripts/bootstrap.sh` runs) and build the visionOS app:

```sh
git clone https://github.com/ec-/Quake3e vendor/Quake3e
git -C vendor/Quake3e checkout "$(grep '^commit' upstream.pin | awk '{print $3}')"

scripts/build-oracle.sh          # applies patches/ and builds the macOS reference engine
scripts/build-visionos-deps.sh   # visionOS dependencies
scripts/build-visionos.sh        # engine + signed visionOS app
```

`scripts/build-visionos.sh` writes the app to `build/visionos/xcode/Release-xros/Quake3e.app`. `scripts/bootstrap.sh` on its own builds and installs the iPhone app.

Upstream Quake3e is vendored unmodified and pinned by commit. Every local change is a patch in `patches/`, applied by `scripts/sync-overlay.sh` with `--fuzz=0`, so a patch that no longer applies fails loudly.

## Notes

- VR offers three ways to aim: your gaze, PS VR2 Sense controllers (the gun is in your hand, with haptics), or a gamepad (the stick turns the view and the crosshair stays centred). The HUD and menus sit on an in-world panel.
- Multiplayer, mods and the single-player bot ladder all work in VR. Gamepad button bindings are listed in the README under [Gamepad bindings](README.md#gamepad-bindings).
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- QUAKE III ARENA is © id Software. Licensed under the GNU GPL v2 (see `COPYING`), matching upstream Quake3e.
