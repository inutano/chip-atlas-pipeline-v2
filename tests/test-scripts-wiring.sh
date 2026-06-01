#!/usr/bin/env bash
#
# Guards the wiring of failure-classify.sh into the pipeline + wrapper scripts:
#   1. every script parses (bash -n)
#   2. each script successfully SOURCES the lib (no "No such file" / "command
#      not found"); we detect this by invoking with no args and confirming the
#      run reaches its own argument validation instead of dying in the source.
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

SCRIPTS=(
  "scripts/failure-classify.sh"
  "scripts/pipeline-v2.sh"
  "scripts/pipeline-v2-bs.sh"
  "scripts/nig/production-process.sh"
)

# 1. Syntax
for s in "${SCRIPTS[@]}"; do
  if bash -n "$ROOT/$s" 2>/dev/null; then pass; else fail "syntax: $s"; fi
done

# 2. Source resolution: run the two pipeline scripts with no args. They must
#    get past `source failure-classify.sh` and reach their required-arg check
#    (which prints "ERROR: --sample-id is required"). A source failure would
#    instead print "No such file" or "command not found".
for s in scripts/pipeline-v2.sh scripts/pipeline-v2-bs.sh; do
  out="$(bash "$ROOT/$s" 2>&1)"
  if printf '%s' "$out" | grep -q "is required" \
     && ! printf '%s' "$out" | grep -qiE "no such file|command not found"; then
    pass
  else
    fail "source resolution: $s — got: $(printf '%s' "$out" | head -1)"
  fi
done

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
