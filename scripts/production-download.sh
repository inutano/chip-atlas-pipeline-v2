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

if [ -z "$SAMPLE_LIST" ] || [ -z "$STAGING_DIR" ]; then
  echo "Usage: $0 <sample_list> <staging_dir> [max_concurrent] [max_buffer]"
  exit 1
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$STAGING_DIR/download.log"

mkdir -p "$STAGING_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Production Downloader ==="
log "Sample list: $SAMPLE_LIST ($(wc -l < "$SAMPLE_LIST") samples)"
log "Staging dir: $STAGING_DIR"
log "Max concurrent: $MAX_CONCURRENT"
log "Max buffer: $MAX_BUFFER"

TOTAL=$(wc -l < "$SAMPLE_LIST")
DONE=0
FAIL=0

download_one() {
  local exp_acc="$1"
  local outdir="$STAGING_DIR/$exp_acc"

  # Skip if already ready, running, or done
  if [ -f "$outdir/.ready" ] || [ -f "$outdir/.running" ] || [ -f "$outdir/.done" ]; then
    return 0
  fi

  mkdir -p "$outdir"

  # Download
  if bash "$SCRIPTS_DIR/fast-download.sh" "$exp_acc" "$outdir" >>"$outdir/download.log" 2>&1; then
    touch "$outdir/.ready"
    log "[OK] $exp_acc"
    return 0
  else
    log "[FAIL] $exp_acc (see $outdir/download.log)"
    return 1
  fi
}

# Main loop: iterate through sample list, rate-limit concurrent downloads
while IFS=$'\t' read -r exp_acc genome strategy layout; do
  # Skip if already handled
  if [ -f "$STAGING_DIR/$exp_acc/.ready" ] || \
     [ -f "$STAGING_DIR/$exp_acc/.running" ] || \
     [ -f "$STAGING_DIR/$exp_acc/.done" ]; then
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
