#!/usr/bin/env python3
"""sim-pixel-count.py — count pixels matching a named colour predicate in a
simulator screenshot, say WHERE they are, and (with --diff) measure how much two
screenshots actually differ.

A feature whose whole job is to put pixels on a screen gets an assertion that
reads pixels. Numbers in a dump prove the code ran; they do not prove anything
was visible. This is that assertion's instrument.

    sim-pixel-count.py <png> <predicate> [--min N] [--max N]
                       [--region x0,y0,x1,y1] [--regionpct x0,y0,x1,y1] [--maxcell N]
    sim-pixel-count.py <png> diff --diff <other.png> [--minpct P] [--maxpct P]
                       [--thresh T] [--region ...]
    sim-pixel-count.py <png> map [cols rows]

--regionpct takes 0-100 percentages of THIS image's own width/height instead
of literal pixels — use it whenever the caller cannot assume a fixed
screenshot resolution (visionOS `simctl io screenshot` captures whatever the
simulator window's CURRENT size is, which genuinely varies by context).

Predicates (0-255 sRGB, deliberately narrow so a brown Quake wall can never
satisfy one by accident):

  nonblack  max(r,g,b) >= 24                  — something was drawn at all. The
            cheapest possible defence against benchmarking a black screen, which
            a sibling port did at "60 fps".
  warm      r >= 60, r-b >= 25, r >= g        — Quake III's brown/rust world.
            Distinguishes "the map is on screen" from "the menu is on screen".
  magenta   r>=140, b>=140, g <= 0.45*min(r,b) — a debug colour. Quake's palette
            has nothing in this region, so a nonzero count means our geometry.

`--maxcell N` / `--mincell N` grid the frame into 64x64 cells and assert the
BUSIEST cell, because a raw count cannot tell a compact blob from scattered
world colour of a similar hue. `--mincell` is the form that matters when the
background is not black: q3dm1's lit floor and the simulator's own "3D / Exit
VR" ornament both put hundreds of near-white pixels into any region, thinly, so
a raw --min is satisfied with the feature absent while the busiest cell is not.

`map` is the SHAPE form, and it is for reading, not asserting: one character
per cell — S where sky wins the cell, `.` where nothing was drawn, `#` for
anything else. "The sky is a small lit rectangle floating in a black void" is a
claim about shape, and no scalar count can see one; a twenty-line picture in a
log can, which is how a corner assertion measuring a ceiling was caught.

`--diff` is the DIFFERENTIAL form, and it is the one that matters for pose:
any fixed screen region goes stale, and "the world is drawn" is not the same
claim as "the world responded to the pose I injected". Measuring the same scene
twice and subtracting is a claim that cannot be satisfied by a static picture.

Exit status 0 when every requested bound holds, 1 otherwise; the measurement
always goes to stdout so a failure report carries the evidence, not a verdict.
"""
import sys
from PIL import Image

PREDS = {
    "nonblack": lambda r, g, b: max(r, g, b) >= 24,
    # The exact complement of `nonblack`: nothing was drawn here. Counting the
    # void is not the same check as counting what should have filled it — a
    # region that is neither sky nor black is geometry, and telling "the sky is
    # missing" apart from "there is no sky in this direction" needs both.
    "black": lambda r, g, b: max(r, g, b) < 24,
    "warm": lambda r, g, b: r >= 60 and (r - b) >= 25 and r >= g,
    # R2.3: the VR aim marker. It is drawn ADDITIVELY in warm white
    # (255,235,190) over whatever it lands on, so its pixels are near the top of
    # all three channels — while everything it is drawn over in a Quake arena is
    # not. The two things that could be confused with it are ruled out by the
    # blue channel: the HUD's yellow digits have b == 0, and q3dm1's own sky and
    # rust palette is r-dominant with b near zero (see the `sky` note below).
    "marker": lambda r, g, b: r >= 200 and g >= 175 and b >= 150,
    "magenta": lambda r, g, b: r >= 140 and b >= 140 and g <= 0.45 * min(r, b),
    # R2.1 fix 13a: q3dm1's sky is NOT the blue/cyan gradient this predicate
    # first assumed — it is a deep orange/red gradient (verified by sampling
    # actual screenshots: r in roughly 35-150, g a small fraction of r, b
    # near zero), close enough in raw HUE to "warm" (the rust/brown palette
    # q3dm1's own floor and walls are painted in) that hue alone cannot
    # separate them — both are r-dominant. What DOES separate them, measured
    # from real corner samples of confirmed sky vs a confirmed ceiling
    # (r/g ratio: sky median 4.05, min 2.9 across >3000 samples; ceiling
    # median 2.03, 99%-ile still under 5.0): sky's green channel is a much
    # SMALLER fraction of red than lit/shadowed geometry's, and its blue
    # channel is closer to zero. r > g*5 with b capped low catches sky at
    # >85% coverage over open sky regions while staying under 1% over both a
    # confirmed ceiling and confirmed floor/wall geometry in the SAME
    # screenshots — verified empirically, not assumed from a colour wheel.
    "sky": lambda r, g, b: r >= 30 and b <= 12 and r > g * 5.0,
}

