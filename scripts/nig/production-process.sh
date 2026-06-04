#!/bin/bash
#
# Production processor: a lightweight coordinator that scans the staging dir for
# `.ready` experiments and submits ONE SLURM job per experiment to process it.
#
# Each per-experiment job (process-experiment.sh) is cgroup-isolated with the
# `--mem`/`--cpus` from job-settings.sh (NEVER --mem=0), so SLURM packs
# min(128/cpus, 512/mem) per node and the kernel OOM-killer can never reach
# system daemons. This coordinator itself is tiny (1 core / ~2 GB).
#
# Usage:
#   sbatch -p kumamoto-c768 --account=kumamoto-group -n 1 --mem=2g -t 2-00:00:00 \
#     -J proc-<genome>-<pipeline> -o ... -e ... \
#     production-process.sh <staging_dir> <pipeline> <genome> <outbase> [max_inflight] [interval]
#
# Env: MAX_RETRIES (default 2), EXCLUDE_NODES (comma list passed to sbatch --exclude).
#
set -eo pipefail

STAGING_DIR="$1"
PIPELINE="$2"        # "chipseq" or "bsseq"
GENOME="$3"
OUTBASE="$4"
MAX_INFLIGHT="${5:-300}"   # max submitted-but-not-terminal jobs (queue + running)
INTERVAL="${6:-30}"
MAX_RETRIES="${MAX_RETRIES:-2}"
EXCLUDE_NODES="${EXCLUDE_NODES:-}"

if [ -z "$STAGING_DIR" ] || [ -z "$PIPELINE" ] || [ -z "$GENOME" ] || [ -z "$OUTBASE" ]; then
  echo "Usage: $0 <staging_dir> <pipeline> <genome> <outbase> [max_inflight] [interval]"
  exit 1
fi

export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$STAGING_DIR"
LOG="$STAGING_DIR/process.log"
LOG_DIR="$(dirname "$STAGING_DIR")/proc-logs"
mkdir -p "$LOG_DIR"

# Shared libs (flat on cluster; ../ in repo).
for lib in failure-classify.sh job-settings.sh; do
  if [ -f "$SCRIPTS_DIR/$lib" ]; then source "$SCRIPTS_DIR/$lib"; else source "$SCRIPTS_DIR/../$lib"; fi
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Resolve the per-(pipeline,genome) resource settings. Never guess.
read -r CPUS MEM TIME_LIMIT <<< "$(job_settings "$PIPELINE" "$GENOME")"
if [ -z "$CPUS" ]; then
  log "ERROR: no job settings for pipeline=$PIPELINE genome=$GENOME (see scripts/job-settings.sh)"
  exit 1
fi

log "=== Production Processor (sbatch-per-experiment) ==="
log "Staging: $STAGING_DIR | Pipeline: $PIPELINE | Genome: $GENOME | Output: $OUTBASE"
log "Per-experiment job: ${CPUS}c, ${MEM}, ${TIME_LIMIT}; max in-flight ${MAX_INFLIGHT}; exclude='${EXCLUDE_NODES}'"

# A SLURM job id is "in the queue" if squeue prints it (pending or running).
job_alive() { [ -n "$(squeue -j "$1" -h -o '%i' 2>/dev/null)" ]; }

# Reset any orphaned in-flight markers: a `.submitted` whose job is gone from the
# queue but left no terminal marker (NODE_FAIL/preemption) goes back to `.ready`.
# Also rescue any legacy `.running` marker from the old inline model.
recover_orphans() {
  local f d jid
  for f in $(find "$STAGING_DIR" -maxdepth 2 -name .submitted 2>/dev/null); do
    d=$(dirname "$f"); jid=$(cat "$f" 2>/dev/null)
    if [ -n "$jid" ] && ! job_alive "$jid"; then
      if [ ! -f "$d/.done" ] && [ ! -f "$d/.fail" ]; then
        rm -f "$f"; touch "$d/.ready"
        log "[RECOVER] $(basename "$d") (job $jid gone, no terminal marker) -> .ready"
      else
        rm -f "$f"   # job finished and wrote terminal but didn't clear .submitted
      fi
    fi
  done
  for f in $(find "$STAGING_DIR" -maxdepth 2 -name .running 2>/dev/null); do
    mv "$f" "$(dirname "$f")/.ready" 2>/dev/null || true
  done
}

count_inflight() { find "$STAGING_DIR" -maxdepth 2 -name .submitted 2>/dev/null | wc -l; }
count_ready()    { find "$STAGING_DIR" -maxdepth 2 -name .ready     2>/dev/null | wc -l; }

submit_one() {
  local exp="$1" staging="$STAGING_DIR/$1" jid
  local args=(--parsable -p kumamoto-c768 --account=kumamoto-group
              --cpus-per-task="$CPUS" --mem="$MEM" -t "$TIME_LIMIT"
              -J "px-${GENOME}-${PIPELINE}-${exp}"
              -o "$LOG_DIR/px-${exp}-%j.out" -e "$LOG_DIR/px-${exp}-%j.err")
  [ -n "$EXCLUDE_NODES" ] && args+=(--exclude="$EXCLUDE_NODES")
  jid=$(sbatch "${args[@]}" --wrap="bash $SCRIPTS_DIR/process-experiment.sh $STAGING_DIR $exp $PIPELINE $GENOME $OUTBASE $CPUS" 2>>"$LOG") || return 1
  echo "$jid" > "$staging/.submitted"
  rm -f "$staging/.ready"
}

recover_orphans
TOTAL_SUBMITTED=0

while true; do
  inflight=$(count_inflight)
  # Submit ready experiments up to the in-flight cap.
  for ready_file in $(find "$STAGING_DIR" -maxdepth 2 -name .ready 2>/dev/null); do
    [ "$inflight" -ge "$MAX_INFLIGHT" ] && break
    exp=$(basename "$(dirname "$ready_file")")
    if submit_one "$exp"; then
      inflight=$((inflight + 1)); TOTAL_SUBMITTED=$((TOTAL_SUBMITTED + 1))
      [ $((TOTAL_SUBMITTED % 50)) -eq 0 ] && log "[STATUS] submitted=$TOTAL_SUBMITTED inflight=$inflight done=$(find "$OUTBASE/$GENOME" -name '*.stats.tsv' 2>/dev/null | wc -l)"
    fi
  done

  recover_orphans

  # Terminate when downloads are done and nothing is ready or in flight.
  if [ -f "$STAGING_DIR/.downloads-complete" ] && [ "$(count_ready)" -eq 0 ] && [ "$(count_inflight)" -eq 0 ]; then
    log "=== Complete: downloads done, no ready/in-flight. submitted=$TOTAL_SUBMITTED done=$(find "$OUTBASE/$GENOME" -name '*.stats.tsv' 2>/dev/null | wc -l) ==="
    break
  fi
  sleep "$INTERVAL"
done
