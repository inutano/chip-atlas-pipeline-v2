#!/usr/bin/env bash
#
# Tests for scripts/bench-analyze.sh — synthesises the memory benchmark.
# The core logic under test is propose_mem_gb(): from a measured peak *anon*
# (non-reclaimable bytes), pick the production --mem = ceil(anon*1.20), floored
# at 8 GB (the samtools-sort buffer ceiling). Also an integration check that the
# per-group table picks max anon and flags OOMs from a fixture result dir.
#
# Run: bash tests/test-bench-analyze.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/bench-analyze.sh
source "$HERE/../scripts/bench-analyze.sh"

PASSED=0; FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then PASSED=$((PASSED+1)); else
    FAILED=$((FAILED+1)); printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual"; fi
}

GiB=$((1024*1024*1024))

# --- propose_mem_gb: 20% margin, ceil to GB, floor 8 -------------------------
assert_eq "zero -> floor 8"        "8"  "$(propose_mem_gb 0)"
assert_eq "2 GiB -> floor 8"       "8"  "$(propose_mem_gb $((2*GiB)))"
assert_eq "8 GiB -> 10"            "10" "$(propose_mem_gb $((8*GiB)))"          # 8*1.2=9.6 -> 10
assert_eq "10 GiB -> 12"           "12" "$(propose_mem_gb $((10*GiB)))"        # exact 12
assert_eq "15 GiB -> 18"           "18" "$(propose_mem_gb $((15*GiB)))"        # exact 18
assert_eq "16 GiB -> 20"           "20" "$(propose_mem_gb $((16*GiB)))"        # 19.2 -> 20
assert_eq "just over 8 floor edge" "8"  "$(propose_mem_gb $((6*GiB)))"         # 6*1.2=7.2 -> 8 floor
assert_eq "6.7 GiB -> 9 over floor" "9" "$(propose_mem_gb $((7*GiB)))"         # 7*1.2=8.4 -> 9

# --- integration: per-group table from a fixture result dir ------------------
# result row format: exp genome pipeline cpus peak_anon peak_current peak_swap oom_kill wall_s rc
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  A hg38 chipseq 5 $((16*GiB)) $((40*GiB)) 0 0 100 0 > "$FIX/A.result"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  B hg38 chipseq 5 $((12*GiB)) $((38*GiB)) 0 0 90  0 > "$FIX/B.result"   # lower anon, same group
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  C sacCer3 bsseq 4 $((3*GiB)) $((14*GiB)) 0 0 50 0 > "$FIX/C.result"

OUT="$(analyze_table "$FIX")"
# hg38-chipseq: max anon = 16 GiB -> propose 20
assert_eq "table picks group max anon -> mem" "20" \
  "$(echo "$OUT" | awk '$1=="hg38-chipseq"{print $5}')"
# sacCer3-bsseq: anon 3 GiB -> floor 8
assert_eq "table small genome floored"        "8" \
  "$(echo "$OUT" | awk '$1=="sacCer3-bsseq"{print $5}')"
# group n counts both hg38 rows
assert_eq "table counts samples per group"    "2" \
  "$(echo "$OUT" | awk '$1=="hg38-chipseq"{print $2}')"

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
