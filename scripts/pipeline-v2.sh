#!/bin/bash
#
# ChIP-Atlas Pipeline v2: Production pipeline
#
# Runs entirely inside one container with all tools. Optimized for throughput:
#   1. Pipe-through: fastp → bwa-mem2 → collate → fixmate → sort → markdup
#   2. All intermediates on local TMPDIR (NVMe) — only final outputs to Lustre
#   3. Single MACS3 + awk filter for 3 q-value thresholds
#   4. No intermediate files on shared filesystem, no container restart overhead
#
# Container: ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0
#
# Usage:
#   apptainer exec --bind /data1/tmp:/tmp pipeline-v2.sif bash pipeline-v2.sh \
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
# Working directory — use local NVMe when available
# ============================================================
# All intermediates (dedup BAM, BedGraph, samtools temps, logs) go here.
# Only final outputs (BigWig, peaks, BigBed, fastp JSON) are copied to $OUTDIR.
WORK="${TMPDIR:-/tmp}/${SAMPLE_ID}_$$"
mkdir -p "$WORK"

# ============================================================
# Thread allocation
# ============================================================
# bwa-mem2 is the CPU bottleneck — give it almost all threads.
# collate/fixmate/markdup are I/O-bound, single-threaded is fine.
# samtools sort needs a few threads for merge.
FASTP_T=2
ALIGN_T=$((THREADS > 3 ? THREADS - 1 : 2))
SORT_T=$((THREADS > 8 ? 3 : 2))
SORT_MEM="4G"

# ============================================================
# Step 1: Piped alignment
# ============================================================
DEDUP_BAM="$WORK/${SAMPLE_ID}.dedup.bam"
RG="@RG\\tID:${SAMPLE_ID}\\tSM:${SAMPLE_ID}\\tPL:ILLUMINA"

# Detect paired-end vs single-end
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  IS_PAIRED=true
else
  IS_PAIRED=false
fi

STEP1_START=$(date +%s)

if [ "$IS_PAIRED" = true ]; then
  log "Step 1: fastp → bwa-mem2 -p → collate → fixmate → sort → markdup (paired-end)"
  fastp --in1 "$FASTQ_FWD" --in2 "$FASTQ_REV" \
      --stdout --json "$WORK/${SAMPLE_ID}_fastp.json" --thread $FASTP_T \
      2>"$WORK/fastp.stderr" \
    | bwa-mem2 mem -t "$ALIGN_T" -R "$RG" -p "$GENOME_FA" - 2>"$WORK/bwamem2.stderr" \
    | samtools collate -O -T "$WORK/collate" - \
    | samtools fixmate -m - - \
    | samtools sort -@ "$SORT_T" -m "$SORT_MEM" -T "$WORK/sort" - \
    | samtools markdup -r - "$DEDUP_BAM"
else
  log "Step 1: fastp → bwa-mem2 → sort → markdup (single-end)"
  fastp --in1 "$FASTQ_FWD" \
      --stdout --json "$WORK/${SAMPLE_ID}_fastp.json" --thread $FASTP_T \
      2>"$WORK/fastp.stderr" \
    | bwa-mem2 mem -t "$ALIGN_T" -R "$RG" "$GENOME_FA" - 2>"$WORK/bwamem2.stderr" \
    | samtools sort -@ "$SORT_T" -m "$SORT_MEM" -T "$WORK/sort" - \
    | samtools markdup -r - "$DEDUP_BAM"
fi

STEP1_END=$(date +%s)
log "Step 1 done: $((STEP1_END - STEP1_START))s"

# ============================================================
# Step 2: BigWig + MACS3 in parallel (both read dedup BAM from NVMe)
# ============================================================
log "Step 2: BigWig + MACS3 (parallel)"
STEP2_START=$(date +%s)

# Count mapped reads for RPM normalization (reads per million mapped reads)
MAPPED=$(samtools view -c -F 4 "$DEDUP_BAM")
log "  Mapped reads (post-dedup): $MAPPED"

# BigWig via bedtools genomecov → RPM normalize → bedGraphToBigWig
# BAM is coordinate-sorted → output is already sorted → no re-sort needed
BEDGRAPH="$WORK/${SAMPLE_ID}.bedGraph"
(bedtools genomecov -bg -ibam "$DEDUP_BAM" \
  | awk -v total="$MAPPED" -v OFS='\t' '{print $1, $2, $3, $4*1000000/total}' \
  > "$BEDGRAPH" \
  && bedGraphToBigWig "$BEDGRAPH" "$CHROM_SIZES" "$OUTDIR/${SAMPLE_ID}.bw" \
  && rm -f "$BEDGRAPH") &
PID_BIGWIG=$!

# MACS3 peak calling — use BAMPE for paired-end, BAM for single-end
if [ "$IS_PAIRED" = true ]; then
  MACS3_FMT="BAMPE"
else
  MACS3_FMT="BAM"
fi

