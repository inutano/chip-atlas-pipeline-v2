#!/bin/bash
#
# ChIP-Atlas Pipeline v2: Production pipeline
#
# Runs entirely inside one container with all tools. Optimized for throughput:
#   1. Pipe-through: fastp → bwa-mem2 → collate → fixmate → sort → markdup
#   2. Tee: dedup BAM split to bedtools genomecov (BigWig) + file (for MACS3)
#   3. Single MACS3 + awk filter for 3 q-value thresholds
#   4. No intermediate files, no container restart overhead
#
# Container: ghcr.io/inutano/chip-atlas-pipeline-v2:latest
#
# Usage:
#   apptainer exec pipeline-v2.sif bash pipeline-v2.sh \
#     --sample-id SRX12345678 \
#     --fastq-fwd reads_1.fastq \
#     [--fastq-rev reads_2.fastq] \
#     --genome-fasta hg38.fa \
#     --chrom-sizes chrom.sizes \
#     --genome-size hs \
#     --outdir ./output \
#     [--threads 8]
#
set -eo pipefail

# ============================================================
# Parse arguments
# ============================================================
THREADS=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-id)    SAMPLE_ID="$2"; shift 2 ;;
    --fastq-fwd)    FASTQ_FWD="$2"; shift 2 ;;
    --fastq-rev)    FASTQ_REV="$2"; shift 2 ;;
    --genome-fasta) GENOME_FA="$2"; shift 2 ;;
    --chrom-sizes)  CHROM_SIZES="$2"; shift 2 ;;
    --genome-size)  GENOME_SIZE="$2"; shift 2 ;;
    --outdir)       OUTDIR="$2"; shift 2 ;;
    --threads)      THREADS="$2"; shift 2 ;;
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

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# Thread allocation
# ============================================================
# fastp is fast, needs minimal threads. bwa-mem2 is the bottleneck.
# samtools sort threads run concurrently in the pipe — keep low to
# avoid oversubscription.
FASTP_T=2
ALIGN_T=$((THREADS > 4 ? THREADS - 2 : 2))
SORT_T=$((THREADS > 8 ? 4 : 2))
SORT_MEM="2G"
BIGWIG_T=$((THREADS > 4 ? THREADS / 2 : 2))

# ============================================================
# Step 1: Piped alignment + BigWig in one pass
# ============================================================
log "Step 1: fastp → bwa-mem2 → collate → fixmate → sort → markdup → tee(BAM + BigWig)"

DEDUP_BAM="$OUTDIR/${SAMPLE_ID}.dedup.bam"
BIGWIG="$OUTDIR/${SAMPLE_ID}.bw"
RG="@RG\\tID:${SAMPLE_ID}\\tSM:${SAMPLE_ID}\\tPL:ILLUMINA"

# Build fastp command
FASTP_ARGS="--in1 $FASTQ_FWD --stdout --json $OUTDIR/${SAMPLE_ID}_fastp.json --thread $FASTP_T"
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  FASTP_ARGS="--in1 $FASTQ_FWD --in2 $FASTQ_REV $FASTP_ARGS"
  BWA_INTERLEAVED="-p"
else
  BWA_INTERLEAVED=""
fi

STEP1_START=$(date +%s)

# Named pipe for the BigWig branch
BIGWIG_FIFO="$OUTDIR/.bigwig_fifo_$$"
mkfifo "$BIGWIG_FIFO"

# Start bedtools genomecov → bedGraphToBigWig reading from the FIFO
(bedtools genomecov -bg -ibam "$BIGWIG_FIFO" \
  | LC_ALL=C sort -k1,1 -k2,2n -S "${SORT_MEM}" --parallel="$SORT_T" \
  | bedGraphToBigWig stdin "$CHROM_SIZES" "$BIGWIG" \
  && log "BigWig done") &
PID_BIGWIG=$!

# Main pipe: fastp → bwa-mem2 → collate → fixmate → sort → markdup → tee
fastp $FASTP_ARGS 2>/dev/null \
  | bwa-mem2 mem -t "$ALIGN_T" -R "$RG" $BWA_INTERLEAVED "$GENOME_FA" - 2>/dev/null \
  | samtools collate -O -@ 2 - \
  | samtools fixmate -m -@ 2 - - \
  | samtools sort -@ "$SORT_T" -m "$SORT_MEM" - \
  | samtools markdup -r -@ 2 - - \
  | tee "$DEDUP_BAM" > "$BIGWIG_FIFO"

# Wait for BigWig to finish
wait $PID_BIGWIG || log "WARNING: BigWig generation failed"
rm -f "$BIGWIG_FIFO"

STEP1_END=$(date +%s)
log "Step 1 done: $((STEP1_END - STEP1_START))s"

# ============================================================
# Step 2: MACS3 peak calling (reads dedup BAM)
# ============================================================
log "Step 2: MACS3 peak calling"
STEP2_START=$(date +%s)

macs3 callpeak \
  -t "$DEDUP_BAM" -n "${SAMPLE_ID}" -g "$GENOME_SIZE" \
  -q 1e-05 -f BAM --outdir "$OUTDIR" \
  2>"$OUTDIR/macs3.stderr" || true

STEP2_END=$(date +%s)
log "Step 2 done: $((STEP2_END - STEP2_START))s"

# ============================================================
# Step 3: Filter peaks + BigBed conversion
# ============================================================
log "Step 3: Filter peaks + BigBed"
PEAKS_05="$OUTDIR/${SAMPLE_ID}_peaks.narrowPeak"

if [ -f "$PEAKS_05" ]; then
  mv "$PEAKS_05" "$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak"
  mv "$OUTDIR/${SAMPLE_ID}_peaks.xls" "$OUTDIR/${SAMPLE_ID}.05_peaks.xls" 2>/dev/null || true
  PEAKS_05="$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak"

  awk '$9 >= 10' "$PEAKS_05" > "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak"
  awk '$9 >= 20' "$PEAKS_05" > "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak"

  # BigBed conversion (parallel)
  for q in 05 10 20; do
    BED="$OUTDIR/${SAMPLE_ID}.${q}_peaks.narrowPeak"
    if [ -s "$BED" ]; then
      (cut -f1-4 "$BED" | sort -k1,1 -k2,2n > "$OUTDIR/.tmp_${q}.bed" \
        && bedToBigBed "$OUTDIR/.tmp_${q}.bed" "$CHROM_SIZES" "$OUTDIR/${SAMPLE_ID}.${q}.bb" \
        && rm -f "$OUTDIR/.tmp_${q}.bed") &
    fi
  done
  wait

  log "Peaks: q05=$(wc -l < "$PEAKS_05") q10=$(wc -l < "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak") q20=$(wc -l < "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak")"
else
  log "No peaks found (MACS3 model building may have failed — expected for low-signal samples)"
fi

# ============================================================
# Cleanup
# ============================================================
rm -f "$DEDUP_BAM" "$OUTDIR/macs3.stderr" "$OUTDIR/${SAMPLE_ID}_summits.bed"

TOTAL=$(($(date +%s) - STEP1_START))
log "Pipeline complete: ${TOTAL}s ($(( TOTAL / 60 ))m)"
log "Output: $OUTDIR/"
