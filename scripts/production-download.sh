#!/bin/bash
#
# Production downloader: rate-limited FASTQ download daemon.
# Runs as a SLURM job on any node. Downloads FASTQs to a staging dir,
# writes .ready markers for the processor to pick up.
#
# Usage:
#   sbatch -p kumamoto-c768 --account=kumamoto-group \
#     -n 2 --mem=4g -t 2-00:00:00 \
#     -J download-ce11 \
#     production-download.sh <sample_list> <staging_dir> [max_concurrent] [max_buffer]
#
set -eo pipefail

SAMPLE_LIST="$1"
STAGING_DIR="$2"
MAX_CONCURRENT="${3:-6}"
MAX_BUFFER="${4:-100}"
# How many download attempts before marking a sample permanently failed.
# A sample's .fail file holds the attempt count; when it reaches this, future
# runs of this daemon skip the sample entirely.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

if [ -z "$SAMPLE_LIST" ] || [ -z "$STAGING_DIR" ]; then
  echo "Usage: $0 <sample_list> <staging_dir> [max_concurrent] [max_buffer]"
  exit 1
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$STAGING_DIR/download.log"

# Apptainer is not in the default PATH on compute nodes. fast-download.sh's
# SRA fasterq-dump fallback probes for apptainer → singularity → docker; without
# this it falls through to docker (no daemon access on the nodes) and the
# fallback fails, so ENA-refused runs can't be rescued. Mirror production-process.sh.
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

mkdir -p "$STAGING_DIR"

# Clear any stale completion marker from a prior run on this staging dir. The
# processor exits when it sees .downloads-complete with no .ready/.running; if a
# re-submitted run left the old marker, a freshly-started processor sees it and
# exits within a second, before this download pass produces any .ready samples.
rm -f "$STAGING_DIR/.downloads-complete"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Production Downloader ==="
log "Sample list: $SAMPLE_LIST ($(wc -l < "$SAMPLE_LIST") samples)"
log "Staging dir: $STAGING_DIR"
log "Max concurrent: $MAX_CONCURRENT"
log "Max buffer: $MAX_BUFFER"

TOTAL=$(wc -l < "$SAMPLE_LIST")
DONE=0
FAIL=0

# Return 0 if the sample is in a terminal state (ready/running/done or
# permanently failed after MAX_ATTEMPTS). 1 if it's a candidate for download.
#
# NOTE: .fail is written by BOTH this downloader (an integer download-attempt
# count) and the processor (a reason word: oom/data/infra/timeout). We disambiguate
# by content: a NON-integer .fail (reason word, or a legacy empty marker) means the
# sample already reached a terminal state downstream — skip it. Only a plain integer
# is our own retry counter. This avoids `[: : integer expression expected` on a
# processor- or legacy-written .fail (the 2026-06-09 rn6 bug).
sample_terminal() {
  local outdir="$1"
  [ -f "$outdir/.ready" ] && return 0
  [ -f "$outdir/.submitted" ] && return 0   # in-flight processing — never re-download (would wipe its FASTQ)
  [ -f "$outdir/.running" ] && return 0
  [ -f "$outdir/.done" ] && return 0
  if [ -f "$outdir/.fail" ]; then
    local attempts
    attempts=$(cat "$outdir/.fail" 2>/dev/null)
    if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then return 0; fi   # reason word / legacy -> terminal
    [ "$attempts" -ge "$MAX_ATTEMPTS" ] && return 0
  fi
  return 1
}

download_one() {
  local exp_acc="$1"
  local outdir="$STAGING_DIR/$exp_acc"

  if sample_terminal "$outdir"; then
    return 0
  fi

  mkdir -p "$outdir"

  # Wipe partial state from prior failed attempt so the new download starts
  # clean — fast-download.sh's cache check is loose and may otherwise see
  # leftover _1.fastq.gz from a previous interrupted run as "cached".
  rm -f "$outdir"/*.fastq.gz "$outdir"/*.fastq 2>/dev/null || true

  if bash "$SCRIPTS_DIR/fast-download.sh" "$exp_acc" "$outdir" >>"$outdir/download.log" 2>&1; then
    rm -f "$outdir/.fail"
    touch "$outdir/.ready"
    log "[OK] $exp_acc"
    return 0
  fi

  local attempts
  attempts=$(cat "$outdir/.fail" 2>/dev/null || echo 0)
  attempts=$((attempts + 1))
  echo "$attempts" > "$outdir/.fail"

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    log "[FAIL-PERM] $exp_acc (attempt $attempts) — will not retry, see $outdir/download.log"
  else
    log "[FAIL] $exp_acc (attempt $attempts/$MAX_ATTEMPTS, see $outdir/download.log)"
  fi
  return 1
}

# Main loop: iterate through sample list, rate-limit concurrent downloads
while IFS=$'\t' read -r exp_acc genome strategy layout; do
  # Skip if in any terminal state (downloaded, processing, done, or
  # permanently failed after MAX_ATTEMPTS).
  if sample_terminal "$STAGING_DIR/$exp_acc"; then
    continue
  fi

  # Buffer control: wait if too many samples are downloaded but not yet processed
  while true; do
    buffered=$(find "$STAGING_DIR" -name ".ready" 2>/dev/null | wc -l)
    if [ "$buffered" -lt "$MAX_BUFFER" ]; then
      break
    fi
    log "[WAIT] Buffer full ($buffered >= $MAX_BUFFER), waiting 30s..."
    sleep 30
  done

  # Concurrency control: wait if too many downloads running
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_CONCURRENT" ]; do
    sleep 2
  done

  download_one "$exp_acc" &

  DONE=$((DONE + 1))
  if [ $((DONE % 50)) -eq 0 ]; then
    log "[PROGRESS] $DONE / $TOTAL submitted, $(find "$STAGING_DIR" -name ".ready" | wc -l) ready, $(find "$STAGING_DIR" -name ".done" | wc -l) processed"
  fi

done < "$SAMPLE_LIST"

# Wait for remaining downloads
wait
log "=== Download phase complete ==="
log "Total: $DONE submitted, $(find "$STAGING_DIR" -name ".ready" | wc -l) ready, $(find "$STAGING_DIR" -name ".fail" 2>/dev/null | wc -l) failed"

# Signal to processor that all downloads are done
touch "$STAGING_DIR/.downloads-complete"
log "Wrote .downloads-complete marker"
