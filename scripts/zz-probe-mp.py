#!/usr/bin/env python3
# zz-probe-mp.py — host-side master-server / server-info probe.
#
# The simulator's own engine can query masters perfectly well (that is what
# zz-probe-mp.sh asserts), but it has no console command that PRINTS the parsed
# address list — the browser is a QVM and its list never reaches the bridge. So
# the host does the same UDP conversation independently and prints candidates,
# and the sim is then told to `connect <addr>` at one of them.
#
# Two commands:
#   masters                — how many records each configured master returns
#   candidates [n]         — live baseq3 servers, stock map, sorted by ping
#
# Politeness: one getservers per master, one getinfo per server, 0.02 s apart.
# Nothing here retries a server that did not answer.

import socket
import struct
import sys
import time

MASTERS = [
    "master.quake3arena.com",  # engine default sv_master1 (id's; long dead)
    "directory.ioquake3.org",  # quake3e default sv_master2
    "master.maverickservers.com",  # quake3e default sv_master3
]
PROTOCOL = 68
PORT_MASTER = 27950
OOB = b"\xff\xff\xff\xff"

# The maps that ship in a retail baseq3 point-release install. A server running
# anything else would make the client fetch it, which is a different test (and
# the simulator build has no libcurl — see zz-probe-mp.sh).
STOCK_MAPS = {f"q3dm{i}" for i in range(1, 20)} | {
    f"q3tourney{i}" for i in range(1, 7)
} | {f"q3ctf{i}" for i in range(1, 5)}


def getservers(host, timeout=4.0):
    """Every address record a master returns for our protocol."""
    try:
        ip = socket.gethostbyname(host)
    except OSError as exc:
        return None, f"DNS failed ({exc})"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.5)
    addrs = []
    try:
        sock.sendto(OOB + b"getservers %d empty full" % PROTOCOL, (ip, PORT_MASTER))
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                data, _ = sock.recvfrom(8192)
            except socket.timeout:
                break
            tag = b"getserversResponse"
            idx = data.find(tag)
            if idx < 0:
                continue
            body = data[idx + len(tag):]
            # Records are \\ + 4 address bytes + 2 port bytes, terminated by
            # the literal "EOT". A truncated trailing record is dropped rather
            # than guessed at.
            pos = 0
            while pos + 7 <= len(body):
                if body[pos:pos + 1] != b"\\":
                    break
                chunk = body[pos + 1:pos + 7]
                if chunk.startswith(b"EOT"):
                    break
                a, b, c, d = chunk[0], chunk[1], chunk[2], chunk[3]
                port = struct.unpack(">H", chunk[4:6])[0]
                if port:
                    addrs.append(f"{a}.{b}.{c}.{d}:{port}")
                pos += 7
    finally:
        sock.close()
    return addrs, ip


def getinfo(addr, timeout=1.2):
    host, _, port = addr.partition(":")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    t0 = time.time()
    try:
        sock.sendto(OOB + b"getinfo q3eios", (host, int(port)))
        data, _ = sock.recvfrom(4096)
    except OSError:
        return None
    finally:
        sock.close()
    ping = int((time.time() - t0) * 1000)
    idx = data.find(b"infoResponse")
    if idx < 0:
        return None
    line = data[idx + len(b"infoResponse"):].strip(b"\n\x00").decode(
        "latin-1", "replace")
    fields = line.split("\\")
    info = {}
    for k, v in zip(fields[1::2], fields[2::2]):
        info[k.lower()] = v
    info["_addr"] = addr
    info["_ping"] = ping
    return info


def cmd_masters():
    for host in MASTERS:
        addrs, ip = getservers(host)
        if addrs is None:
            print(f"{host}: {ip}")
            continue
        print(f"{host} ({ip}): {len(addrs)} address records "
              f"({len(set(addrs))} unique)")


def cmd_candidates(want):
    seen = []
    for host in MASTERS:
        addrs, _ = getservers(host)
        if addrs:
            seen.extend(addrs)
    uniq = sorted(set(seen))
    print(f"# {len(uniq)} unique addresses from {len(MASTERS)} masters",
          file=sys.stderr)
    good = []
    for addr in uniq:
        info = getinfo(addr)
        time.sleep(0.02)
        if not info:
            continue
        if info.get("gamename", "").lower() not in ("baseq3", "q3a", ""):
            continue
        if info.get("game", ""):  # a mod's fs_game — not a vanilla test
            continue
        if info.get("mapname", "").lower() not in STOCK_MAPS:
            continue
        if info.get("pure", "1") not in ("0", "1"):
            continue
        if info.get("g_needpass", "0") != "0":
            continue
        good.append(info)
    good.sort(key=lambda i: i["_ping"])
    for info in good[:want]:
        print(f"{info['_addr']}\t{info['_ping']}ms\t"
              f"{info.get('mapname','?')}\t"
              f"{info.get('clients','?')}/{info.get('sv_maxclients','?')}\t"
              f"{info.get('hostname','?')[:40]}")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "masters"
    if what == "masters":
        cmd_masters()
    elif what == "candidates":
        cmd_candidates(int(sys.argv[2]) if len(sys.argv) > 2 else 10)
    else:
        print("usage: zz-probe-mp.py [masters|candidates [n]]", file=sys.stderr)
        sys.exit(2)
