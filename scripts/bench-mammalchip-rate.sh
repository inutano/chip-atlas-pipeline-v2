#!/bin/bash
#
# bench-mammalchip-rate.sh — measure the OOM RATE of mammal-ChIP at candidate caps.
#
# mammal-ChIP is the dominant production volume, and its memory is read-count
# (MACS3) driven, so different samples sit anywhere from ~15 to ~34 GB anon. The
# floor sweep anchored on the worst outlier (which needs >28 GB); this answers the
# real question: across the actual sample distribution, what fraction OOMs at 20 GB
# (rides OOM-retry-2x) vs 24 GB? That decides whether 20g+retry is efficient or the
# floor should be a bit higher.
#
# Tests every clean (rc=0) mammal-ChIP sample from the measure round at 20g and 24g.
# Runs under nohup on a001; writes bench-mchip-summary.txt.
#
set -uo pipefail
BD=~/chip-atlas-v2
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
ST=$SHARED/bench-staging; OUTBASE=$SHARED/bench-out
SCR=$BD/scripts; RES=$BD/bench-results
RR=$BD/bench-mchip-res; TSV=$BD/bench-mchip.tsv
SUM=$BD/bench-mchip-summary.txt; LOG=$BD/bench-mchip.log
BENCHRE='^bench-'
GIB=1073741824
CAPS="20 24"

exec >"$LOG" 2>&1
echo "=== mchip-rate START $(date) ==="

# All clean mammal-ChIP samples from the measure round (exp genome anon), low->high.
tmp=$(mktemp)
cat "$RES"/*.result 2>/dev/null | awk -F'\t' '
  $3=="chipseq" && $2 ~ /^(rn6|mm10|hg38)$/ && $10==0 {print $1"\t"$2"\t"$5}' \
  | sort -t$'\t' -k3,3n > "$tmp"
echo "=== clean mammal-ChIP samples (exp genome anonGB) ==="
awk -F'\t' -v g="$GIB" '{printf "%-12s %-6s %dG\n",$1,$2,int($3/g)}' "$tmp"

: > "$TSV"
while IFS=$'\t' read -r exp gen anon; do
  [ -z "$exp" ] && continue
  for cap in $CAPS; do printf '%s\t%s\tchipseq\t0\t%sg\n' "$exp" "$gen" "$cap" >> "$TSV"; done
done < "$tmp"
rm -f "$tmp"
echo "=== sweep TSV ($(wc -l < "$TSV") jobs) ==="; cat "$TSV"

EXCL=$(sinfo -N -p kumamoto-c768 -h -o "%n %t" 2>/dev/null | awk '$2 ~ /down|drain|fail|drng|boot|unk/ {print $1}' | sort -u | paste -sd, -)
rm -rf "$RR"; mkdir -p "$RR"
bash "$SCR/bench-run.sh" "$ST" "$TSV" "$OUTBASE" "$RR" "$EXCL"

for i in $(seq 1 480); do
  n=$(squeue --me -h -o "%j" 2>/dev/null | grep -cE "$BENCHRE")
  [ "$n" -eq 0 ] && break
  sleep 60
done
echo "=== jobs drained (waited ~${i}m) ==="

{
  echo "=== mammal-ChIP OOM by cap $(date) ==="
  echo "PASS = finished no-OOM (rc 0/42, oom_kill=0); OOM = oom_kill>0 or rc=137."
  printf '%-12s %-6s %6s %4s %4s %4s %7s  %s\n' EXP GENOME ANON_G CAP RC OOM WALLs VERDICT
  for f in "$RR"/*.result; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .result); cap=${base##*.}
    IFS=$'\t' read -r exp gen pipe cpus anon pcur pswap oom wall rc < "$f"
    if [ "${oom:-0}" -gt 0 ] 2>/dev/null || [ "$rc" = 137 ]; then v=OOM
    elif [ "$rc" = 0 ] || [ "$rc" = 42 ]; then v=PASS; else v="ERR(rc=$rc)"; fi
    printf '%-12s %-6s %5dG %4s %4s %4s %7s  %s\n' "$exp" "$gen" "$((anon/GIB))" "$cap" "$rc" "$oom" "$wall" "$v"
  done | sort -k4,4 -k3,3n
  echo
  echo "=== OOM RATE per cap (fraction needing the 2x retry) ==="
  for cap in $CAPS; do
    total=0; oomc=0
    for f in "$RR"/*.${cap}g.result; do
      [ -e "$f" ] || continue
      IFS=$'\t' read -r e g p c a pc ps oom w rc < "$f"
      total=$((total+1)); { [ "${oom:-0}" -gt 0 ] 2>/dev/null || [ "$rc" = 137 ]; } && oomc=$((oomc+1))
    done
    echo "${cap}g: $oomc/$total OOM"
  done
} | tee "$SUM"
echo "=== mchip-rate DONE $(date) ===" | tee -a "$SUM"
