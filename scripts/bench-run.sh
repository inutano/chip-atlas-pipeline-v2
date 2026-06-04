#!/bin/bash
#
# bench-run.sh — submit one memory-benchmark job per experiment in a dataset TSV.
# Each job runs at the group's cores (from job-settings.sh) with a generous
# --mem=64g cgroup ceiling (never the constraint, and never --mem=0 so a runaway
# is contained to its own cgroup), and records memory.peak via bench-experiment.sh.
#
# Usage: bench-run.sh <staging_dir> <benchmark_tsv> <outbase> <resultdir> [exclude_nodes]
#
set -euo pipefail
STAGING="$1"; TSV="$2"; OUTBASE="$3"; RESULTDIR="$4"; EXCLUDE="${5:-}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/job-settings.sh"
mkdir -p "$RESULTDIR" "$OUTBASE"

n=0
while IFS=$'\t' read -r exp genome pipeline _; do
  [ -z "$exp" ] && continue
  case "$exp" in \#*) continue ;; esac
  read -r cpus _mem _time <<< "$(job_settings "$pipeline" "$genome")"
  [ -z "$cpus" ] && { echo "skip $exp: no settings for $pipeline/$genome"; continue; }
  args=(-p kumamoto-c768 --account=kumamoto-group --cpus-per-task="$cpus" --mem=64g -t 0-06:00:00
        -J "bench-${genome}-${pipeline}-${exp}" -o "$RESULTDIR/$exp.out" -e "$RESULTDIR/$exp.err")
  [ -n "$EXCLUDE" ] && args+=(--exclude="$EXCLUDE")
  jid=$(sbatch --parsable "${args[@]}" --wrap="bash $SCRIPTS_DIR/bench-experiment.sh $STAGING $exp $pipeline $genome $OUTBASE $cpus $RESULTDIR")
  echo "submitted $exp ($genome/$pipeline, ${cpus}c) job $jid"
  n=$((n+1))
done < <(grep -v '^#' "$TSV")
echo "=== submitted $n benchmark jobs ==="
