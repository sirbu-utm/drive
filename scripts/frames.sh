#!/usr/bin/env bash
# Render a scene with Movie Maker and keep a subset of frames.
# Usage: scripts/frames.sh <scene> <out_prefix.png> <total_frames> <keep_every> [WxH] [-- user args...]
#   e.g. scripts/frames.sh res://scenes/test_track.tscn docs/shots/phase2/drift 900 150 1280x720 -- --demo=drift
# Output: <prefix>_<frame>.png for every keep_every-th frame (60 fps, frame numbers are 1-based).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
scene="$1"; prefix="$2"; total="$3"; every="$4"; res="${5:-1280x720}"
shift 5 || shift $#
[[ "${1:-}" == "--" ]] && shift
mkdir -p "$(dirname "$prefix")"
prefix_abs="$(cd "$(dirname "$prefix")" && pwd)/$(basename "$prefix")"
tmp="$(mktemp -d "$ROOT/tools/frames_XXXXXX")"
"$ROOT/scripts/godot.sh" "$scene" --resolution "$res" --write-movie "$(winpath "$tmp/f.png")" --fixed-fps 60 \
    --quit-after "$total" -- "$@" 2>&1 | grep -vE "^\s*$" | tail -8
n=0
for f in $(ls "$tmp"/f*.png | sort); do
  n=$((n+1))
  if (( n % every == 0 )); then cp "$f" "${prefix_abs}_$(printf '%04d' $n).png"; fi
done
rm -rf "$tmp"
echo "kept frames (every $every of $n) -> ${prefix_abs}_*.png"
