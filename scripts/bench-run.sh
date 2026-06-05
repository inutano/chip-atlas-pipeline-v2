#!/bin/bash
#
# bench-run.sh — submit one memory-benchmark job per experiment in a dataset TSV.
# Each job runs at the group's cores (from job-settings.sh) and records peak
# non-reclaimable memory (anon) via bench-experiment.sh.
#
# Two rounds, same script:
#   MEASURE  : --mem defaults to 64g (a safe ceiling, never the constraint, never
#              --mem=0). anon is independent of the cap, so this measures the true
#              floor without OOM risk. TSV = docs/benchmark-experiments.tsv
#              (col5 = tier text, ignored here).
#   CONFIRM  : put the proposed cap in col5 as "<N>g" (e.g. 20g) for each row; that
#              row is submitted at exactly that --mem so a too-tight cap shows up as
#              an OOM (oom_kill>0 / rc 137) in the result. Use the deepest sample
#              per group.
#
# Usage: bench-run.sh <staging_dir> <benchmark_tsv> <outbase> <resultdir> [exclude_nodes] [default_mem]
#
set -euo pipefail
STAGING="$1"; TSV="$2"; OUTBASE="$3"; RESULTDIR="$4"; EXCLUDE="${5:-}"; DEFAULT_MEM="${6:-64g}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/job-settings.sh"
mkdir -p "$RESULTDIR" "$OUTBASE"

n=0
while IFS=$'\t' read -r exp genome pipeline _bytes col5; do
  [ -z "$exp" ] && continue
  case "$exp" in \#*) continue ;; esac
  read -r cpus _mem _time <<< "$(job_settings "$pipeline" "$genome")"
  [ -z "$cpus" ] && { echo "skip $exp: no settings for $pipeline/$genome"; continue; }
  # CONFIRM round: col5 like "20g" overrides --mem; else MEASURE at default ceiling.
  mem="$DEFAULT_MEM"
  case "$col5" in [0-9]*g) mem="$col5" ;; esac
  args=(-p kumamoto-c768 --account=kumamoto-group --cpus-per-task="$cpus" --mem="$mem" -t 0-06:00:00
        -J "bench-${genome}-${pipeline}-${exp}" -o "$RESULTDIR/$exp.out" -e "$RESULTDIR/$exp.err")
  [ -n "$EXCLUDE" ] && args+=(--exclude="$EXCLUDE")
  jid=$(sbatch --parsable "${args[@]}" --wrap="bash $SCRIPTS_DIR/bench-experiment.sh $STAGING $exp $pipeline $genome $OUTBASE $cpus $RESULTDIR")
  echo "submitted $exp ($genome/$pipeline, ${cpus}c, --mem=$mem) job $jid"
  n=$((n+1))
done < <(grep -v '^#' "$TSV")
echo "=== submitted $n benchmark jobs ==="
