#!/usr/bin/env bash
#
# Tests for scripts/download-route.sh — the per-run source ordering. ENA serves
# ready-made .gz for SRR/ERR *and* DRR (verified against the ENA filereport API),
# so ENA is tried first for everything. DDBJ-local (bz2→gz transcode on /lustre9)
# is only a fallback for DRR runs not available from ENA; SRA fasterq-dump is the
# last resort. This avoids the CPU transcode + head-of-line blocking that stalled
# the 2026-06-01 rn6 smoke run.
#
# Run: bash tests/test-download-route.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/download-route.sh
source "$HERE/../scripts/download-route.sh"

PASSED=0
FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

# download_sources_for <run_prefix> -> space-separated ordered source names
assert_eq "DRR: ENA first, DDBJ-local fallback, SRA last" "ena ddbj_local sra" "$(download_sources_for DRR)"
assert_eq "SRR: ENA then SRA (no DDBJ-local)"             "ena sra"            "$(download_sources_for SRR)"
assert_eq "ERR: ENA then SRA (no DDBJ-local)"             "ena sra"            "$(download_sources_for ERR)"
# Unknown/odd prefix still gets the safe default (ENA then SRA).
assert_eq "unknown prefix: ENA then SRA"                  "ena sra"            "$(download_sources_for XXX)"

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
