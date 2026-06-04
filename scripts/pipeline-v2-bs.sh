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
# Container: ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.2.0
#
# Usage:
#   apptainer exec --bind /data1/tmp:/tmp pipeline-v2-bs.sif bash pipeline-v2-bs.sh \
#     --sample-id SRX12345678 \
#     --fastq-fwd reads_1.fastq.gz \
#     [--fastq-rev reads_2.fastq.gz] \
#     --genome hg38 \
#     --genome-fasta hg38.fa \
#     --abismal-index hg38.abismal.idx \
#     --chrom-sizes hg38.chrom.sizes \
#     --outdir ./output \
#     [--threads 16]
#
set -eo pipefail

# Shared failure-classification helpers (deterministic data vs transient/infra
# failures). Lives alongside this script in the flat cluster layout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/failure-classify.sh"

# ============================================================
# Parse arguments
# ============================================================
THREADS=16

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-id)     SAMPLE_ID="$2"; shift 2 ;;
    --fastq-fwd)     FASTQ_FWD="$2"; shift 2 ;;
    --fastq-rev)     FASTQ_REV="$2"; shift 2 ;;
    --genome)        GENOME="$2"; shift 2 ;;
    --genome-fasta)  GENOME_FA="$2"; shift 2 ;;
    --abismal-index) ABISMAL_IDX="$2"; shift 2 ;;
    --chrom-sizes)   CHROM_SIZES="$2"; shift 2 ;;
    --outdir)        OUTDIR="$2"; shift 2 ;;
    --threads)       THREADS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

for var in SAMPLE_ID FASTQ_FWD GENOME GENOME_FA ABISMAL_IDX CHROM_SIZES OUTDIR; do
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
LAYOUT_FLAG=0
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  IS_PAIRED=true
  LAYOUT_FLAG=1
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
# CpG count lookup for coverage calculation
# ============================================================
declare -A CPG_COUNTS=(
  [hg38]=61959486
  [mm10]=43816016
  [rn6]=53698106
  [ce11]=6263050
  [dm6]=11787346
  [sacCer3]=710598
)
CPG_COUNT="${CPG_COUNTS[$GENOME]:-0}"
if [ "$CPG_COUNT" -eq 0 ]; then
  log "WARNING: Unknown genome '$GENOME', CpG coverage will be 0"
fi

# ============================================================
# FASTP output paths
# ============================================================
FASTP_JSON="$WORK/fastp.json"

# ============================================================
# Step 0: fastp QC/trimming
# ============================================================
# PE: fastp writes trimmed FASTQs to NVMe scratch (two output streams
#     can't be piped through a single process substitution).
# SE: abismal reads directly from process substitution (no disk write).
log "Step 0: fastp QC/trimming"
T0=$(date +%s)
STEP0_START=$T0   # used by the "Step 0+1a done" timing log below

if [ "$IS_PAIRED" = true ]; then
  fastp --in1 "$FASTQ_FWD" --in2 "$FASTQ_REV" \
    --out1 "$WORK/trim_1.fq.gz" --out2 "$WORK/trim_2.fq.gz" \
    --json "$FASTP_JSON" --thread 2 2>"$WORK/fastp.stderr"
  FASTQ_ARGS=("$WORK/trim_1.fq.gz" "$WORK/trim_2.fq.gz")
  TRIM_CLEANUP=true
  log "  fastp: $(($(date +%s) - T0))s (PE, trimmed to NVMe)"
else
  # SE: fastp streams directly into abismal via process substitution
  # FASTQ_ARGS is set as a single-element array; the actual process
  # substitution is constructed at the abismal invocation below.
  TRIM_CLEANUP=false
  log "  fastp: will stream via process substitution (SE)"
fi

# ============================================================
# Step 1: Sequential alignment + format + sort + dedup
# ============================================================
# Each intermediate lives on local NVMe ($WORK) and is deleted as soon as
# the next step has consumed it. This keeps peak disk usage low and avoids
# Lustre I/O entirely.
log "Step 1: abismal → format → sort → uniq → dedup BAM"
DEDUP_BAM="$WORK/${SAMPLE_ID}.dedup.bam"

STEP1_START=$(date +%s)

# 1a. abismal alignment
T0=$(date +%s)
if [ "$IS_PAIRED" = true ]; then
  # PE: read trimmed FASTQs from NVMe scratch
  dnmtools abismal \
      -i "$ABISMAL_IDX" \
      -t "$THREADS" \
      -B \
      -o "$WORK/mapped.bam" \
      -s "$WORK/abismal.stats" \
      "${FASTQ_ARGS[@]}" 2>"$WORK/abismal.stderr"
  rm -f "$WORK"/trim*.fq.gz
else
  # SE: fastp streams directly into abismal via process substitution
  dnmtools abismal \
      -i "$ABISMAL_IDX" \
      -t "$THREADS" \
      -B \
      -o "$WORK/mapped.bam" \
      -s "$WORK/abismal.stats" \
      <(fastp --in1 "$FASTQ_FWD" --stdout \
          --json "$FASTP_JSON" --thread 2 2>"$WORK/fastp.stderr") \
      2>"$WORK/abismal.stderr"
