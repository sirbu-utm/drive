#!/usr/bin/env bash
# Headless test run. Usage: scripts/test.sh [name-prefix]   (e.g. phase1)
# Runs game/tests/<prefix>*_tests.gd; non-zero exit code on any failure or any engine error.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="$(mktemp)"
extra=()
[[ $# -ge 1 ]] && extra=(-- "$1")
"$ROOT/scripts/godot.sh" --headless --script res://tests/test_runner.gd "${extra[@]}" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
if grep -E "^(SCRIPT ERROR|ERROR:|USER ERROR)|Parse Error" "$LOG" >/dev/null; then
  echo "TEST RUN: engine/script errors in log" >&2; rc=1
fi
rm -f "$LOG"
exit "$rc"
