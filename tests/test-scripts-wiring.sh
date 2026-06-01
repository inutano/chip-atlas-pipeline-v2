#!/usr/bin/env bash
#
# Guards the wiring of the shared libs into the pipeline/download/wrapper scripts:
#   1. every script parses (bash -n)
#   2. each script that sources a lib reaches its own argument check instead of
#      dying in the source (no "No such file" / "command not found").
#
# Run: bash tests/test-scripts-wiring.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $1"; }

# 1. Syntax — all scripts (libs + executables)
SCRIPTS=(
  scripts/failure-classify.sh
  scripts/download-route.sh
  scripts/make-batches.sh
  scripts/batch-status.sh
  scripts/pipeline-v2.sh
  scripts/pipeline-v2-bs.sh
  scripts/fast-download.sh
  scripts/nig/production-process.sh
)
for s in "${SCRIPTS[@]}"; do
  if bash -n "$ROOT/$s" 2>/dev/null; then pass; else fail "syntax: $s"; fi
done

# 2. Source resolution — these source a lib at startup; running them with no
#    args must get past the source to their own usage/arg error.
for s in scripts/pipeline-v2.sh scripts/pipeline-v2-bs.sh scripts/fast-download.sh; do
  out="$(bash "$ROOT/$s" 2>&1)"
  if printf '%s' "$out" | grep -qiE "no such file|command not found"; then
    fail "source resolution: $s — $(printf '%s' "$out" | grep -iE 'no such file|command not found' | head -1)"
  else
    pass
  fi
done

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
