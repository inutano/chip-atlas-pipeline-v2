#!/usr/bin/env bash
#
# Tests for the stateful outcome-application helpers in failure-classify.sh:
# read_attempts and apply_outcome. These manipulate the staging-dir marker
# files (.running/.ready/.done/.fail), the .attempts counter, and the staged
# FASTQs. Zero-dependency: plain bash + a temp dir.
#
# Run: bash tests/test-apply-outcome.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/failure-classify.sh
source "$HERE/../scripts/failure-classify.sh"

PASSED=0
FAILED=0

check() {
  local desc="$1"; shift
  if "$@"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: $desc"
  fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

# Build a fresh staging dir in the .running state with a staged FASTQ.
new_staging() {
  local d; d="$(mktemp -d)"
  touch "$d/.running"
  touch "$d/SRX0000001.fastq.gz"
  [ -n "${1:-}" ] && echo "$1" > "$d/.attempts"
  echo "$d"
}

# ---- read_attempts ----
d="$(mktemp -d)"
assert_eq "read_attempts: absent => 0" "0" "$(read_attempts "$d")"
echo 1 > "$d/.attempts"
assert_eq "read_attempts: file '1' => 1" "1" "$(read_attempts "$d")"
echo 3 > "$d/.attempts"
assert_eq "read_attempts: file '3' => 3" "3" "$(read_attempts "$d")"
rm -rf "$d"

# ---- apply_outcome: done ----
d="$(new_staging)"
apply_outcome "$d" done
check "done: .done created"        test -f "$d/.done"
check "done: .running removed"     test ! -e "$d/.running"
check "done: FASTQ cleaned"        test ! -e "$d/SRX0000001.fastq.gz"
check "done: .attempts cleared"    test ! -e "$d/.attempts"
rm -rf "$d"

# ---- apply_outcome: datafail (terminal, won't reprocess => clean FASTQ) ----
d="$(new_staging)"
apply_outcome "$d" datafail
check "datafail: .fail created"    test -f "$d/.fail"
check "datafail: .running removed" test ! -e "$d/.running"
check "datafail: FASTQ cleaned"    test ! -e "$d/SRX0000001.fastq.gz"
rm -rf "$d"

# ---- apply_outcome: retry (keep FASTQ, bump attempts, back to .ready) ----
d="$(new_staging)"
apply_outcome "$d" retry
check "retry: .ready created"      test -f "$d/.ready"
check "retry: .running removed"    test ! -e "$d/.running"
check "retry: FASTQ kept"          test -e "$d/SRX0000001.fastq.gz"
assert_eq "retry: attempts 0 -> 1" "1" "$(read_attempts "$d")"
rm -rf "$d"

# ---- apply_outcome: retry increments an existing counter ----
d="$(new_staging 1)"
apply_outcome "$d" retry
assert_eq "retry: attempts 1 -> 2" "2" "$(read_attempts "$d")"
rm -rf "$d"

# ---- apply_outcome: infrafail (terminal after retries; keep FASTQ for manual rerun) ----
d="$(new_staging 2)"
apply_outcome "$d" infrafail
check "infrafail: .fail created"   test -f "$d/.fail"
check "infrafail: .running removed" test ! -e "$d/.running"
check "infrafail: FASTQ kept"      test -e "$d/SRX0000001.fastq.gz"
rm -rf "$d"

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
