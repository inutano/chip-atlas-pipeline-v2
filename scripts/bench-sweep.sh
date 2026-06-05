#!/bin/bash
#
# bench-sweep.sh — OOM-threshold sweep to find the minimum --mem per setting-class.
#
# Settings are really 4 classes: {small,mammal} x {chipseq,bsseq}. For each class
# we take the MOST memory-demanding sample observed in the measure round (max anon
# from bench-results/) and run it down a ladder of --mem caps. A cap PASSES if the
# job finishes without an OOM (oom_kill==0 and rc!=137; rc=42 data-fail still PASSES
# because it exercised the memory-heavy steps first). The floor = lowest passing cap.
# That floor is the throughput-optimal --mem; deep outliers beyond it are handled in
# production by the coordinator's OOM-retry-at-2x.
#
# Runs under nohup on a001. Reads bench-results/ (measure), writes bench-sweep-res/
# and bench-sweep-summary.txt.
#
set -uo pipefail
BD=~/chip-atlas-v2
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
ST=$SHARED/bench-staging; OUTBASE=$SHARED/bench-out
SCR=$BD/scripts
RES=$BD/bench-results            # measure round results (target selection)
SWE=$BD/bench-sweep-res          # sweep results
SWTSV=$BD/bench-sweep.tsv
SUM=$BD/bench-sweep-summary.txt
LOG=$BD/bench-sweep.log
BENCHRE='^bench-'
GIB=1073741824

exec >"$LOG" 2>&1
echo "=== sweep START $(date) ==="

wait_for_bench() {
  local i n
  for i in $(seq 1 480); do
    n=$(squeue --me -h -o "%j" 2>/dev/null | grep -cE "$BENCHRE")
    [ "$n" -eq 0 ] && break
    sleep 60
  done
  echo "=== $1: bench jobs drained (waited ~${i}m) ==="
}

# 0. Let the measure round finish so every class has its full anon ranking.
wait_for_bench "pre-sweep (measure round)"
echo "measure results=$(ls "$RES"/*.result 2>/dev/null | wc -l)/39"

# 1. Per-class ladders (GB). Anchor high, descend past the expected floor.
declare -A LADDER=(
  [mammal-chipseq]="28 24 20 18 16"
  [small-chipseq]="16 14 12 10 8"
  [mammal-bsseq]="20 16 14 12 10 8"
  [small-bsseq]="12 10 8 6"
)

# 2. Build the sweep TSV: max-anon sample per class x each ladder cap (col5=cap).
: > "$SWTSV"
echo "=== target selection (max-anon sample per class) ==="
for class in mammal-chipseq small-chipseq mammal-bsseq small-bsseq; do
  pipe=${class#*-}; size=${class%-*}
  if [ "$size" = mammal ]; then gpat='rn6|mm10|hg38'; else gpat='sacCer3|ce11|dm6|TAIR10'; fi
  row=$(cat "$RES"/*.result 2>/dev/null | awk -F'\t' -v p="$pipe" -v g="$gpat" '
    $3==p && $2 ~ ("^("g")$") { if ($5+0>m){m=$5+0; r=$0} } END{ print r }')
  if [ -z "$row" ]; then echo "WARN: no measure sample for $class"; continue; fi
  exp=$(echo "$row" | cut -f1); gen=$(echo "$row" | cut -f2); anon=$(echo "$row" | cut -f5)
  printf '  %-16s target=%s (%s) anon=%dG  ladder=[%s]\n' "$class" "$exp" "$gen" "$((anon/GIB))" "${LADDER[$class]}"
  for cap in ${LADDER[$class]}; do
    printf '%s\t%s\t%s\t0\t%sg\n' "$exp" "$gen" "$pipe" "$cap" >> "$SWTSV"
  done
done
echo "=== sweep TSV ($(wc -l < "$SWTSV") jobs) ==="; cat "$SWTSV"

# 3. Submit the ladder (one cgroup-capped job per cap) and wait.
EXCL=$(sinfo -N -p kumamoto-c768 -h -o "%n %t" 2>/dev/null | awk '$2 ~ /down|drain|fail|drng|boot|unk/ {print $1}' | sort -u | paste -sd, -)
echo "exclude=[$EXCL]"
rm -rf "$SWE"; mkdir -p "$SWE"
bash "$SCR/bench-run.sh" "$ST" "$SWTSV" "$OUTBASE" "$SWE"
wait_for_bench "sweep"

# 4. Report: per class, each cap PASS/OOM, then the floor (lowest passing cap).
{
  echo "=== OOM-THRESHOLD SWEEP RESULT $(date) ==="
  echo "PASS = finished, no OOM (rc 0 or 42, oom_kill=0).  OOM = oom_kill>0 or rc=137."
  echo
  printf '%-16s %-12s %4s %5s %4s %7s  %s\n' CLASS EXP CAP RC OOM WALLs VERDICT
  # cap is encoded in the result filename (EXP.<cap>g.result); read it from the path.
  for f in "$SWE"/*.result; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .result)                 # EXP.<cap>g
    cap=${base##*.}                                # <cap>g
    IFS=$'\t' read -r exp gen pipe cpus anon pcur pswap oom wall rc < "$f"
    case "$gen" in rn6|mm10|hg38) size=mammal ;; *) size=small ;; esac
    if [ "$oom" -gt 0 ] 2>/dev/null || [ "$rc" = 137 ]; then v=OOM
    elif [ "$rc" = 0 ] || [ "$rc" = 42 ]; then v=PASS
    else v="ERR(rc=$rc)"; fi
    printf '%-16s %-12s %4s %5s %4s %7s  %s\n' "$size-$pipe" "$exp" "$cap" "$rc" "$oom" "$wall" "$v"
  done | sort -k1,1 -k3,3n
  echo
  echo "=== FLOOR per class (lowest passing cap) ==="
  for f in "$SWE"/*.result; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .result); cap=${base##*.}; capn=${cap%g}
    IFS=$'\t' read -r exp gen pipe cpus anon pcur pswap oom wall rc < "$f"
    case "$gen" in rn6|mm10|hg38) size=mammal ;; *) size=small ;; esac
    if ! { [ "$oom" -gt 0 ] 2>/dev/null || [ "$rc" = 137 ]; }; then
      if [ "$rc" = 0 ] || [ "$rc" = 42 ]; then echo "$size-$pipe $capn"; fi
    fi
  done | sort -k1,1 -k2,2n | awk '{ if(!($1 in seen)){seen[$1]=1; printf "%-16s floor = %sg\n",$1,$2} }'
} | tee "$SUM"

echo "=== sweep DONE $(date) ===" | tee -a "$SUM"
