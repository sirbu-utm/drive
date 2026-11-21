#!/usr/bin/env bash
# Common environment for DRIVE1 scripts (source me).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_EXE="$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe"
GODOT_GUI_EXE="$ROOT/tools/godot/Godot_v4.7.2-stable_win64.exe"
BLENDER_EXE="$ROOT/tools/blender/blender.exe"
GAME_DIR="$ROOT/game"
# Windows-path helper
winpath() { wslpath -w "$1"; }
# Index of the discrete GPU for Godot --gpu-index (checked in the log; override via DRIVE1_GPU_INDEX)
export DRIVE1_GPU_INDEX="${DRIVE1_GPU_INDEX:-0}"
