#!/usr/bin/env python3
"""vr-hudheight-check.py — is HUD Height a TRANSLATION of the head-locked cluster?

R3.2 item 2 replaced the Panel Size spread multiplier with a HUD Height offset in
degrees, and the property that makes it the control the device round asked for is
that it moves the whole cluster by exactly the number on the slider — no more, no
less, and the same amount in both directions. Anything else is a scale wearing a
position control's label, which is the defect being fixed.

Reads three `statuspitch=<signed>deg` fields out of PANELNOW lines (at height 0,
at +N and at -N) and asserts the two deltas are +N and -N.

Usage: vr-hudheight-check.py "<line-or-field at 0>" "<at +N>" "<at -N>" <N>
Exit 0 on PASS, 1 on FAIL. Prints the suite's own PASS/FAIL line either way.
"""
import re
import sys

TOL = 0.05   # degrees; the field is printed to two decimals


def pitch(text):
    m = re.search(r"statuspitch=([+-][0-9.]+)deg", text or "")
    return float(m.group(1)) if m else None


def main(argv):
    if len(argv) != 5:
        print("   FAIL  vr-hudheight-check.py: wrong argument count", file=sys.stderr)
        return 1
    p0, pup, pdn = (pitch(x) for x in argv[1:4])
    try:
        n = float(argv[4])
    except ValueError:
        print("   FAIL  vr-hudheight-check.py: the height argument is not a number",
              file=sys.stderr)
        return 1
    if None in (p0, pup, pdn):
        print("   FAIL  statuspitch was not published for one of the three heights "
              f"(0={argv[1]!r} +{n:g}={argv[2]!r} -{n:g}={argv[3]!r})", file=sys.stderr)
        return 1
    up, dn = pup - p0, pdn - p0
    if abs(up - n) < TOL and abs(dn + n) < TOL:
        print(f"   PASS  the cluster translates by exactly the slider value "
              f"(+{n:g} -> {up:+.2f}deg, -{n:g} -> {dn:+.2f}deg)")
        return 0
    print(f"   FAIL  HUD Height is not a translation: +{n:g} moved {up:+.2f}deg, "
          f"-{n:g} moved {dn:+.2f}deg", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
