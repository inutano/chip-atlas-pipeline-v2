#!/bin/bash
#
# ChIP-Atlas Pipeline v2: Bisulfite-seq production pipeline
#
# Runs entirely inside one container. Optimized for throughput:
#   1. Single-container execution (no per-step docker startup overhead)
#   2. All intermediates on local TMPDIR (NVMe), deleted as consumed
#   3. Parallel region calling: hmr + hypermr + pmd + BigWig simultaneously
#
# Note: dnmtools format/uniq use htslib, which requires seekable BAM files,
# so step 1 uses file-based intermediates rather than a Unix pipe. The big
# wins are NVMe locality, container reuse, and the parallel step 3 fan-out.
#
# Container: ghcr.io/inutano/chip-atlas-pipeline-v2-bs:latest
#
# Usage:
#   apptainer exec --bind /data1/tmp:/tmp pipeline-v2-bs.sif bash pipeline-v2-bs.sh \
#     --sample-id SRX12345678 \
#     --fastq-fwd reads_1.fastq.gz \
#     [--fastq-rev reads_2.fastq.gz] \
#     --genome-fasta hg38.fa \
#     --abismal-index hg38.abismal.idx \
#     --chrom-sizes hg38.chrom.sizes \
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
    --sample-id)     SAMPLE_ID="$2"; shift 2 ;;
    --fastq-fwd)     FASTQ_FWD="$2"; shift 2 ;;
    --fastq-rev)     FASTQ_REV="$2"; shift 2 ;;
    --genome-fasta)  GENOME_FA="$2"; shift 2 ;;
    --abismal-index) ABISMAL_IDX="$2"; shift 2 ;;
    --chrom-sizes)   CHROM_SIZES="$2"; shift 2 ;;
    --outdir)        OUTDIR="$2"; shift 2 ;;
    --threads)       THREADS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

for var in SAMPLE_ID FASTQ_FWD GENOME_FA ABISMAL_IDX CHROM_SIZES OUTDIR; do
  if [ -z "${!var}" ]; then
    echo "ERROR: --$(echo $var | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
    exit 1
  fi
done

mkdir -p "$OUTDIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# Working directory — local NVMe when available
# ============================================================
WORK="${TMPDIR:-/tmp}/${SAMPLE_ID}_$$"
mkdir -p "$WORK"

# ============================================================
# Detect SE/PE and set flags
# ============================================================
IS_PAIRED=false
FORMAT_SE_FLAG=""
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  IS_PAIRED=true
else
  FORMAT_SE_FLAG="-single-end"
fi

# ============================================================
# Thread allocation
# ============================================================
# Every step that scales with threads gets all of them. samtools sort and
# the dnmtools tools all use thread pools internally.
SORT_MEM="2G"

# ============================================================
# Step 1: Sequential alignment + format + sort + dedup
# ============================================================
# Each intermediate lives on local NVMe ($WORK) and is deleted as soon as
# the next step has consumed it. This keeps peak disk usage low and avoids
# Lustre I/O entirely.
log "Step 1: abismal → format → sort → uniq → dedup BAM"
DEDUP_BAM="$WORK/${SAMPLE_ID}.dedup.bam"

STEP1_START=$(date +%s)

# Build fastq input args as an array (handles SE/PE without word splitting)
if [ "$IS_PAIRED" = true ]; then
  FASTQ_ARGS=("$FASTQ_FWD" "$FASTQ_REV")
else
  FASTQ_ARGS=("$FASTQ_FWD")
fi

# 1a. abismal alignment
T0=$(date +%s)
dnmtools abismal \
    -i "$ABISMAL_IDX" \
    -t "$THREADS" \
    -B \
    -o "$WORK/mapped.bam" \
    -s "$WORK/abismal.stats" \
    "${FASTQ_ARGS[@]}" 2>"$WORK/abismal.stderr"
log "  abismal: $(($(date +%s) - T0))s"

# 1b. dnmtools format → drop mapped.bam
T0=$(date +%s)
dnmtools format \
    -t "$THREADS" \
    -f abismal \
    -B \
    $FORMAT_SE_FLAG \
    "$WORK/mapped.bam" \
    "$WORK/formatted.bam" 2>"$WORK/format.stderr"
rm -f "$WORK/mapped.bam"
log "  format:  $(($(date +%s) - T0))s"

# 1c. samtools sort → drop formatted.bam
T0=$(date +%s)
samtools sort \
    -@ "$THREADS" \
    -m "$SORT_MEM" \
    -T "$WORK/sort" \
    -o "$WORK/sorted.bam" \
    "$WORK/formatted.bam" 2>"$WORK/sort.stderr"
