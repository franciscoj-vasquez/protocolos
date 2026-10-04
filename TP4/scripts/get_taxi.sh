#!/usr/bin/env bash
# Clone the DUT repository (fpganinja/taxi) at the commit verified in TP4.
#   ./get_taxi.sh            -> TP4/repo_taxi/taxi @ TAXI_COMMIT
#   TAXI_COMMIT=<sha> ./get_taxi.sh
set -euo pipefail

TAXI_COMMIT="${TAXI_COMMIT:-cc70b270b910d369ab1ad7b3855e76399fd461f1}"   # 2026-08-28
DEST="$(cd "$(dirname "$0")/.." && pwd)/repo_taxi/taxi"

if [ ! -d "$DEST/.git" ]; then
    git clone https://github.com/fpganinja/taxi.git "$DEST"
fi
git -C "$DEST" fetch --quiet origin
git -C "$DEST" -c advice.detachedHead=false checkout --quiet "$TAXI_COMMIT"

# src/eth/lib/taxi is a symlink to the repo root: it only works on Linux/macOS
# clones (on a Windows checkout it becomes a text file and the .f lists break).
if [ ! -f "$DEST/src/eth/lib/taxi/src/lfsr/rtl/taxi_lfsr.sv" ]; then
    echo "ERROR: symlink src/eth/lib/taxi not resolved. Clone on Linux (not on a Windows checkout)." >&2
    exit 1
fi
echo "taxi @ $(git -C "$DEST" rev-parse --short HEAD) in $DEST"
