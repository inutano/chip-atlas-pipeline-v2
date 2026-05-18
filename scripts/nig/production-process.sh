#!/bin/bash
#
# Production processor: scans staging dir for .ready samples and submits
# SLURM jobs to process them. Runs as a loop, polling every INTERVAL seconds.
#
# Usage:
#   sbatch -p kumamoto-c768 --account=kumamoto-group \
#     -n 1 --mem=2g -t 2-00:00:00 \
#     -J process-ce11 \
#     production-process.sh <staging_dir> <pipeline> <genome> <outbase> \
#       [cpus] [mem] [time_limit] [max_concurrent] [interval]
#
set -eo pipefail

STAGING_DIR="$1"
PIPELINE="$2"        # "chipseq" or "bsseq"
GENOME="$3"
OUTBASE="$4"
CPUS="${5:-4}"
MEM="${6:-16g}"
TIME_LIMIT="${7:-0-01:00:00}"
MAX_CONCURRENT="${8:-32}"
INTERVAL="${9:-30}"

if [ -z "$STAGING_DIR" ] || [ -z "$PIPELINE" ] || [ -z "$GENOME" ]; then
  echo "Usage: $0 <staging_dir> <pipeline> <genome> <outbase> [cpus] [mem] [time] [max_concurrent] [interval]"
  exit 1
fi

export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$STAGING_DIR/process.log"

# MACS3 genome size lookup
declare -A MACS3_GSIZE=(
  [sacCer3]=12157105
  [ce11]=100286401
  [dm6]=142573017
  [rn6]=2870184193
  [mm10]=2652783500
  [hg38]=2913022398
)

SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
REF=$SHARED/references
CHIP_SIF=$SHARED/containers/pipeline-v2.sif
BS_SIF=$SHARED/containers/pipeline-v2-bs.sif

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Production Processor ==="
log "Staging: $STAGING_DIR"
log "Pipeline: $PIPELINE, Genome: $GENOME"
log "Output: $OUTBASE"
log "Config: ${CPUS}c, ${MEM}, ${TIME_LIMIT}, max ${MAX_CONCURRENT} concurrent"

TOTAL_SUBMITTED=0
TOTAL_DONE=0

