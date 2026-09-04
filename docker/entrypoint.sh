#!/usr/bin/env bash
#
# Container entrypoint. Dispatches to the test suite or a live scan.
#
#   (no args)      -> oxcorder.sh (full run)
#   run [args...]  -> oxcorder.sh [args...]
#   test [args...] -> tests/run.sh [args...]   (bats suite; no rack needed)
#   shell|bash     -> interactive bash
#   -<flag> ...    -> passed straight to oxcorder.sh (e.g. -s, -c, -w 30m)
set -euo pipefail

cmd="${1:-run}"
case "$cmd" in
  test|tests) shift; exec /app/tests/run.sh "$@" ;;
  run)        shift; exec /app/oxcorder.sh "$@" ;;
  shell|bash) shift; exec bash "$@" ;;
  *)          exec /app/oxcorder.sh "$@" ;;   # bare flags/args -> oxcorder
esac
