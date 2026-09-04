#!/usr/bin/env bash
#
# Run the Oxcorder test suite. Checks that bats-core (and jq) are installed
# before running, and prints how to get them if not.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "error: bats not found — the test suite needs bats-core." >&2
  echo "  macOS:  brew install bats-core" >&2
  echo "  Linux:  https://github.com/bats-core/bats-core#installation" >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found (brew install jq)." >&2
  exit 127
fi

exec bats "$here"/*.bats
