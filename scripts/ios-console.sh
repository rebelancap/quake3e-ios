#!/bin/bash
# Interactive remote console for quake3e on the iPhone.
#
#   ./scripts/ios-console.sh                     # launch app + attach console
#   ./scripts/ios-console.sh --deploy            # rebuild+reinstall+data first
#   ./scripts/ios-console.sh -- +demo four       # extra engine args at launch
#
# Live engine console: every console line streams to your terminal;
# anything you type executes as an engine command (map q3dm7 · set r_fbo 0;
# vid_restart · screenshotJPEG · timedemo 1; demo four ...). Ctrl-C
# detaches; the app keeps running — reattach with: nc <host> 27999
#
# Ported from q2repro-ios (its single most valuable debugging tool).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

DEVICE="960B5E4D-DD8F-57EF-A7B7-7B84B8633496"
BUNDLE=com.rebelancap.quake3e
HOST="Austins-iPhone.local"
PORT=27999
DO_DEPLOY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --deploy) DO_DEPLOY=1; shift ;;
        --host)   HOST=$2; shift 2 ;;
        --device) DEVICE=$2; shift 2 ;;
        --)       shift; break ;;
        *) echo "unknown arg $1" >&2; exit 2 ;;
    esac
done

if [ "$DO_DEPLOY" = "1" ]; then
    ./scripts/deploy.sh
fi

EXTRA_ARGS="${*:-}"
echo "== launching with console bridge (extra args: ${EXTRA_ARGS:-none})"
xcrun devicectl device process launch --terminate-existing \
    --environment-variables "{\"Q3E_CONSOLE\":\"1\", \"Q3E_ARGS\":\"$EXTRA_ARGS\"}" \
    --device "$DEVICE" "$BUNDLE" > /dev/null

echo "== waiting for engine boot + bridge..."
for i in $(seq 1 30); do
    sleep 1
    if nc -z -G 2 "$HOST" "$PORT" 2>/dev/null; then
        echo "== connected — type engine commands (Ctrl-C detaches, app keeps running)"
        exec nc "$HOST" "$PORT"
    fi
done
echo "ERROR: bridge port $PORT on $HOST never opened" >&2
exit 1