CELL = 64
# Every 2nd pixel: a 3840x2160 screenshot is 8.3 MP and the features looked for
# are tens of pixels across, so a 2x2 stride cannot miss one and the whole check
# stays under a second.
STRIDE = 2


def load(path, region):
    im = Image.open(path).convert("RGB")
    if region:
        im = im.crop(region)
    return im


def region_from_pct(path, pct):
    # visionOS `simctl io screenshot` captures whatever the simulator window's
    # CURRENT resolution is, and that genuinely differs by context (a menu/
    # panel frame measured smaller than a full stereo world frame in the same
    # run) — an absolute-pixel --region silently degrades into "most of the
    # image" or "nothing" when the caller's assumed resolution does not match.
    # --regionpct is resolution-independent: 0-100 percentages of THIS image's
    # own dimensions, resolved here so the rest of the tool never knows the
    # difference from a literal --region.
    x0p, y0p, x1p, y1p = pct
    w, h = Image.open(path).size
    return (int(w * x0p / 100.0), int(h * y0p / 100.0),
            int(w * x1p / 100.0), int(h * y1p / 100.0))


def run_diff(path, other, region, minpct, maxpct, thresh):
    # R2.1 cut-list: checked on the RAW images, BEFORE any --regionpct crop.
    # PIL's .crop() does not raise or clip for an out-of-bounds box — it
    # returns exactly the requested size, zero-padding whatever falls
    # outside the source image. --regionpct's region is resolved from
    # `path`'s own dimensions (region_from_pct, above) and then applied to
    # BOTH images; a genuine resolution mismatch between the two screenshots
    # being diffed (a real failure mode: `simctl io screenshot` captures
    # whatever the simulator window's CURRENT size is, and two shots taken
    # across a mode transition can differ) used to sail straight through the
    # size check below, because by the time it ran, both crops had ALREADY
    # been forced to the identical requested crop-box size regardless of
    # what the source images actually were — comparing real pixels from one
    # against synthetic black padding from the other and reporting whatever
    # that produced as a measurement.
    raw_a, raw_b = Image.open(path).size, Image.open(other).size
    if raw_a != raw_b:
        print("   FAIL  diff: %s is %dx%d but %s is %dx%d (checked before any --regionpct crop, "
              "which would otherwise silently zero-pad the smaller one to match)"
              % (path, raw_a[0], raw_a[1], other, raw_b[0], raw_b[1]), file=sys.stderr)
        return 1
    a = load(path, region)
    b = load(other, region)
    if a.size != b.size:
        print("   FAIL  diff: %s is %dx%d but %s is %dx%d"
              % (path, a.size[0], a.size[1], other, b.size[0], b.size[1]), file=sys.stderr)
        return 1
    w, h = a.size
    pa, pb = a.load(), b.load()
    n = 0
    total = 0
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    for y in range(0, h, STRIDE):
        for x in range(0, w, STRIDE):
            total += 1
            ra, ga, ba = pa[x, y]
            rb, gb, bb = pb[x, y]
            if abs(ra - rb) + abs(ga - gb) + abs(ba - bb) >= thresh:
                n += 1
                if x < x0: x0 = x
                if y < y0: y0 = y
                if x > x1: x1 = x
                if y > y1: y1 = y
    pct = (100.0 * n / total) if total else 0.0
    box = "none" if x1 < 0 else "(%d,%d)-(%d,%d)" % (x0, y0, x1, y1)
    print("   diff %s vs %s: %d/%d sampled pixels differ by >=%d (%.2f%%) bbox=%s"
          % (path.split("/")[-1], other.split("/")[-1], n, total, thresh, pct, box))
    ok = True
    if minpct is not None and pct < minpct:
        ok = False
        print("   FAIL  expected at least %.2f%% of pixels to change, got %.2f%% — "
              "the frame did not respond" % (minpct, pct), file=sys.stderr)
    if maxpct is not None and pct > maxpct:
        ok = False
        print("   FAIL  expected at most %.2f%% of pixels to change, got %.2f%%"
              % (maxpct, pct), file=sys.stderr)
    return 0 if ok else 1


