#!/usr/bin/env bash
# Bake impostor atlases for all trees (Blender + Cycles GPU). ~2 min per tree.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
SRC="$ROOT/assets_src/polyhaven_models"
OUT="$ROOT/game/assets/vegetation/impostors"
mkdir -p "$OUT"
bake() {  # model.gltf name [node]
  local extra=()
  [[ -n "${3:-}" ]] && extra=(--node "$3")
  [[ -f "$OUT/$2.json" && -z "${FORCE:-}" ]] && { echo "skip $2"; return; }
  "$BLENDER_EXE" -b --factory-startup -P "$(winpath "$ROOT/pipeline/vegetation/bake_impostors.py")" -- \
     "$(winpath "$SRC/$1")" "$(winpath "$OUT")" --name "$2" "${extra[@]}" 2>&1 | tr -d '\r' | grep -E "\] (done|.*radius)|Traceback|Error:" | grep -v "Not freed"
}
bake island_tree_01/island_tree_01_1k.gltf island_tree_01
bake island_tree_02/island_tree_02_1k.gltf island_tree_02
bake fir_tree_01/fir_tree_01_1k.gltf fir_a fir_tree_01_a
bake fir_tree_01/fir_tree_01_1k.gltf fir_b fir_tree_01_b
bake fir_tree_01/fir_tree_01_1k.gltf fir_c fir_tree_01_c
bake pine_sapling_medium/pine_sapling_medium_1k.gltf sapling_a pine_sapling_medium_a
bake pine_sapling_medium/pine_sapling_medium_1k.gltf sapling_b pine_sapling_medium_b
bake jacaranda_tree/jacaranda_tree_1k.gltf jacaranda
