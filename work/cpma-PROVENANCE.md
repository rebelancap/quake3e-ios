# work/cpma — provenance record

Challenge ProMode Arena 1.53, the first mod on this port's acceptance list
("OSP, CPMA, defrag are the acceptance set"). It is here so that the VR mods
round, and the simulator suite's mods case, can install a real third-party
`fs_game` tree through the app's own drop-in path without a network fetch.

**Safe to delete: YES.** It is free, public, and re-fetchable in two commands
(below). Nothing in the repo builds from it and no user data lives in it.

## Source

| Item | Size | Origin |
|---|---|---|
| `cpma/z-cpma-pak153.pk3` plus the mod's own cfg/hud/locs trees | 17 MB | CPMA 1.53 "the mod itself", the no-maps distribution, from the project's own CDN: `https://cdn.playmorepromode.com/files/cpma/cpma-1.53-nomaps.zip`, linked from the downloads page at `https://playmorepromode.com/downloads`. Fetched 2026-08-17. |
| `cpma/map_*.pk3` — 38 map paks | 118 MB | "CPMA Maps — all maps required by the mod", same CDN: `https://cdn.playmorepromode.com/files/cpma-mappack-full.zip`. NOT optional, see below. |

Checksums as fetched:

```
mod zip  sha256 edfffa0c1a0375ba46a5b42257a168fb15086712245733526ab2d9ccdd821ca0
mod pak  sha256 8e99df463f3a680f8796577a0cf03a52471dc307078f9cd923b07b0d065bdd0c
         (cpma/z-cpma-pak153.pk3, 17,104,701 bytes)
map zip  sha256 5db933fc92c41f2e0941ab65725586d4d0c30fe84727427bb6b265e4d941a226
         (cpma-mappack-full.zip, 122,543,145 bytes)
```

Neither zip is kept — they are the same bytes as the tree beside them, and the
commands below rebuild both exactly.

## Re-fetch

```sh
cd work
curl -fLO https://cdn.playmorepromode.com/files/cpma/cpma-1.53-nomaps.zip
unzip -q cpma-1.53-nomaps.zip      # writes cpma/
curl -fLO https://cdn.playmorepromode.com/files/cpma-mappack-full.zip
unzip -q cpma-mappack-full.zip -d cpma/
rm cpma-1.53-nomaps.zip cpma-mappack-full.zip
```

**The map pack is mandatory, which was not obvious and cost a round of
guessing.** The "nomaps" download is the mod alone, and CPMA's `qagame`
validates its entire map list at Game Initialization: with only the mod
installed it aborts with `ERROR: map_cpm1a.pk3 is missing or corrupt!` before
any map loads — on `devmap q3dm1`, a stock baseq3 map it does not need. It
names the paks one at a time, so discovering the requirement by adding them
individually is a 38-step loop; fetch the pack.

## How it is used

Never baked into the app bundle. It is installed the way a player installs a
mod — copied into the app container's `Documents/` beside `baseq3`, which is
what the Files-app drop-in writes to:

```sh
CT=$(xcrun simctl get_app_container <UDID> com.rebelancap.quake3e data)
rsync -a work/cpma "$CT/Documents/"
# then, in the engine:  fs_game cpma ; vid_restart
```

The simulator suite's mods case skips loudly (never silently) when
`work/cpma/z-cpma-pak153.pk3` is absent, so a clean checkout still runs the
whole suite without this tree.

## Why this mod

It is the acceptance mod for two separate claims:

1. **Mods load at all in VR** — its cgame draws its own HUD, on its own
   layout, which is what exercises the R4.2 band geometry against content this
   port has never seen.
2. **The R4.3 Damage Flash gate is mod-safe** — the gate keys on the shader
   name id's cgame registers for the blood blend, and CPMA's own `cgame.qvm`
   carries the same string:
   `strings vm/cgame.qvm | grep viewBloodBlend` → `viewBloodBlend`.