def run_map(path, cols, rows):
    # Downscale first: the question is the SHAPE of the sky region, and a cell
    # verdict taken from an 8x8 average of the cell is both cheaper and less
    # jittery than one taken from every pixel in it.
    im = Image.open(path).convert("RGB")
    w, h = im.size
    small = im.resize((cols * 8, rows * 8), Image.BILINEAR)
    px = small.load()
    sky, black = PREDS["sky"], PREDS["black"]
    tot_s = tot_b = tot = 0
    lines = []
    for cy in range(rows):
        row = ""
        for cx in range(cols):
            s = b = n = 0
            for y in range(cy * 8, cy * 8 + 8):
                for x in range(cx * 8, cx * 8 + 8):
                    r, g, bb = px[x, y]
                    n += 1
                    if sky(r, g, bb):
                        s += 1
                    elif black(r, g, bb):
                        b += 1
            tot_s += s; tot_b += b; tot += n
            row += "S" if s * 2 >= n else ("." if b * 2 >= n else "#")
        lines.append(row)
    print("   %s: %dx%d  sky=%.1f%% black=%.1f%%  (S=sky . =nothing drawn #=other)"
          % (path.split("/")[-1], w, h, 100.0 * tot_s / tot, 100.0 * tot_b / tot))
    for ln in lines:
        print("   " + ln)
    return 0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    path, pred = argv[1], argv[2]
    if pred == "map":
        return run_map(path, int(argv[3]) if len(argv) > 3 else 40,
                       int(argv[4]) if len(argv) > 4 else 18)
    lo = hi = maxcell = mincell = None
    minpct = maxpct = None
    thresh = 24
    other = None
    region = None
    i = 3
    while i < len(argv):
        if argv[i] == "--min":
            lo = int(argv[i + 1]); i += 2
        elif argv[i] == "--max":
            hi = int(argv[i + 1]); i += 2
        elif argv[i] == "--maxcell":
            maxcell = int(argv[i + 1]); i += 2
        elif argv[i] == "--mincell":
            mincell = int(argv[i + 1]); i += 2
        elif argv[i] == "--diff":
            other = argv[i + 1]; i += 2
        elif argv[i] == "--minpct":
            minpct = float(argv[i + 1]); i += 2
        elif argv[i] == "--maxpct":
            maxpct = float(argv[i + 1]); i += 2
        elif argv[i] == "--thresh":
            thresh = int(argv[i + 1]); i += 2
        elif argv[i] == "--region":
            region = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        elif argv[i] == "--regionpct":
            region = region_from_pct(path, tuple(float(v) for v in argv[i + 1].split(",")))
            i += 2
        else:
            print("unknown argument %s" % argv[i]); return 2

    if pred == "diff":
        if not other:
            print("diff needs --diff <other.png>"); return 2
        return run_diff(path, other, region, minpct, maxpct, thresh)

    if pred not in PREDS:
        print("unknown predicate %s (have: %s, diff)" % (pred, ", ".join(PREDS)))
        return 2
    f = PREDS[pred]

    im = load(path, region)
    w, h = im.size
    px = im.load()
    n = 0
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    cells = {}
    for y in range(0, h, STRIDE):
        for x in range(0, w, STRIDE):
            r, g, b = px[x, y]
            if f(r, g, b):
                n += 1
                if x < x0: x0 = x
                if y < y0: y0 = y
                if x > x1: x1 = x
                if y > y1: y1 = y
                k = (x // CELL, y // CELL)
                cells[k] = cells.get(k, 0) + 1
    box = "none" if x1 < 0 else "(%d,%d)-(%d,%d)" % (x0, y0, x1, y1)
    peak, peakcell = (0, None)
    if cells:
        peakcell, peak = max(cells.items(), key=lambda kv: kv[1])
    peaktxt = "none" if peakcell is None else "%d in cell (%d,%d)" % (
        peak, peakcell[0] * CELL, peakcell[1] * CELL)
    print("   %s: %s pixels=%d (sampled 1-in-%d) bbox=%s busiest %dx%d cell=%s of %dx%d"
          % (path.split("/")[-1], pred, n, STRIDE * STRIDE, box, CELL, CELL, peaktxt, w, h))
    ok = True
    if lo is not None and n < lo:
        ok = False
        print("   FAIL  expected at least %d %s pixels, got %d" % (lo, pred, n), file=sys.stderr)
    if hi is not None and n > hi:
        ok = False
        print("   FAIL  expected at most %d %s pixels, got %d (bbox %s)"
              % (hi, pred, n, box), file=sys.stderr)
    if maxcell is not None and peak > maxcell:
        ok = False
        print("   FAIL  a COMPACT %s blob is present: %s (limit %d per cell) — "
              "scattered world colour cannot do this" % (pred, peaktxt, maxcell), file=sys.stderr)
    if mincell is not None and peak < mincell:
        ok = False
        print("   FAIL  no COMPACT %s blob: busiest cell %s, wanted at least %d — "
              "the raw count cannot say this, because a lit floor fills a region "
              "with the same colour thinly" % (pred, peaktxt, mincell), file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
