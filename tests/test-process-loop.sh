#!/usr/bin/env bash
#
# Integration test for production-process.sh's coordinator loop, with `sbatch`
# and `squeue` stubbed (no real SLURM). Verifies: it submits one job per .ready
# experiment, writes .submitted, the orphan/cleanup path clears .submitted once
# the (simulated) job leaves the queue having written .done, and the loop exits
# when downloads are complete and nothing remains.
#
# Run: bash tests/test-process-loop.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; ST="$WORK/staging"; OUT="$WORK/out"
mkdir -p "$STUB" "$ST" "$OUT"

# Fake sbatch: parse --wrap to find <staging> <exp>, simulate an instantly-finished
# job (touch .done), and print a fresh jobid (--parsable).
cat > "$STUB/sbatch" <<'SBATCH'
#!/bin/bash
jf=/tmp/.fakejid.$$; : "${FAKEJID_FILE:=$jf}"
n=$(( $(cat "$FAKEJID_FILE" 2>/dev/null || echo 9000) + 1 )); echo "$n" > "$FAKEJID_FILE"
for a in "$@"; do [ "${a#--wrap=}" != "$a" ] && w="${a#--wrap=}"; done
set -- $w   # bash <path> <STAGING> <EXP> <pipeline> <genome> <outbase> <cpus>
staging="$3"; exp="$4"
mkdir -p "$staging/$exp"; touch "$staging/$exp/.done"
echo "$n"
SBATCH

# Fake squeue: jobs never appear (simulating they've already finished).
cat > "$STUB/squeue" <<'SQUEUE'
#!/bin/bash
exit 0
SQUEUE
chmod +x "$STUB/sbatch" "$STUB/squeue"
export FAKEJID_FILE="$WORK/jid"

# Two ready experiments with a staged FASTQ, and downloads marked complete.
for e in SRX0000001 SRX0000002; do
  mkdir -p "$ST/$e"; touch "$ST/$e/${e}.fastq.gz" "$ST/$e/.ready"
done
touch "$ST/.downloads-complete"

# Run the coordinator with the stubs on PATH, fast interval, short overall guard.
PATH="$STUB:$PATH" timeout 30 bash "$ROOT/scripts/nig/production-process.sh" \
  "$ST" chipseq sacCer3 "$OUT" 300 1 >"$WORK/proc.log" 2>&1
rc=$?

PASSED=0; FAILED=0
check(){ local d="$1"; shift; if "$@"; then PASSED=$((PASSED+1)); else FAILED=$((FAILED+1)); echo "FAIL: $d"; fi; }

check "loop exited cleanly (not timeout)" test "$rc" -eq 0
check "SRX1 ended .done"          test -f "$ST/SRX0000001/.done"
check "SRX2 ended .done"          test -f "$ST/SRX0000002/.done"
check "no .submitted left"        test -z "$(find "$ST" -name .submitted)"
check "no .ready left"            test -z "$(find "$ST" -name .ready)"
grep -q "Complete:" "$WORK/proc.log" && PASSED=$((PASSED+1)) || { FAILED=$((FAILED+1)); echo "FAIL: no Complete log line"; echo "--- proc.log ---"; tail -8 "$WORK/proc.log"; }

echo "----------------------------------------"
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
