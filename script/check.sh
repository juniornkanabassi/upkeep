#!/usr/bin/env bash
# Normal council gate: all correctness lanes, every light/dark surface, and the layout grid.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UPKEEP_BUILD_DIR="${UPKEEP_BUILD_DIR:-$ROOT_DIR/build}"
export UPKEEP_SNAPSHOT_DIR="${UPKEEP_SNAPSHOT_DIR:-$UPKEEP_BUILD_DIR/snapshots}"
mkdir -p "$UPKEEP_SNAPSHOT_DIR"
STARTED_AT="$(/usr/bin/python3 -c 'import time; print(time.time())')"
"$ROOT_DIR/script/test.sh" --all
/usr/bin/python3 "$ROOT_DIR/script/check_snapshots.py" "$UPKEEP_SNAPSHOT_DIR" "$STARTED_AT"
