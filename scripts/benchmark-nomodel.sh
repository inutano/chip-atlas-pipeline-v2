#!/bin/bash
#
# Benchmark Option A with --nomodel on all ce11 samples.
# Uses fast-download.sh (aria2c + ENA) and caches FASTQs.
#
set -eo pipefail

BASE_DIR="$HOME/repos/chip-atlas-pipeline-v2"
TEST_DIR="/data3/chip-atlas-v2/test-run"
SAMPLES_TSV="$BASE_DIR/data/validation-samples.tsv"
WORKFLOW="$BASE_DIR/cwl/workflows/option-a-nomodel.cwl"
TIMING_LOG="$BASE_DIR/data/benchmark-timing-nomodel.tsv"
DOWNLOAD_SCRIPT="$BASE_DIR/scripts/fast-download.sh"

TARGET_GENOME="ce11"
GENOME_SIZE="ce"

genome_dir="$TEST_DIR/$TARGET_GENOME"
fa="$genome_dir/${TARGET_GENOME}.fa"

# Initialize timing log
if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\ttimestamp\n" > "$TIMING_LOG"
fi

# Process all ce11 samples
tail -n +2 "$SAMPLES_TSV" | awk -F'\t' -v g="$TARGET_GENOME" '$2==g' | while IFS=$'\t' read -r accession genome exp_type antigen cell_type cell_class title num_reads mapping_rate dup_rate num_peaks read_tier; do
  # Skip if already benchmarked
  if grep -q "^${accession}	" "$TIMING_LOG" 2>/dev/null; then
    echo "[SKIP] $accession — already benchmarked"
    continue
  fi

  echo "========================================"
  echo "nomodel: $accession ($genome, $exp_type, ${num_reads} reads)"
  echo "========================================"

  cache_dir="$genome_dir/fastq-cache"
  work_dir="$genome_dir/work-nomodel/$accession"
  output_dir="$genome_dir/results-nomodel/$accession"
  mkdir -p "$cache_dir" "$work_dir" "$output_dir"

  # --- Step 1: Resolve SRR and download ---
  srr=$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${accession}&rettype=xml" \
    | grep -oP 'SRR[0-9]{7,}' | sort -u | head -1)

  if [ -z "$srr" ]; then
    echo "[ERROR] Could not resolve SRR for $accession, skipping"
    continue
  fi

  dl_start=$(date +%s)
  bash "$DOWNLOAD_SCRIPT" "$srr" "$cache_dir" 2>&1 | tail -5
  dl_end=$(date +%s)
  dl_sec=$((dl_end - dl_start))

  # Determine forward read file — handle various naming conventions:
  #   PE: SRR_1.fastq + SRR_2.fastq
  #   SE: SRR.fastq
  #   Unusual: SRR_subreads.fastq, etc.
  if [ -f "${cache_dir}/${srr}_1.fastq" ]; then
    fwd="${cache_dir}/${srr}_1.fastq"
  elif [ -f "${cache_dir}/${srr}.fastq" ]; then
    fwd="${cache_dir}/${srr}.fastq"
  else
    # Find any FASTQ matching this SRR
    fwd=$(ls "${cache_dir}/${srr}"*.fastq 2>/dev/null | head -1)
    if [ -z "$fwd" ]; then
      echo "[WARN] No FASTQ found for $srr, skipping"
      continue
    fi
    echo "[INFO] Using non-standard FASTQ: $(basename "$fwd")"
  fi

  # Build CWL input YAML
  input_yml="$work_dir/input.yml"
  cat > "$input_yml" <<YAML
sample_id: ${accession}
fastq_fwd:
  class: File
  path: ${fwd}
YAML

  if [ -f "${cache_dir}/${srr}_2.fastq" ]; then
    cat >> "$input_yml" <<YAML
fastq_rev:
  class: File
  path: ${cache_dir}/${srr}_2.fastq
YAML
  fi

  cat >> "$input_yml" <<YAML
genome_fasta:
  class: File
  path: ${fa}
  secondaryFiles:
    - class: File
      path: ${fa}.0123
    - class: File
      path: ${fa}.amb
    - class: File
      path: ${fa}.ann
    - class: File
      path: ${fa}.bwt.2bit.64
    - class: File
      path: ${fa}.pac
chrom_sizes:
  class: File
  path: ${genome_dir}/chrom.sizes
genome_size: "${GENOME_SIZE}"
YAML

  # --- Step 2: Run pipeline ---
  echo "[PIPELINE] Running with --nomodel..."
  pipe_start=$(date +%s)

  if cwltool --outdir "$output_dir" "$WORKFLOW" "$input_yml" 2>&1 | tee "$output_dir/cwltool.log" | tail -5; then
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$accession" "$genome" "$exp_type" "$num_reads" "$dl_sec" "$pipe_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"

    # Keep peaks, remove BAM
    rm -f "$output_dir"/*.bam "$output_dir"/*.bam.bai
  else
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))

    printf "%s\t%s\t%s\t%s\t%s\tFAILED\t%s\t%s\n" \
      "$accession" "$genome" "$exp_type" "$num_reads" "$dl_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"
  fi

  rm -rf "$work_dir"
  echo "[DONE] $accession (dl ${dl_sec}s, pipe ${pipe_sec}s)"
  echo ""
done

COMPLETED=$(tail -n +2 "$TIMING_LOG" | grep -cv 'FAILED' || true)
FAILED=$(tail -n +2 "$TIMING_LOG" | grep -c 'FAILED' || true)

echo "========================================"
echo "nomodel benchmark complete!"
echo "Completed: $COMPLETED, Failed: $FAILED"
echo "========================================"

curl -s -X POST https://api.getmoshi.app/api/webhook \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"ADEnnNHEbkI20RHRpBIvf0q2ufMe9orI\", \"title\": \"nomodel Benchmark\", \"message\": \"ce11 nomodel done. ${COMPLETED} OK, ${FAILED} failed.\"}"
