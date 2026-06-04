#!/usr/bin/env bash
#
# Tests for scripts/job-settings.sh — the per-(pipeline,genome) SLURM resource
# lookup used to submit one cgroup-capped job per experiment. Values are the
# current plan settings (provisional pending the 2026-06 memory benchmark; the
# benchmark refines them and this test is updated alongside).
#
# Run: bash tests/test-job-settings.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/job-settings.sh
source "$HERE/../scripts/job-settings.sh"

PASSED=0; FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then PASSED=$((PASSED+1)); else
    FAILED=$((FAILED+1)); printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual"; fi
}

# job_settings <pipeline> <genome> -> "<cpus> <mem> <time>"
# ChIP: small genomes 4c/16g/2h; mammals 5c/20g/2h
assert_eq "chip sacCer3" "4 16g 0-02:00:00" "$(job_settings chipseq sacCer3)"
assert_eq "chip ce11"    "4 16g 0-02:00:00" "$(job_settings chipseq ce11)"
assert_eq "chip dm6"     "4 16g 0-02:00:00" "$(job_settings chipseq dm6)"
assert_eq "chip TAIR10"  "4 16g 0-02:00:00" "$(job_settings chipseq TAIR10)"
assert_eq "chip rn6"     "5 20g 0-02:00:00" "$(job_settings chipseq rn6)"
assert_eq "chip mm10"    "5 20g 0-02:00:00" "$(job_settings chipseq mm10)"
assert_eq "chip hg38"    "5 20g 0-02:00:00" "$(job_settings chipseq hg38)"
# BS: small genomes 4c/16g/2h; mammals 4c/20g/4h
assert_eq "bs sacCer3"   "4 16g 0-02:00:00" "$(job_settings bsseq sacCer3)"
assert_eq "bs dm6"       "4 16g 0-02:00:00" "$(job_settings bsseq dm6)"
assert_eq "bs TAIR10"    "4 16g 0-02:00:00" "$(job_settings bsseq TAIR10)"
assert_eq "bs rn6"       "4 20g 0-04:00:00" "$(job_settings bsseq rn6)"
assert_eq "bs mm10"      "4 20g 0-04:00:00" "$(job_settings bsseq mm10)"
assert_eq "bs hg38"      "4 20g 0-04:00:00" "$(job_settings bsseq hg38)"
# unknown genome -> empty (caller must error, not guess)
assert_eq "unknown genome" "" "$(job_settings chipseq nosuchgenome)"
assert_eq "unknown pipeline" "" "$(job_settings rnaseq hg38)"

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
