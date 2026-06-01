#!/usr/bin/env bash
#
# Tests for scripts/failure-classify.sh — the pure decision functions that
# separate deterministic "bad data" failures (terminal) from transient/infra
# failures (retryable). Zero-dependency: plain bash, no bats required.
#
# Run: bash tests/test-failure-classify.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/failure-classify.sh
source "$HERE/../scripts/failure-classify.sh"

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

# ----------------------------------------------------------------------
# classify_outcome <rc> <stats_exists 0|1> <attempts> <max_retries>
#   -> done | datafail | retry | infrafail
# ----------------------------------------------------------------------

# Success: rc 0 and stats.tsv written
assert_eq "rc0 + stats present => done"          "done"      "$(classify_outcome 0 1 0 2)"

# Data failure: pipeline signalled deterministic bad-data via exit 42.
# Terminal regardless of attempts (re-running identical data won't help).
assert_eq "rc42 => datafail (attempt 0)"         "datafail"  "$(classify_outcome 42 0 0 2)"
assert_eq "rc42 => datafail (attempts maxed)"    "datafail"  "$(classify_outcome 42 0 9 2)"

# Transient/infra: any other non-zero exit, retry until the cap.
assert_eq "rc1, under cap => retry"              "retry"     "$(classify_outcome 1 0 0 2)"
assert_eq "rc1, one attempt left => retry"       "retry"     "$(classify_outcome 1 0 1 2)"
assert_eq "rc1, at cap => infrafail"             "infrafail" "$(classify_outcome 1 0 2 2)"
assert_eq "rc137 (OOM), under cap => retry"      "retry"     "$(classify_outcome 137 0 0 2)"

# Pipeline said success (rc0) but produced no stats.tsv marker — treat as
# transient (something aborted after exit): retry, then give up.
assert_eq "rc0 but no stats, under cap => retry" "retry"     "$(classify_outcome 0 0 0 2)"
assert_eq "rc0 but no stats, at cap => infrafail" "infrafail" "$(classify_outcome 0 0 2 2)"

# ----------------------------------------------------------------------
# classify_macs3_failure <macs3_rc> <peaks_xls_exists 0|1>
#   -> ok | data | infra
# (0 peaks is fine; only a true crash with no output is a failure)
# ----------------------------------------------------------------------

assert_eq "macs3 rc0 => ok"                      "ok"        "$(classify_macs3_failure 0 0)"
assert_eq "macs3 rc0 with xls => ok"             "ok"        "$(classify_macs3_failure 0 1)"
assert_eq "macs3 nonzero but xls present => ok"  "ok"        "$(classify_macs3_failure 1 1)"
assert_eq "macs3 clean nonzero, no output => data" "data"    "$(classify_macs3_failure 1 0)"
assert_eq "macs3 rc127, no output => data"       "data"      "$(classify_macs3_failure 127 0)"
assert_eq "macs3 OOM (rc137), no output => infra" "infra"    "$(classify_macs3_failure 137 0)"
assert_eq "macs3 SIGTERM (rc143), no output => infra" "infra" "$(classify_macs3_failure 143 0)"

# ----------------------------------------------------------------------
# classify_bsseq_failure <bigwig_rc> <methyl_bw_ok 0|1> <cover_bw_ok 0|1> <covered_cpgs>
#   -> ok | data | infra
# ----------------------------------------------------------------------

assert_eq "bs all good => ok"                    "ok"        "$(classify_bsseq_failure 0 1 1 50000)"
assert_eq "bs no covered CpGs => data"           "data"      "$(classify_bsseq_failure 1 0 0 0)"
assert_eq "bs bigwig failed but has CpGs => infra" "infra"   "$(classify_bsseq_failure 1 0 0 50000)"
assert_eq "bs methyl bw missing, has CpGs => infra" "infra"  "$(classify_bsseq_failure 0 0 1 50000)"

# ----------------------------------------------------------------------
echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
