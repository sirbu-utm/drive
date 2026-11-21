#!/usr/bin/env bash
# Headless asset (re)import. Exits non-zero if the log contains errors.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="$(mktemp)"
"$ROOT/scripts/godot.sh" --headless --import --quit 2>&1 | tr -d '\r' | tee "$LOG"
# A second pass makes sure the .godot cache is complete (first import can emit class-cache warnings)
"$ROOT/scripts/godot.sh" --headless --import --quit 2>&1 | tr -d '\r' | tee -a "$LOG" >/dev/null
if grep -E "^(ERROR|SCRIPT ERROR|USER ERROR)|Parse Error" "$LOG" >/dev/null; then
  echo "IMPORT FAILED: errors in log" >&2; rm -f "$LOG"; exit 1
fi
rm -f "$LOG"; echo "IMPORT OK"
