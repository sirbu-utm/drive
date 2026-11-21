#!/usr/bin/env bash
# Preview renders of the GLB. Usage: scripts/render_car.sh --out docs/shots/phase1 [--modes class|beauty,class] [--views a,b] ...
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out|--glb|--hdri) args+=("$1" "$(winpath "$(readlink -m "$2")")"); shift 2;;
    *) args+=("$1"); shift;;
  esac
done
"$BLENDER_EXE" -b --factory-startup -P "$(winpath "$ROOT/pipeline/render_previews.py")" -- "${args[@]}" 2>&1 | grep -E "^\[render\]|Error|Traceback|File |rror" | sed 's/\r$//'
test "${PIPESTATUS[0]}" -eq 0