fi
log "  abismal: $(($(date +%s) - T0))s"

STEP0_END=$(date +%s)
log "Step 0+1a done: fastp+abismal $((STEP0_END - STEP0_START))s"

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

# Capture dedup BAM size for stats, then delete
DEDUP_BAM_SIZE=$(wc -c < "$DEDUP_BAM" 2>/dev/null || echo 0)
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

# Fan out region callers in parallel, each under a wall-clock `timeout`.
# dnmtools pmd has an un-capped beta-binomial MLE loop (TwoStateBetaBin::fit,
# v1.5.1 src/common/TwoStateHMM.cpp:104 — no iteration cap) that spins forever at
# 99.9% CPU on methylation-free genomes (sacCer3/ce11/dm6 — ~all CpGs at 0
# methylation, so the HMM has no two-state structure and Baum-Welch diverges).
# hmr/hypermr handle that data fine, but we wrap all three for safety. They are
# non-blocking (only BigWig gates stats.tsv), so a timeout just omits the .bed.
(timeout 900 dnmtools hmr -o "$OUTDIR/${SAMPLE_ID}.hmr.bed" "$WORK/counts.sym.tsv" 2>"$WORK/hmr.stderr") &
PID_HMR=$!

(timeout 900 dnmtools hypermr -o "$OUTDIR/${SAMPLE_ID}.hypermr.bed" "$WORK/counts.tsv" 2>"$WORK/hypermr.stderr") &
PID_HYPERMR=$!

(timeout 900 dnmtools pmd -i 10 -o "$OUTDIR/${SAMPLE_ID}.pmd.bed" "$WORK/counts.tsv" 2>"$WORK/pmd.stderr") &
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

# Wait for all parallel jobs. Capture BigWig's exit status — it's the
# essential output. hmr/hypermr/pmd are derived analyses; if they fail
# (e.g. low-signal sample with too few CpGs to model), we still keep the
# BigWigs and write stats.tsv.
HMR_RC=0;     wait $PID_HMR     || HMR_RC=$?
HYPERMR_RC=0; wait $PID_HYPERMR || HYPERMR_RC=$?
PMD_RC=0;     wait $PID_PMD     || PMD_RC=$?
BIGWIG_RC=0;  wait $PID_BIGWIG  || BIGWIG_RC=$?
[ "$HMR_RC"     -ne 0 ] && log "WARNING: hmr failed (rc=$HMR_RC)"
[ "$HYPERMR_RC" -ne 0 ] && log "WARNING: hypermr failed (rc=$HYPERMR_RC)"
[ "$PMD_RC"     -ne 0 ] && log "WARNING: pmd failed (rc=$PMD_RC)"
[ "$BIGWIG_RC"  -ne 0 ] && log "WARNING: BigWig failed (rc=$BIGWIG_RC)"

STEP3_END=$(date +%s)
log "Step 3 done: $((STEP3_END - STEP3_START))s"

# ============================================================
# Step 4: deeptools multiBigwigSummary (binned methylation matrix)
#
# Bins the methylation BigWig (methyl.bw). Failure here is non-blocking:
# .npz is derived; methyl.bw / cover.bw remain the canonical outputs.
# ============================================================
log "Step 4: deeptools multiBigwigSummary (binning methyl.bw)"
STEP4_START=$(date +%s)

BIN_RC=0
if [ -s "$OUTDIR/${SAMPLE_ID}.methyl.bw" ]; then
  TMP_NPZ="$WORK/${SAMPLE_ID}.tmp.npz"
  TMP_TSV="$WORK/${SAMPLE_ID}.tmp.tsv"
  REG_TXT="$WORK/${SAMPLE_ID}.regions.txt"

  multiBigwigSummary bins \
      --numberOfProcessors "$THREADS" \
      --bwfiles "$OUTDIR/${SAMPLE_ID}.methyl.bw" \
      --outFileName "$TMP_NPZ" \
      --outRawCounts "$TMP_TSV" \
      --labels "$SAMPLE_ID" \
      2>"$WORK/multiBigwigSummary.stderr" || BIN_RC=$?

  if [ "$BIN_RC" -eq 0 ] && [ -s "$TMP_NPZ" ] && [ -s "$TMP_TSV" ]; then
    # deeptools --outRawCounts emits one header line starting with '#';
    # data rows are chrom\tstart\tend\tvalue. NR>1 skips the header.
    awk -F'\t' 'NR > 1 { print $1 ":" $2 "-" $3 }' "$TMP_TSV" > "$REG_TXT"

    python3 - "$TMP_NPZ" "$REG_TXT" "$OUTDIR/${SAMPLE_ID}.npz" <<'PY' || BIN_RC=$?
import numpy as np, sys
src_npz, reg_txt, out_npz = sys.argv[1:4]
with open(reg_txt, encoding="utf-8") as f:
    regions = np.array([line.rstrip("\n") for line in f], dtype="<U")
