#!/usr/bin/env bash
#
# bench-analyze.sh — synthesise the memory benchmark into per-group --mem.
#
# Reads *.result files written by bench-experiment.sh (anon poller). Each row:
#   exp  genome  pipeline  cpus  peak_anon  peak_current  peak_swap  oom_kill  wall_s  rc
# all memory fields in BYTES. peak_anon is the NON-RECLAIMABLE footprint (the OOM
# floor under a cgroup cap); peak_current is total incl. reclaimable page cache
# (the old, inflated metric — reported only to show the gap).
#
# Per (genome,pipeline) group we take the MAX peak_anon across its samples and
# propose --mem = ceil(anon * 1.20), floored at 8 GB (samtools-sort buffer
# ceiling: ChIP 2*4G, BS 4*2G). A separate confirmation round proves the proposal
# never OOMs at the cap; this script just turns measurements into candidates.
#
# Usage: bench-analyze.sh <resultdir>
#
set -uo pipefail

# propose_mem_gb <peak_anon_bytes> -> integer GB
# 20% safety margin over measured non-reclaimable peak, ceil to whole GB, floor 8.
propose_mem_gb() {
  local anon="${1:-0}"
  local gib=$((1024*1024*1024))
  local withmargin=$(( anon * 12 / 10 ))                 # *1.20, integer
  local gb=$(( (withmargin + gib - 1) / gib ))           # ceil to GiB
  (( gb < 8 )) && gb=8                                    # samtools-sort floor
  echo "$gb"
}

# analyze_table <resultdir> -> rows: "group n max_anon_gb max_total_gb proposed_mem_gb ooms fails"
# (max_anon_gb / max_total_gb are floor'd-to-int GB just for display; the proposal
#  uses the exact byte value so it isn't double-rounded.)
analyze_table() {
  local dir="$1"
  cat "$dir"/*.result 2>/dev/null | awk -F'\t' -v gib=$((1024*1024*1024)) '
    {
      g=$2"-"$3; anon=$5+0; cur=$6+0; oom=$8+0; rc=$10
      n[g]++
      if (anon>ma[g]) ma[g]=anon
      if (cur>mc[g]) mc[g]=cur
      if (oom>0) ooms[g]++
      if (rc!=0 && rc!="" && rc!="0" && rc!="NOFASTQ") fails[g]++
    }
    END{
      for (k in n) {
        wm = int(ma[k]*12/10)                  # *1.20
        gb = int((wm + gib - 1)/gib)           # ceil GiB
        if (gb<8) gb=8
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", \
          k, n[k], int(ma[k]/gib), int(mc[k]/gib), gb, ooms[k]+0, fails[k]+0
      }
    }' | sort
}

main() {
  local dir="${1:?usage: bench-analyze.sh <resultdir>}"
  printf '%-16s %3s %9s %10s %9s %4s %5s\n' GROUP n ANON_GB TOTAL_GB MEM_GB OOM FAIL
  printf '%-16s %3s %9s %10s %9s %4s %5s\n' ---------------- --- --------- ---------- --------- ---- -----
  analyze_table "$dir" | while IFS=$'\t' read -r g n anon total mem ooms fails; do
    printf '%-16s %3d %8dG %9dG %8dG %4d %5d\n' "$g" "$n" "$anon" "$total" "$mem" "$ooms" "$fails"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
