#!/bin/bash
#
# ChIP-Atlas Pipeline v2: Option B "Fast" — Optimized single-pass pipeline
#
# Optimizations over the CWL step-by-step approach:
#   1. Pipe-through: fastp → bwa-mem2 → samtools chain → dedup BAM (no intermediate files)
#   2. Parallel post-markdup: bamCoverage + MACS3 run concurrently
#   3. Single MACS3 call at q=1e-05, then filter for 1e-10 and 1e-20
#   4. Reference index preloaded to /dev/shm when available
#
# Usage:
#   bash pipeline-option-b-fast.sh \
#     --sample-id SRX12345678 \
#     --fastq-fwd reads_1.fastq \
#     [--fastq-rev reads_2.fastq] \
#     --genome-fasta hg38.fa \
#     --chrom-sizes chrom.sizes \
#     --genome-size hs \
#     --outdir ./output \
#     [--threads 16]
#
set -eo pipefail

# ============================================================
# Parse arguments
# ============================================================
THREADS=16

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-id)   SAMPLE_ID="$2"; shift 2 ;;
    --fastq-fwd)   FASTQ_FWD="$2"; shift 2 ;;
    --fastq-rev)   FASTQ_REV="$2"; shift 2 ;;
    --genome-fasta) GENOME_FA="$2"; shift 2 ;;
    --chrom-sizes) CHROM_SIZES="$2"; shift 2 ;;
    --genome-size) GENOME_SIZE="$2"; shift 2 ;;
    --outdir)      OUTDIR="$2"; shift 2 ;;
    --threads)     THREADS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

for var in SAMPLE_ID FASTQ_FWD GENOME_FA CHROM_SIZES GENOME_SIZE OUTDIR; do
  if [ -z "${!var}" ]; then
    echo "ERROR: --$(echo $var | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
    exit 1
  fi
done

mkdir -p "$OUTDIR"

# ============================================================
# Container setup — auto-detect runtime
# ============================================================
CONTAINER_CMD=""
GENOME_DIR="$(cd "$(dirname "$GENOME_FA")" && pwd)"
OUTDIR_ABS="$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)"
FWD_DIR="$(cd "$(dirname "$FASTQ_FWD")" && pwd)"
REV_DIR=""
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  REV_DIR="$(cd "$(dirname "$FASTQ_REV")" && pwd)"
fi

if command -v apptainer &>/dev/null; then
  CONTAINER_CMD="apptainer exec"
elif command -v singularity &>/dev/null; then
  CONTAINER_CMD="singularity exec"
elif command -v docker &>/dev/null; then
  DOCKER_VOLS="-v $GENOME_DIR:$GENOME_DIR -v $OUTDIR_ABS:$OUTDIR_ABS -v $FWD_DIR:$FWD_DIR"
  [ -n "$REV_DIR" ] && DOCKER_VOLS="$DOCKER_VOLS -v $REV_DIR:$REV_DIR"
  # -i needed for stdin piping between containers
  CONTAINER_CMD="docker run --rm -i $DOCKER_VOLS"
fi

if [ -z "$CONTAINER_CMD" ]; then
  echo "ERROR: No container runtime found (apptainer/singularity/docker)"
  exit 1
fi

# Container images (without docker:// prefix — added per-runtime)
IMG_FASTP="quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"
IMG_BWAMEM2="quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8"
IMG_SAMTOOLS="quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"
IMG_DEEPTOOLS="quay.io/biocontainers/deeptools:3.5.6--pyhdfd78af_0"
IMG_MACS3="quay.io/biocontainers/macs3:3.0.4--py312h71493bf_0"
IMG_BIGBED="quay.io/biocontainers/ucsc-bedtobigbed:482--hdc0a859_0"

