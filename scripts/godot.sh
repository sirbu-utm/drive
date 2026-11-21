#!/usr/bin/env bash
# Run Godot (console build) with the game project. Usage: scripts/godot.sh [godot args...]
# - --path <game dir> is added automatically unless already present.
# - --language en (stable English logs), ANSI colours and CRs are stripped from the output.
# - A discrete-GPU index (--gpu-index $DRIVE1_GPU_INDEX) is added for non-headless runs
#   unless DRIVE1_NO_GPU_INDEX=1. Check the "Using Device" line in the log.
# - Windows path arguments must be converted by the caller with `wslpath -w`.
# Exit code is Godot's exit code.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
args=("$@")
has_path=0; headless=0
for a in "${args[@]}"; do
  [[ "$a" == "--path" ]] && has_path=1
  [[ "$a" == "--headless" ]] && headless=1
done
pre=(--language en)
(( has_path )) || pre+=(--path "$(winpath "$GAME_DIR")")
if (( ! headless )) && [[ -z "${DRIVE1_NO_GPU_INDEX:-}" ]]; then
  pre+=(--gpu-index "$DRIVE1_GPU_INDEX")
fi
"$GODOT_EXE" "${pre[@]}" "${args[@]}" 2>&1 | sed -u 's/\x1b\[[0-9;]*m//g; s/\r$//'
exit "${PIPESTATUS[0]}"
