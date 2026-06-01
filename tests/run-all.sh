#!/usr/bin/env bash
# Run all pipeline test suites. Exit non-zero if any suite fails.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

rc=0
for t in "$HERE"/test-*.sh; do
  echo "### $(basename "$t")"
  bash "$t" || rc=1
  echo
done
exit "$rc"
