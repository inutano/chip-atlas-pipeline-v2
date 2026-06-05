#!/bin/bash
#
# bench-orchestrate.sh — run the full memory benchmark on NIG, end to end, under
# nohup on the login node so it survives the operator's session.
#
#   Round 1 MEASURE : every dataset experiment at --mem=64g (safe ceiling),
#                     bench-experiment polls peak anon (non-reclaimable).
#   ANALYSE         : per (genome,pipeline) group, propose --mem = ceil(maxanon*1.2),
#                     floor 8 GB. Build a confirmation TSV: the deepest sample of
#                     each group at its proposed cap.
#   Round 2 CONFIRM : run those at the tight cap; a too-tight cap surfaces as an
#                     OOM (oom_kill>0 / rc 137). This is the production condition.
#   VERDICT         : write bench-summary.txt with the proposal + confirm result.
#
# All progress to bench-orchestrate.log; final tables to bench-summary.txt.
#
set -uo pipefail
BD=~/chip-atlas-v2
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
ST=$SHARED/bench-staging
OUTBASE=$SHARED/bench-out
DS=$BD/benchmark-experiments.tsv
SCR=$BD/scripts
RES=$BD/bench-results
RESC=$BD/bench-results-confirm
CONFIRM_TSV=$BD/bench-confirm.tsv
SUM=$BD/bench-summary.txt
LOG=$BD/bench-orchestrate.log
BENCHRE='^bench-(hg38|mm10|rn6|dm6|ce11|sacCer3|TAIR10)-'
GIB=1073741824

exec >"$LOG" 2>&1
echo "=== orchestrate START $(date) ==="

wait_for_bench() {   # $1 = label, waits until no bench jobs in squeue (8h cap)
  local i n
  for i in $(seq 1 480); do
    n=$(squeue --me -h -o "%j" 2>/dev/null | grep -cE "$BENCHRE")
    [ "$n" -eq 0 ] && break
    sleep 60
  done
  echo "=== $1 jobs drained (waited ~${i}m) ==="
}

# node health -> exclude unhealthy
EXCL=$(sinfo -N -p kumamoto-c768 -h -o "%n %t" 2>/dev/null | awk '$2 ~ /down|drain|fail|drng|boot|unk/ {print $1}' | sort -u | paste -sd, -)
echo "exclude=[$EXCL]"

# ---------------- Round 1: MEASURE -----------------------------------------
[ -d "$RES" ] && mv "$RES" "$BD/bench-results-flawed-$(ls -d "$BD"/bench-results-flawed-* 2>/dev/null | wc -l)" 2>/dev/null
mkdir -p "$RES"
echo "=== Round 1 MEASURE (--mem=64g) ==="
bash "$SCR/bench-run.sh" "$ST" "$DS" "$OUTBASE" "$RES" "$EXCL" 64g
wait_for_bench MEASURE
echo "measure results=$(ls "$RES"/*.result 2>/dev/null | wc -l)/39"

echo "=== ANALYSIS (peak anon -> proposed --mem) ==="
bash "$SCR/bench-analyze.sh" "$RES" | tee "$SUM"

# ---------------- Build confirmation TSV ------------------------------------
# deepest (max anon) sample per group, col5 = proposed mem "<N>g"
cat "$RES"/*.result 2>/dev/null | awk -F'\t' -v gib="$GIB" '
  { g=$2"-"$3; anon=$5+0
    if (anon>ma[g]) { ma[g]=anon; ex[g]=$1; ge[g]=$2; pi[g]=$3 } }
  END{ for (g in ma) {
        wm=int(ma[g]*12/10); mem=int((wm+gib-1)/gib); if(mem<8)mem=8
        printf "%s\t%s\t%s\t0\t%dg\n", ex[g], ge[g], pi[g], mem } }' \
  | sort -k2,2 -k3,3 > "$CONFIRM_TSV"
echo "=== confirmation targets (deepest sample @ proposed cap) ==="
cat "$CONFIRM_TSV"

# ---------------- Round 2: CONFIRM ------------------------------------------
[ -d "$RESC" ] && rm -rf "$RESC"; mkdir -p "$RESC"
echo "=== Round 2 CONFIRM (tight cap) ==="
bash "$SCR/bench-run.sh" "$ST" "$CONFIRM_TSV" "$OUTBASE" "$RESC" "$EXCL"
wait_for_bench CONFIRM

# ---------------- Verdict ---------------------------------------------------
{
  echo
  echo "=== CONFIRMATION @ proposed --mem (oom_kill>0 or rc=137 => TOO TIGHT) ==="
  printf '%-12s %-16s %4s %8s %9s %4s %5s  %s\n' EXP GROUP CAP ANON_G TOTAL_G OOM RC VERDICT
  # join cap from CONFIRM_TSV by exp
  awk -F'\t' 'NR==FNR{cap[$1]=$5; next}
    { exp=$1; oom=$8+0; rc=$10; v=(oom>0||rc==137)?"TOO-TIGHT":"OK"
      printf "%-12s %-16s %4s %7.1fG %8.1fG %4d %5s  %s\n",
        exp, $2"-"$3, cap[exp], $5/1073741824, $6/1073741824, oom, rc, v }' \
    "$CONFIRM_TSV" <(cat "$RESC"/*.result 2>/dev/null | sort -k2,2 -k3,3)
} | tee -a "$SUM"

echo "=== orchestrate DONE $(date) ===" | tee -a "$SUM"
