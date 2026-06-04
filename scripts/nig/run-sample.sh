#!/bin/bash
#
# Process one sample: download FASTQ → run pipeline → output to 3-level dir.
# Called by SLURM array job. Reads sample info from the sample list by line number.
#
# Usage: run-sample.sh <sample_list> <line_number> <pipeline> <genome> <outbase>
#
set -eo pipefail

SAMPLE_LIST="$1"
LINE_NUM="$2"
PIPELINE="$3"     # "chipseq" or "bsseq"
GENOME="$4"
OUTBASE="$5"

export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

# MACS3 genome size lookup (effective/mappable genome size)
declare -A MACS3_GSIZE=(
  [sacCer3]=12157105
  [ce11]=100286401
  [dm6]=142573017
  [rn6]=2870184193
  [mm10]=2652783500
  [hg38]=2913022398
  [TAIR10]=119146348
)

# Read sample info from list
LINE=$(sed -n "${LINE_NUM}p" "$SAMPLE_LIST")
EXP_ACC=$(echo "$LINE" | cut -f1)
STRATEGY=$(echo "$LINE" | cut -f3)
LAYOUT=$(echo "$LINE" | cut -f4)

if [ -z "$EXP_ACC" ]; then
  echo "ERROR: No sample at line $LINE_NUM"
  exit 1
fi

# Paths
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
REF=$SHARED/references
CHIP_SIF=$SHARED/containers/pipeline-v2.sif
BS_SIF=$SHARED/containers/pipeline-v2-bs.sif
SCRIPTS=~/chip-atlas-v2/scripts
WORK=/data1/tmp/${EXP_ACC}_$$

# 3-level output dir: genome/prefix/experiment
PREFIX=${EXP_ACC:0:6}
OUTDIR=$OUTBASE/$GENOME/$PREFIX/$EXP_ACC

# Skip if already processed
if [ -f "$OUTDIR/${EXP_ACC}.stats.tsv" ]; then
  echo "[SKIP] $EXP_ACC already has stats.tsv"
  exit 0
fi

# Clean any partial outputs from a prior interrupted run. stats.tsv is the
# completion marker; if it's missing, any other files in OUTDIR are stale.
if [ -n "$(ls -A "$OUTDIR" 2>/dev/null)" ]; then
  rm -f "$OUTDIR"/*
fi

mkdir -p "$OUTDIR" "$WORK/fastq"

# Trap-clean WORK on any exit (success, error, signal — including SLURM TIMEOUT
# / OOM kill). Without this, killed jobs leak ~50 GB scratch dirs on /data1/tmp
# that admins have to clean (see 2026-05 incident: 924 GB across kumamoto).
trap "rm -rf '$WORK'" EXIT

log() { echo "[$(date '+%H:%M:%S')] $EXP_ACC: $*"; }

# ============================================================
# Step 1: Download FASTQ
# ============================================================
log "Downloading FASTQ"
DL_START=$(date +%s)
DL_OK=false
for dl_attempt in 1 2 3; do
  if TMPDIR=$WORK bash "$SCRIPTS/fast-download.sh" "$EXP_ACC" "$WORK/fastq" 2>&1 | tail -3; then
    DL_OK=true
    break
  fi
  if [ "$dl_attempt" -lt 3 ]; then
    log "Download attempt $dl_attempt failed, retrying in $((60 * dl_attempt))s"
    sleep $((60 * dl_attempt))
    rm -rf "$WORK/fastq"/* 2>/dev/null || true
  fi
done
DL_END=$(date +%s)
if [ "$DL_OK" != true ]; then
  log "ERROR: Download failed after 3 attempts ($((DL_END - DL_START))s total)"
  exit 1
fi
log "Download: $((DL_END - DL_START))s"

# Detect FASTQ files
FWD=$(ls "$WORK/fastq/${EXP_ACC}_1.fastq.gz" 2>/dev/null || ls "$WORK/fastq/${EXP_ACC}.fastq.gz" 2>/dev/null || true)
REV=$(ls "$WORK/fastq/${EXP_ACC}_2.fastq.gz" 2>/dev/null || true)

if [ -z "$FWD" ]; then
  log "ERROR: No FASTQ found after download"
  exit 1
fi

# ============================================================
# Step 2: Run pipeline
# ============================================================
log "Running $PIPELINE pipeline"
PIPE_START=$(date +%s)

# Apptainer bind mounts: NVMe scratch + output dir + references
BIND_ARGS="--bind /data1/tmp:/data1/tmp --bind $OUTBASE:$OUTBASE --bind $REF:$REF"

if [ "$PIPELINE" = "chipseq" ]; then
  REV_ARG=""
  [ -n "$REV" ] && REV_ARG="--fastq-rev $REV"

  GSIZE="${MACS3_GSIZE[$GENOME]:-2913022398}"

  TMPDIR=$WORK apptainer exec $BIND_ARGS \
    "$CHIP_SIF" \
    bash $SCRIPTS/pipeline-v2.sh \
      --sample-id "$EXP_ACC" \
      --fastq-fwd "$FWD" $REV_ARG \
      --genome-fasta "$REF/${GENOME}.fa" \
      --chrom-sizes "$REF/${GENOME}.chrom.sizes" \
      --genome-size "$GSIZE" \
      --outdir "$OUTDIR" \
      --threads "${SLURM_CPUS_PER_TASK:-4}"

elif [ "$PIPELINE" = "bsseq" ]; then
  REV_ARG=""
  [ -n "$REV" ] && REV_ARG="--fastq-rev $REV"

  TMPDIR=$WORK apptainer exec $BIND_ARGS \
    "$BS_SIF" \
    bash $SCRIPTS/pipeline-v2-bs.sh \
      --sample-id "$EXP_ACC" \
      --fastq-fwd "$FWD" $REV_ARG \
      --genome-fasta "$REF/${GENOME}.fa" \
      --abismal-index "$REF/${GENOME}.abismal.idx" \
      --chrom-sizes "$REF/${GENOME}.chrom.sizes" \
      --genome "$GENOME" \
      --outdir "$OUTDIR" \
      --threads "${SLURM_CPUS_PER_TASK:-4}"
fi

PIPE_END=$(date +%s)
log "Pipeline: $((PIPE_END - PIPE_START))s"

# WORK cleanup happens via EXIT trap above.
log "Done: total $((PIPE_END - DL_START))s"