macs3 callpeak \
  -t "$DEDUP_BAM" -n "${SAMPLE_ID}" -g "$GENOME_SIZE" \
  -q 1e-05 -f "$MACS3_FMT" --outdir "$WORK" \
  2>"$WORK/macs3.stderr" || true

wait $PID_BIGWIG || log "WARNING: BigWig generation failed"

STEP2_END=$(date +%s)
log "Step 2 done: $((STEP2_END - STEP2_START))s"

# ============================================================
# Step 3: Filter peaks + BigBed conversion
# ============================================================
log "Step 3: Filter peaks + BigBed"
PEAKS_05="$WORK/${SAMPLE_ID}_peaks.narrowPeak"

if [ -f "$PEAKS_05" ]; then
  mv "$PEAKS_05" "$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak"
  mv "$WORK/${SAMPLE_ID}_peaks.xls" "$OUTDIR/${SAMPLE_ID}.05_peaks.xls" 2>/dev/null || true
  PEAKS_05="$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak"

  awk '$9 >= 10' "$PEAKS_05" > "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak"
  awk '$9 >= 20' "$PEAKS_05" > "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak"

  for q in 05 10 20; do
    BED="$OUTDIR/${SAMPLE_ID}.${q}_peaks.narrowPeak"
    if [ -s "$BED" ]; then
      (cut -f1-4 "$BED" | sort -k1,1 -k2,2n > "$WORK/.tmp_${q}.bed" \
        && bedToBigBed "$WORK/.tmp_${q}.bed" "$CHROM_SIZES" "$OUTDIR/${SAMPLE_ID}.${q}.bb" \
        && rm -f "$WORK/.tmp_${q}.bed") &
    fi
  done
  wait

  log "Peaks: q05=$(wc -l < "$PEAKS_05") q10=$(wc -l < "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak") q20=$(wc -l < "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak")"
else
  log "No peaks found (MACS3 model building may have failed — expected for low-signal samples)"
fi

# ============================================================
# Step 4: Statistics TSV (v1-compatible, 15 columns)
# ============================================================
log "Step 4: Writing statistics TSV"

FASTP_JSON="$WORK/${SAMPLE_ID}_fastp.json"

# Read counts from fastp JSON
READS_BEFORE=$(python3 -c "import json; d=json.load(open('$FASTP_JSON')); print(d['summary']['before_filtering']['total_reads'])" 2>/dev/null || echo 0)
READS_AFTER=$(python3 -c "import json; d=json.load(open('$FASTP_JSON')); print(d['summary']['after_filtering']['total_reads'])" 2>/dev/null || echo 0)

# Rates (guard against zero READS_AFTER)
if [ "${READS_AFTER:-0}" -gt 0 ] 2>/dev/null; then
  MAP_RATE=$(awk "BEGIN {printf \"%.1f\", $MAPPED / $READS_AFTER * 100}")
  DUP_RATE=$(awk "BEGIN {printf \"%.1f\", (1 - $MAPPED / $READS_AFTER) * 100}")
else
  MAP_RATE=0
  DUP_RATE=0
fi

# File sizes (0 for intermediates not kept)
FASTQ_SIZE=$(wc -c < "$FASTQ_FWD" 2>/dev/null || echo 0)
BW_SIZE=$(wc -c < "$OUTDIR/${SAMPLE_ID}.bw" 2>/dev/null || echo 0)

# Peak counts
PEAKS_05_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak" 2>/dev/null || echo 0)
PEAKS_10_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak" 2>/dev/null || echo 0)
PEAKS_20_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak" 2>/dev/null || echo 0)

# Elapsed time in minutes
TOTAL_MIN=$(awk "BEGIN {printf \"%.2f\", ($(date +%s) - $STEP1_START) / 60}")

# SE=0, PE=1
PE_FLAG=0
[ "$IS_PAIRED" = true ] && PE_FLAG=1

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$SAMPLE_ID" \
  "$PE_FLAG" \
  "$FASTQ_SIZE" \
  "0" \
  "$READS_BEFORE" \
  "$READS_AFTER" \
  "$MAP_RATE" \
  "$DUP_RATE" \
  "0" \
  "0" \
  "$BW_SIZE" \
  "$PEAKS_05_N" \
  "$PEAKS_10_N" \
  "$PEAKS_20_N" \
  "$TOTAL_MIN" \
  > "$OUTDIR/${SAMPLE_ID}.stats.tsv"

log "Stats: reads_before=$READS_BEFORE reads_after=$READS_AFTER mapped=$MAPPED map_rate=${MAP_RATE}% peaks_q05=$PEAKS_05_N time=${TOTAL_MIN}m"

# ============================================================
# Move fastp report to final output, cleanup work dir
# ============================================================
mv "$WORK/${SAMPLE_ID}_fastp.json" "$OUTDIR/" 2>/dev/null || true
rm -rf "$WORK"

TOTAL=$(($(date +%s) - STEP1_START))
log "Pipeline complete: ${TOTAL}s ($(( TOTAL / 60 ))m)"
log "Output: $OUTDIR/"