z = np.load(src_npz, allow_pickle=True)
matrix = z["matrix"].astype(np.float32, copy=False)
labels = z["labels"]
if labels.dtype == object:
    labels = np.array([str(x) for x in labels.tolist()], dtype="<U")
np.savez_compressed(out_npz, matrix=matrix, labels=labels, regions=regions)
PY
  fi
else
  log "  Skipping: $OUTDIR/${SAMPLE_ID}.methyl.bw not present"
  BIN_RC=1
fi

if [ "$BIN_RC" -ne 0 ] || [ ! -s "$OUTDIR/${SAMPLE_ID}.npz" ]; then
  log "WARNING: binning failed (rc=$BIN_RC) — see $WORK/multiBigwigSummary.stderr; continuing"
fi

log "Step 4 done: $(($(date +%s) - STEP4_START))s"

# ============================================================
# Move diagnostic files to output and cleanup
# ============================================================
cp "$WORK/abismal.stats" "$OUTDIR/${SAMPLE_ID}.abismal.stats" 2>/dev/null || true
cp "$FASTP_JSON" "$OUTDIR/${SAMPLE_ID}_fastp.json" 2>/dev/null || true

# ============================================================
# Collect statistics for v1-compatible stats TSV
#
# stats.tsv is the completion marker. Only write it if BigWig (the
# essential output) succeeded; otherwise the upstream wrapper retries.
# ============================================================
# BigWig is the essential BS-seq output. If it's missing, distinguish:
#   - sample had zero covered CpGs => deterministic bad data (no methylation
#     signal): exit DATA_FAILURE_RC so the wrapper marks it terminal.
#   - data present but the BigWig step failed => transient: exit 1 to retry.
METHYL_OK=0; [ -s "$OUTDIR/${SAMPLE_ID}.methyl.bw" ] && METHYL_OK=1
COVER_OK=0;  [ -s "$OUTDIR/${SAMPLE_ID}.cover.bw" ]  && COVER_OK=1
COVERED_CPGS=$(wc -l < "$WORK/counts.tsv" 2>/dev/null || echo 0)
case "$(classify_bsseq_failure "$BIGWIG_RC" "$METHYL_OK" "$COVER_OK" "$COVERED_CPGS")" in
  data)
    log "DATA-FAIL: zero covered CpGs / no methylation signal — sparse sample, marking terminal"
    exit "$DATA_FAILURE_RC"
    ;;
  infra)
    log "ERROR: BigWig outputs missing or invalid (rc=$BIGWIG_RC) though CpG data exists — refusing stats.tsv (will retry)"
    exit 1
    ;;
esac

TOTAL_MIN=$(( ($(date +%s) - STEP1_START) / 60 ))

# Read count and mapping rate from abismal stats YAML
if [ "$IS_PAIRED" = true ]; then
  READ_COUNT=$(grep "total_pairs:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')
else
  READ_COUNT=$(grep "total_reads:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')
fi
MAP_RATE=$(grep "percent_mapped:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')

# Methylation rate and CpG coverage from counts.tsv
METH_STATS=$(awk -F'\t' -v cpg="$CPG_COUNT" '{
  met += $6 * $5; total += $6
} END {
  if (total > 0) printf "%.1f\t%.1f", met/total*100, total/cpg
  else printf "0.0\t0.0"
}' "$WORK/counts.tsv")
METH_RATE=$(echo "$METH_STATS" | cut -f1)
CPG_COVERAGE=$(echo "$METH_STATS" | cut -f2)

# Region counts
HMR_N=0; PMD_N=0; HYPERMR_N=0
[ -f "$OUTDIR/${SAMPLE_ID}.hmr.bed" ]     && HMR_N=$(wc -l     < "$OUTDIR/${SAMPLE_ID}.hmr.bed")
[ -f "$OUTDIR/${SAMPLE_ID}.pmd.bed" ]     && PMD_N=$(wc -l     < "$OUTDIR/${SAMPLE_ID}.pmd.bed")
[ -f "$OUTDIR/${SAMPLE_ID}.hypermr.bed" ] && HYPERMR_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.hypermr.bed")

# FASTQ file size (bytes), sum for PE
FASTQ_SIZE=$(du -sb "$FASTQ_FWD" ${FASTQ_REV:+"$FASTQ_REV"} 2>/dev/null | awk '{s+=$1} END {print s+0}')

# Write v1-compatible stats TSV (15 columns; cols 12-14 empty for BS-seq)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t\t%s\n' \
  "$SAMPLE_ID" "$LAYOUT_FLAG" "$FASTQ_SIZE" "$DEDUP_BAM_SIZE" \
  "$READ_COUNT" "$MAP_RATE" "$METH_RATE" "$CPG_COVERAGE" \
  "$HMR_N" "$PMD_N" "$HYPERMR_N" "$TOTAL_MIN" \
  > "$OUTDIR/${SAMPLE_ID}.stats.tsv"

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