process_sample() {
  local exp_acc="$1"
  local staging="$STAGING_DIR/$exp_acc"

  # Mark as running
  mv "$staging/.ready" "$staging/.running"

  # 3-level output
  local prefix=${exp_acc:0:6}
  local outdir=$OUTBASE/$GENOME/$prefix/$exp_acc
  mkdir -p "$outdir"

  # Find FASTQs
  local fwd=$(ls "$staging/${exp_acc}_1.fastq.gz" 2>/dev/null || ls "$staging/${exp_acc}.fastq.gz" 2>/dev/null || true)
  local rev=$(ls "$staging/${exp_acc}_2.fastq.gz" 2>/dev/null || true)

  if [ -z "$fwd" ]; then
    log "[FAIL] $exp_acc: no FASTQ in staging"
    mv "$staging/.running" "$staging/.fail"
    return 1
  fi

  local rev_arg=""
  [ -n "$rev" ] && rev_arg="--fastq-rev $rev"

  local work=/data1/tmp/${exp_acc}_$$
  mkdir -p "$work"

  local bind_args="--bind /data1/tmp:/data1/tmp --bind $OUTBASE:$OUTBASE --bind $REF:$REF --bind $STAGING_DIR:$STAGING_DIR"
  local rc=0

  if [ "$PIPELINE" = "chipseq" ]; then
    local gsize="${MACS3_GSIZE[$GENOME]:-2913022398}"
    TMPDIR=$work apptainer exec $bind_args "$CHIP_SIF" \
      bash $SCRIPTS_DIR/pipeline-v2.sh \
        --sample-id "$exp_acc" \
        --fastq-fwd "$fwd" $rev_arg \
        --genome-fasta "$REF/${GENOME}.fa" \
        --chrom-sizes "$REF/${GENOME}.chrom.sizes" \
        --genome-size "$gsize" \
        --outdir "$outdir" \
        --threads "$CPUS" || rc=$?

  elif [ "$PIPELINE" = "bsseq" ]; then
    TMPDIR=$work apptainer exec $bind_args "$BS_SIF" \
      bash $SCRIPTS_DIR/pipeline-v2-bs.sh \
        --sample-id "$exp_acc" \
        --fastq-fwd "$fwd" $rev_arg \
        --genome-fasta "$REF/${GENOME}.fa" \
        --abismal-index "$REF/${GENOME}.abismal.idx" \
        --chrom-sizes "$REF/${GENOME}.chrom.sizes" \
        --genome "$GENOME" \
        --outdir "$outdir" \
        --threads "$CPUS" || rc=$?
  fi

  rm -rf "$work"

  if [ $rc -eq 0 ] && [ -f "$outdir/${exp_acc}.stats.tsv" ]; then
    touch "$staging/.done"
    rm -f "$staging/.running"
    # Clean FASTQs from staging (processed successfully)
    rm -f "$staging"/*.fastq.gz "$staging"/*.fastq
    log "[DONE] $exp_acc"
  else
    mv "$staging/.running" "$staging/.fail"
    log "[FAIL] $exp_acc (exit=$rc)"
  fi
}

# Main loop: poll staging for .ready samples, process them
log "Starting processor loop (interval=${INTERVAL}s)"

while true; do
  # Find ready samples
  ready_samples=()
  for ready_file in $(find "$STAGING_DIR" -maxdepth 2 -name ".ready" 2>/dev/null); do
    exp_dir=$(dirname "$ready_file")
    exp_acc=$(basename "$exp_dir")
    ready_samples+=("$exp_acc")
  done

  if [ ${#ready_samples[@]} -eq 0 ]; then
    # Check if download is still running
    downloading=$(find "$STAGING_DIR" -maxdepth 2 -name "download.log" -newer "$STAGING_DIR/process.log" 2>/dev/null | wc -l)
    done_count=$(find "$STAGING_DIR" -maxdepth 2 -name ".done" 2>/dev/null | wc -l)
    fail_count=$(find "$STAGING_DIR" -maxdepth 2 -name ".fail" 2>/dev/null | wc -l)

    # Check if download is complete (marker file written by downloader)
    if [ -f "$STAGING_DIR/.downloads-complete" ]; then
      running=$(find "$STAGING_DIR" -maxdepth 2 -name ".running" 2>/dev/null | wc -l)
      if [ $running -eq 0 ]; then
        done_count=$(find "$STAGING_DIR" -maxdepth 2 -name ".done" 2>/dev/null | wc -l)
        fail_count=$(find "$STAGING_DIR" -maxdepth 2 -name ".fail" 2>/dev/null | wc -l)
        log "Downloads complete, no running jobs. Done=$done_count, Failed=$fail_count"
        break
      fi
    fi

    sleep "$INTERVAL"
    continue
  fi

  # Process ready samples (up to max concurrent)
  for exp_acc in "${ready_samples[@]}"; do
    # Concurrency control
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_CONCURRENT" ]; do
      sleep 5
    done

    process_sample "$exp_acc" &
    TOTAL_SUBMITTED=$((TOTAL_SUBMITTED + 1))

    if [ $((TOTAL_SUBMITTED % 20)) -eq 0 ]; then
      done_count=$(find "$STAGING_DIR" -maxdepth 2 -name ".done" 2>/dev/null | wc -l)
      ready_count=$(find "$STAGING_DIR" -maxdepth 2 -name ".ready" 2>/dev/null | wc -l)
      running_count=$(jobs -rp | wc -l)
      log "[STATUS] submitted=$TOTAL_SUBMITTED done=$done_count ready=$ready_count running=$running_count"
    fi
  done

  sleep "$INTERVAL"
done

wait
TOTAL_DONE=$(find "$STAGING_DIR" -maxdepth 2 -name ".done" 2>/dev/null | wc -l)
TOTAL_FAIL=$(find "$STAGING_DIR" -maxdepth 2 -name ".fail" 2>/dev/null | wc -l)
log "=== Processor complete: done=$TOTAL_DONE failed=$TOTAL_FAIL ==="
