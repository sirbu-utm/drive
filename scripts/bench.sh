#!/usr/bin/env bash
# Benchmark of the exported game: the autopilot drives the ring while frame times are recorded.
# Usage: scripts/bench.sh [exe=build/release/DRIVE1.exe]
#   1) 2560x1440 Ultra (+ per-feature ablation: how many ms each feature costs)
#   2) 1920x1080 High
# Results: build/bench_ultra_1440p.json, build/bench_high_1080p.json and "BENCH ..." lines on the console.
# WINDOWED and heavy on the GPU: do not run it while somebody is playing on this PC.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
exe="${1:-$ROOT/build/release/DRIVE1.exe}"
cd "$(dirname "$exe")"
common=(-- --nomenu --autopilot=ring --idx=300 --speed=60)
"$exe" "${common[@]}" --bench=ultra --bench-size=2560x1440 --bench-seconds=90 \
  --bench-ablate=sdfgi,ssr,ssil,ssao,vfog,glow,msaa,aa,shadows,shadow_distance,trees,grass,aniso,fsr --bench-ablate-seconds=15 \
  --bench-out="$(winpath "$ROOT/build/bench_ultra_1440p.json")" 2>&1 | grep -E "BENCH|ERROR"
"$exe" "${common[@]}" --bench=high --bench-size=1920x1080 --bench-seconds=90 \
  --bench-out="$(winpath "$ROOT/build/bench_high_1080p.json")" 2>&1 | grep -E "BENCH|ERROR"
