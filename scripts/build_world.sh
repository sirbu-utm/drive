#!/usr/bin/env bash
# Full world rebuild: python generator -> Godot headless builder. Usage: scripts/build_world.sh [--skip-gen]
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
if [[ "${1:-}" != "--skip-gen" ]]; then
  "$ROOT/tools/venv/bin/python" "$ROOT/pipeline/world/gen_world.py"
fi
"$ROOT/scripts/import.sh" >/dev/null
"$ROOT/scripts/godot.sh" --headless --script res://scripts/world/build_world.gd 2>&1 | grep -E "build_world|ERROR|SCRIPT ERROR|rror" 
