#!/usr/bin/env bash
# Rebuild the car GLB from assets_raw/ (headless Blender). Extra args are passed to build_car.py.
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
mkdir -p "$ROOT/build/car_debug"
"$BLENDER_EXE" -b --factory-startup -P "$(winpath "$ROOT/pipeline/build_car.py")" -- \
    --debug-dir "$(winpath "$ROOT/build/car_debug")" "$@" 2>&1 | grep -v '^$' | sed 's/\r$//'
test "${PIPESTATUS[0]}" -eq 0