run_tool() {
  local img="$1"; shift
  if [[ "$CONTAINER_CMD" == *apptainer* ]] || [[ "$CONTAINER_CMD" == *singularity* ]]; then
    $CONTAINER_CMD "docker://$img" "$@"
  else
    $CONTAINER_CMD "$img" "$@"
  fi
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# Optional: preload reference genome index to /dev/shm (shared memory)
# ============================================================
SHM_REF=""
SHM_SIZE=$(df /dev/shm 2>/dev/null | awk 'NR==2 {print $4}')
REF_SIZE=$(du -sk "$GENOME_FA".bwt.2bit.64 2>/dev/null | cut -f1)
LOCK="/dev/shm/.chipatlasv2-ref-$(basename "$GENOME_FA").lock"

if [ -n "$SHM_SIZE" ] && [ -n "$REF_SIZE" ] && [ "$SHM_SIZE" -gt $((REF_SIZE * 3)) ] 2>/dev/null; then
  SHM_DIR="/dev/shm/chipatlasv2-$(basename "$GENOME_FA" .fa)"
  if [ -f "$SHM_DIR/$(basename "$GENOME_FA").bwt.2bit.64" ]; then
    log "Reference already in /dev/shm, reusing"
    SHM_REF="$SHM_DIR/$(basename "$GENOME_FA")"
  elif (set -o noclobber; echo $$ > "$LOCK") 2>/dev/null; then
    log "Preloading reference to /dev/shm (~$((REF_SIZE / 1024 / 1024))GB)..."
    mkdir -p "$SHM_DIR"
    cp "$GENOME_FA" "$GENOME_FA".{0123,amb,ann,bwt.2bit.64,pac,fai} "$SHM_DIR/" 2>/dev/null && \
      SHM_REF="$SHM_DIR/$(basename "$GENOME_FA")" && \
      log "Reference loaded to /dev/shm" || \
      log "Failed to load to /dev/shm, using original path"
    rm -f "$LOCK"
  else
    log "Another job is loading reference to /dev/shm, waiting..."
    while [ -f "$LOCK" ]; do sleep 2; done
    if [ -f "$SHM_DIR/$(basename "$GENOME_FA").bwt.2bit.64" ]; then
      SHM_REF="$SHM_DIR/$(basename "$GENOME_FA")"
    fi
  fi
fi

# Use /dev/shm reference if available, otherwise original
ACTIVE_REF="${SHM_REF:-$GENOME_FA}"

# ============================================================
# Step 1: Piped alignment — fastp → bwa-mem2 → sort → fixmate → sort → markdup
# ============================================================
log "Step 1: Piped alignment pipeline (fastp → bwa-mem2 → samtools chain)"
DEDUP_BAM="$OUTDIR/${SAMPLE_ID}.dedup.bam"
FASTP_THREADS=4
ALIGN_THREADS=$((THREADS - FASTP_THREADS))
SORT_THREADS=4
SORT_MEM="2G"

RG="@RG\\tID:${SAMPLE_ID}\\tSM:${SAMPLE_ID}\\tPL:ILLUMINA"

# Build fastp command
FASTP_CMD="run_tool $IMG_FASTP fastp --in1 $FASTQ_FWD"
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  FASTP_CMD="$FASTP_CMD --in2 $FASTQ_REV"
fi
FASTP_CMD="$FASTP_CMD --stdout --json $OUTDIR/${SAMPLE_ID}_fastp.json --html $OUTDIR/${SAMPLE_ID}_fastp.html --thread $FASTP_THREADS"

STEP1_START=$(date +%s)

eval "$FASTP_CMD" 2>"$OUTDIR/fastp.stderr" \
  | run_tool "$IMG_BWAMEM2" bwa-mem2 mem -t "$ALIGN_THREADS" -R "$RG" -p "$ACTIVE_REF" - 2>/dev/null \
  | run_tool "$IMG_SAMTOOLS" samtools sort -n -@ "$SORT_THREADS" -m "$SORT_MEM" - \
  | run_tool "$IMG_SAMTOOLS" samtools fixmate -m - - \
  | run_tool "$IMG_SAMTOOLS" samtools sort -@ "$SORT_THREADS" -m "$SORT_MEM" - \
  | run_tool "$IMG_SAMTOOLS" samtools markdup -r - "$DEDUP_BAM"

run_tool "$IMG_SAMTOOLS" samtools index "$DEDUP_BAM"

STEP1_END=$(date +%s)
log "Step 1 done: $((STEP1_END - STEP1_START))s"

# ============================================================
# Step 2: Parallel — bamCoverage + MACS3 (single call at q=1e-05)
# ============================================================
log "Step 2: bamCoverage + MACS3 (parallel)"
STEP2_START=$(date +%s)

# bamCoverage in background
run_tool "$IMG_DEEPTOOLS" bamCoverage \
  -b "$DEDUP_BAM" -o "$OUTDIR/${SAMPLE_ID}.bw" \
  --binSize 10 --normalizeUsing RPKM -p "$((THREADS / 2))" \
  2>"$OUTDIR/bamcoverage.stderr" &
PID_BAMCOV=$!

# Single MACS3 call at the most permissive threshold (q=1e-05)
run_tool "$IMG_MACS3" macs3 callpeak \
  -t "$DEDUP_BAM" -n "${SAMPLE_ID}" -g "$GENOME_SIZE" \
  -q 1e-05 -f BAM --nomodel --extsize 200 --outdir "$OUTDIR" \
  2>"$OUTDIR/macs3.stderr" || true

# Wait for bamCoverage
wait $PID_BAMCOV || true

STEP2_END=$(date +%s)
log "Step 2 done: $((STEP2_END - STEP2_START))s"

# ============================================================
# Step 3: Filter MACS3 peaks for stricter thresholds + BigBed
# ============================================================
log "Step 3: Filter peaks + BigBed conversion"
PEAKS_05="$OUTDIR/${SAMPLE_ID}_peaks.narrowPeak"

if [ -f "$PEAKS_05" ]; then
  # Rename q05 peaks
  mv "$PEAKS_05" "$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak"
  mv "$OUTDIR/${SAMPLE_ID}_peaks.xls" "$OUTDIR/${SAMPLE_ID}.05_peaks.xls" 2>/dev/null || true
  PEAKS_05="$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak"

  # Filter for q=1e-10 (column 9 >= 10)
  awk '$9 >= 10' "$PEAKS_05" > "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak"

  # Filter for q=1e-20 (column 9 >= 20)
  awk '$9 >= 20' "$PEAKS_05" > "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak"

  # BigBed conversion (parallel)
  for q in 05 10 20; do
    BED="$OUTDIR/${SAMPLE_ID}.${q}_peaks.narrowPeak"
    if [ -s "$BED" ]; then
      (cut -f1-4 "$BED" | sort -k1,1 -k2,2n > "$OUTDIR/tmp_${q}.bed" \
        && run_tool "$IMG_BIGBED" bedToBigBed "$OUTDIR/tmp_${q}.bed" "$CHROM_SIZES" "$OUTDIR/${SAMPLE_ID}.${q}.bb" \
        && rm -f "$OUTDIR/tmp_${q}.bed") &
    fi
  done
  wait

  log "Peaks: q05=$(wc -l < "$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak") q10=$(wc -l < "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak") q20=$(wc -l < "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak")"
else
  log "No peaks found (MACS3 may have failed on low-signal data)"
fi

# ============================================================
# Cleanup
# ============================================================
rm -f "$DEDUP_BAM" "$DEDUP_BAM.bai" "$OUTDIR/fastp.stderr" "$OUTDIR/bamcoverage.stderr" "$OUTDIR/macs3.stderr"
rm -f "$OUTDIR/${SAMPLE_ID}_summits.bed"

TOTAL=$(($(date +%s) - STEP1_START))
log "Pipeline complete: ${TOTAL}s ($(( TOTAL / 60 ))m)"
log "Output: $OUTDIR/"