rm -f "$WORK/formatted.bam"
log "  sort:    $(($(date +%s) - T0))s"

# 1d. dnmtools uniq (dedup) → drop sorted.bam
T0=$(date +%s)
dnmtools uniq \
    -t "$THREADS" \
    "$WORK/sorted.bam" \
    "$DEDUP_BAM" 2>"$WORK/uniq.stderr"
rm -f "$WORK/sorted.bam"
log "  uniq:    $(($(date +%s) - T0))s"

STEP1_END=$(date +%s)
log "Step 1 done: $((STEP1_END - STEP1_START))s"

# ============================================================
# Step 2: Per-CpG methylation counts
# ============================================================
log "Step 2: dnmtools counts"
STEP2_START=$(date +%s)

dnmtools counts \
    -t "$THREADS" \
    -cpg-only \
    -c "$GENOME_FA" \
    "$DEDUP_BAM" \
  | awk -F'\t' -v OFS='\t' '$6 > 0' > "$WORK/counts.tsv"

# Delete the dedup BAM now — no other step needs it
rm -f "$DEDUP_BAM"

STEP2_END=$(date +%s)
log "Step 2 done: $((STEP2_END - STEP2_START))s"

# ============================================================
# Step 3: Parallel region calls + BigWig generation
# ============================================================
log "Step 3: sym + hmr, hypermr, pmd, BigWig (parallel)"
STEP3_START=$(date +%s)

# HMR needs symmetric CpGs — build sym first, then parallel calls
dnmtools sym -t 2 -o "$WORK/counts.sym.tsv" "$WORK/counts.tsv"

# Fan out 4 parallel jobs
(dnmtools hmr -o "$OUTDIR/${SAMPLE_ID}.hmr.bed" "$WORK/counts.sym.tsv" 2>"$WORK/hmr.stderr") &
PID_HMR=$!

(dnmtools hypermr -o "$OUTDIR/${SAMPLE_ID}.hypermr.bed" "$WORK/counts.tsv" 2>"$WORK/hypermr.stderr") &
PID_HYPERMR=$!

(dnmtools pmd -o "$OUTDIR/${SAMPLE_ID}.pmd.bed" "$WORK/counts.tsv" 2>"$WORK/pmd.stderr") &
PID_PMD=$!

# BigWig: sort counts.tsv (lexical chrom order — bedGraphToBigWig is strict),
# single awk pass to produce both BedGraphs, then parallel bedGraphToBigWig.
(
  sort -k1,1 -k2,2n "$WORK/counts.tsv" \
    | awk -F'\t' -v OFS='\t' -v M="$WORK/methyl.bg" -v C="$WORK/cover.bg" '{
        print $1, $2, $2+1, $5 > M
        print $1, $2, $2+1, $6 > C
      }'
  bedGraphToBigWig "$WORK/methyl.bg" "$CHROM_SIZES" "$OUTDIR/${SAMPLE_ID}.methyl.bw" &
  bedGraphToBigWig "$WORK/cover.bg"  "$CHROM_SIZES" "$OUTDIR/${SAMPLE_ID}.cover.bw" &
  wait
) &
PID_BIGWIG=$!

# Wait for all parallel jobs
wait $PID_HMR || log "WARNING: hmr failed"
wait $PID_HYPERMR || log "WARNING: hypermr failed"
wait $PID_PMD || log "WARNING: pmd failed"
wait $PID_BIGWIG || log "WARNING: BigWig failed"

STEP3_END=$(date +%s)
log "Step 3 done: $((STEP3_END - STEP3_START))s"

# ============================================================
# Move diagnostic files to output and cleanup
# ============================================================
cp "$WORK/abismal.stats" "$OUTDIR/${SAMPLE_ID}.abismal.stats" 2>/dev/null || true

# Report summary
echo ""
echo "=== Pipeline v2 BS-seq: $SAMPLE_ID ==="
if [ -f "$WORK/abismal.stats" ]; then
  grep "percent_mapped" "$WORK/abismal.stats" | head -1
fi
echo "CpGs with coverage: $(wc -l < "$WORK/counts.tsv")"
for bed in hmr hypermr pmd; do
  f="$OUTDIR/${SAMPLE_ID}.${bed}.bed"
  [ -f "$f" ] && echo "${bed} regions: $(wc -l < "$f")"
done

rm -rf "$WORK"

TOTAL=$(($(date +%s) - STEP1_START))
log "Pipeline complete: ${TOTAL}s ($(( TOTAL / 60 ))m)"
log "Output: $OUTDIR/"
