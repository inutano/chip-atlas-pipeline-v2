#!/bin/bash
#
# Download all FASTQ data for an SRX/ERX/DRX experiment.
# Resolves all SRR/ERR/DRR runs, downloads each, concatenates into
# experiment-level FASTQ files (matching v1 pipeline behavior).
#
# Usage: download-experiment.sh <experiment_accession> <output_dir>
#
# Output:
#   SE: <output_dir>/<SRX>.fastq
#   PE: <output_dir>/<SRX>_1.fastq + <output_dir>/<SRX>_2.fastq
#
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXP_ACC="$1"
OUTDIR="$2"

if [ -z "$EXP_ACC" ] || [ -z "$OUTDIR" ]; then
  echo "Usage: $0 <experiment_accession> <output_dir>"
  exit 1
fi

mkdir -p "$OUTDIR"

# Check if experiment-level FASTQs already exist
if [ -f "$OUTDIR/${EXP_ACC}_1.fastq" ] || [ -f "$OUTDIR/${EXP_ACC}.fastq" ]; then
  echo "[CACHE] $EXP_ACC already downloaded"
  exit 0
fi

# --- Step 1: Resolve all run accessions ---
echo "[RESOLVE] Looking up runs for $EXP_ACC..."
runs=$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${EXP_ACC}&rettype=xml" \
  | grep -oP '[DES]RR[0-9]{7,}' | sort -u)

if [ -z "$runs" ]; then
  echo "[ERROR] Could not resolve any runs for $EXP_ACC"
  exit 1
fi

run_count=$(echo "$runs" | wc -w)
echo "[RESOLVE] Found $run_count run(s): $runs"

# --- Step 2: Download each run ---
tmp_dir="$OUTDIR/.tmp_${EXP_ACC}"
mkdir -p "$tmp_dir"

for srr in $runs; do
  echo "[DOWNLOAD] $srr..."
  bash "$SCRIPT_DIR/fast-download.sh" "$srr" "$tmp_dir"
done

# --- Step 3: Determine SE vs PE and concatenate ---
# Check if any run has _1/_2 files (paired-end)
pe_files=$(ls "$tmp_dir"/*_1.fastq 2>/dev/null | wc -l)

if [ "$pe_files" -gt 0 ]; then
  # Paired-end: concatenate all _1 and _2 files
  echo "[CONCAT] Merging $run_count run(s) as paired-end..."
  cat "$tmp_dir"/*_1.fastq > "$OUTDIR/${EXP_ACC}_1.fastq"
  cat "$tmp_dir"/*_2.fastq > "$OUTDIR/${EXP_ACC}_2.fastq"
  echo "[DONE] ${EXP_ACC}_1.fastq ($(wc -l < "$OUTDIR/${EXP_ACC}_1.fastq" | awk '{print $1/4}') reads)"
  echo "[DONE] ${EXP_ACC}_2.fastq"
else
  # Single-end: concatenate all .fastq files
  echo "[CONCAT] Merging $run_count run(s) as single-end..."
  cat "$tmp_dir"/*.fastq > "$OUTDIR/${EXP_ACC}.fastq"
  echo "[DONE] ${EXP_ACC}.fastq ($(wc -l < "$OUTDIR/${EXP_ACC}.fastq" | awk '{print $1/4}') reads)"
fi

# Clean up individual run files
rm -rf "$tmp_dir"
