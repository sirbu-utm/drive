#!/usr/bin/env bash
# Render a scene to a PNG on the GPU via Movie Maker.
# Usage: scripts/shot.sh <scene res:// path or file under game/> <out.png> [frames=30] [WxH=1920x1080]
# Renders N frames at a fixed 60 fps and keeps the LAST frame as <out.png>.
# Extra godot args may be given via SHOT_EXTRA (e.g. SHOT_EXTRA="-- --some-arg").
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
scene="${1:?scene}"; out="${2:?out.png}"; frames="${3:-30}"; res="${4:-1920x1080}"
[[ "$scene" == res://* ]] || scene="res://${scene#game/}"
mkdir -p "$(dirname "$out")"
out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
tmp="$(mktemp -d "$ROOT/tools/shot_XXXXXX")"
LOG="$tmp/log.txt"
# shellcheck disable=SC2086
"$ROOT/scripts/godot.sh" "$scene" --resolution "$res" --write-movie "$(winpath "$tmp/f.png")" \
    --fixed-fps 60 --quit-after "$frames" ${SHOT_EXTRA:-} 2>&1 | tee "$LOG"
last="$(ls "$tmp"/f*.png 2>/dev/null | sort | tail -1)"
if [[ -z "$last" ]]; then echo "SHOT FAILED: no frames written" >&2; rm -rf "$tmp"; exit 1; fi
cp "$last" "$out_abs"
grep -E "Using Device|GPU_PROBE" "$LOG" || true
rm -rf "$tmp"
echo "SHOT OK -> $out_abs ($res, $frames frames)"
