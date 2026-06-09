#!/bin/bash
#
# bench-rn6chip-floor.sh [N] — OOM-threshold test for the mammal-ChIP --mem floor,
# reusing the already-staged rn6 ChIP FASTQ (no download). Runs N experiments at
# 28/32/36/40 GB and reports the OOM rate per cap so we can pick the smallest cap
# with an acceptable OOM rate. rn6 has the highest ChIP anon of the mammals, so its
# floor is safe for hg38/mm10 too. Run under nohup on a001.
#
# Usage: bench-rn6chip-floor.sh [N]   (default 12 experiments)
#
set -uo pipefail
BD=$HOME/chip-atlas-v2
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
ST=/home/okishinya/chipatlas-v2/staging/rn6-chipseq   # reuse staged FASTQ
OUTBASE=$SHARED/bench-out
SCR=$BD/scripts
RR=$BD/bench-rn6chip-res; TSV=$BD/bench-rn6chip.tsv
SUM=$BD/bench-rn6chip-summary.txt; LOG=$BD/bench-rn6chip.log
N="${1:-12}"; CAPS="28 32 36 40"; GIB=1073741824
BENCHRE='^bench-rn6-chipseq'

exec >"$LOG" 2>&1
echo "=== rn6-ChIP floor test START $(date) ==="

mapfile -t exps < <(for d in "$ST"/*/; do
  [ -d "$d" ] || continue
  if ls "$d"/*.fastq.gz >/dev/null 2>&1; then basename "$d"; fi
done | head -n "$N")
echo "testing ${#exps[@]} experiments x [$CAPS] GB"

: > "$TSV"
for exp in "${exps[@]}"; do
  for cap in $CAPS; do printf '%s\trn6\tchipseq\t0\t%sg\n' "$exp" "$cap" >> "$TSV"; done
done
echo "=== TSV ($(wc -l < "$TSV") jobs) ==="

EXCL=$(sinfo -N -p kumamoto-c768 -h -o "%n %t" 2>/dev/null \
  | awk '$2 ~ /down|drain|fail|drng|boot|unk/ {print $1}' | sort -u | paste -sd, -)
rm -rf "$RR"; mkdir -p "$RR"
bash "$SCR/bench-run.sh" "$ST" "$TSV" "$OUTBASE" "$RR" "$EXCL"

for i in $(seq 1 160); do
  n=$(squeue --me -h -o "%j" 2>/dev/null | grep -cE "$BENCHRE")
  [ "$n" -eq 0 ] && break
  sleep 30
done
echo "=== jobs drained (waited ~$((i/2))m) ==="

{
  echo "=== rn6-ChIP OOM rate by cap ==="
  for cap in $CAPS; do
    total=0; oomc=0
    for f in "$RR"/*.${cap}g.result; do
      [ -e "$f" ] || continue; total=$((total + 1))
      IFS=$'\t' read -r e g p c a pc ps oom w rc < "$f"
      { [ "${oom:-0}" -gt 0 ] 2>/dev/null || [ "$rc" = 137 ]; } && oomc=$((oomc + 1))
    done
    echo "  ${cap}g: $oomc/$total OOM"
  done
  echo "=== per-experiment (exp cap oom rc anonGB wall_s) ==="
  for f in "$RR"/*.result; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .result); cap=${b##*.}
    IFS=$'\t' read -r e g p c a pc ps oom w rc < "$f"
    printf "  %-12s %4s oom=%s rc=%-4s anon=%dG wall=%ss\n" "$e" "$cap" "${oom:-?}" "$rc" "$((${a:-0} / GIB))" "$w"
  done | sort -k1,1 -k2,2
} | tee "$SUM"
echo "=== rn6-ChIP floor DONE $(date) ===" | tee -a "$SUM"
