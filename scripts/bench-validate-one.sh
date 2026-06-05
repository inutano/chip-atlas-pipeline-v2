#!/bin/bash
# One-sample smoke test of the anon poller before the full benchmark.
# Submits one fast clean sample, waits, prints the result row and a verdict.
set -uo pipefail
BD=~/chip-atlas-v2
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
ST=$SHARED/bench-staging; OUTBASE=$SHARED/bench-out
RES=$BD/bench-validate-res; rm -rf "$RES"; mkdir -p "$RES"
EXP=${1:-SRX23748815}; GENOME=${2:-ce11}; PIPE=${3:-chipseq}

printf '%s\t%s\t%s\t0\tsmall\n' "$EXP" "$GENOME" "$PIPE" > "$BD/bench-validate.tsv"
EXCL=$(sinfo -N -p kumamoto-c768 -h -o "%n %t" 2>/dev/null | awk '$2 ~ /down|drain|fail|drng|boot|unk/ {print $1}' | sort -u | paste -sd, -)
bash "$BD/scripts/bench-run.sh" "$ST" "$BD/bench-validate.tsv" "$OUTBASE" "$RES" "$EXCL" 64g

echo "waiting for $EXP ..."
for i in $(seq 1 40); do
  [ -f "$RES/$EXP.result" ] && break
  sleep 15
done
echo "=== result row (exp genome pipeline cpus anon total swap oom wall rc) ==="
cat "$RES/$EXP.result" 2>/dev/null || { echo "NO RESULT after ~10m"; exit 1; }
awk -F'\t' '{ a=$5+0; c=$6+0
  if (a>0 && c>=a) print "VERDICT: OK  anon="a"  total="c"  (anon>0, total>=anon as expected)"
  else print "VERDICT: SUSPECT  anon="a"  total="c }' "$RES/$EXP.result"
