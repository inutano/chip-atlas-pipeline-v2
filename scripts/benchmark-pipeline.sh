#!/bin/bash
#
# Benchmark the Option A pipeline on validation samples.
# Downloads FASTQ, runs CWL workflow, records per-step timing,
# keeps only final outputs (peaks, bigwig, bigbed) and deletes
# intermediate files to save disk space.
#
set -eo pipefail

BASE_DIR="$HOME/repos/chip-atlas-pipeline-v2"
TEST_DIR="/data3/chip-atlas-v2/test-run"
SAMPLES_TSV="$BASE_DIR/data/validation-samples.tsv"
WORKFLOW="$BASE_DIR/cwl/workflows/option-a.cwl"
SRA_IMG="quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"
TIMING_LOG="$BASE_DIR/data/benchmark-timing.tsv"

# Effective genome sizes for MACS3
declare -A GENOME_SIZES
GENOME_SIZES=(
  ["hg38"]="hs"
  ["mm10"]="mm"
  ["rn6"]="2.87e9"
  ["dm6"]="dm"
  ["ce11"]="ce"
  ["sacCer3"]="1.2e7"
)

# Initialize timing log
if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\ttimestamp\n" > "$TIMING_LOG"
fi

# Process each sample
tail -n +2 "$SAMPLES_TSV" | while IFS=$'\t' read -r accession genome exp_type antigen cell_type cell_class title num_reads mapping_rate dup_rate num_peaks read_tier; do
  # Only process current assemblies
  case "$genome" in
    hg38|mm10|rn6|dm6|ce11|sacCer3) ;;
    *) continue ;;
  esac

  # Check if genome index is ready
  genome_dir="$TEST_DIR/$genome"
  fa="$genome_dir/${genome}.fa"
  if [ ! -f "${fa}.bwt.2bit.64" ]; then
    echo "[SKIP] $accession ($genome) — BWA-MEM2 index not ready"
    continue
  fi

  # Check if already processed
  if grep -q "^${accession}	" "$TIMING_LOG" 2>/dev/null; then
    echo "[SKIP] $accession — already benchmarked"
    continue
  fi

  echo "========================================"
  echo "Processing: $accession ($genome, $exp_type, ${num_reads} reads)"
  echo "========================================"

  work_dir="$genome_dir/work/$accession"
  output_dir="$genome_dir/results/$accession"
  mkdir -p "$work_dir" "$output_dir"

  # --- Step 1: Download FASTQ ---
  echo "[1/2] Downloading FASTQ..."
  dl_start=$(date +%s)

  # Resolve SRR accession
  srr=$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${accession}&rettype=xml" \
    | grep -oP 'SRR[0-9]{7,}' | sort -u | head -1)

  if [ -z "$srr" ]; then
    echo "[ERROR] Could not resolve SRR for $accession, skipping"
    continue
  fi

  docker run --rm -v "$work_dir":/data -w /data "$SRA_IMG" \
    fasterq-dump "$srr" --split-files --skip-technical --threads 4 --outdir . 2>&1 \
    | tail -3

  dl_end=$(date +%s)
  dl_sec=$((dl_end - dl_start))
  echo "  Download time: ${dl_sec}s"

  # Determine SE vs PE — handle fasterq-dump naming:
  #   SE: SRR.fastq (no _1 suffix)
  #   PE: SRR_1.fastq + SRR_2.fastq
  if [ -f "${work_dir}/${srr}_1.fastq" ]; then
    fwd="${work_dir}/${srr}_1.fastq"
  elif [ -f "${work_dir}/${srr}.fastq" ]; then
    fwd="${work_dir}/${srr}.fastq"
  else
    echo "[ERROR] No FASTQ found for $srr, skipping"
    rm -rf "$work_dir"
    continue
  fi

  # Build CWL input YAML
  input_yml="$work_dir/input.yml"
  cat > "$input_yml" <<YAML
sample_id: ${accession}
fastq_fwd:
  class: File
  path: ${fwd}
YAML

  if [ -f "${work_dir}/${srr}_2.fastq" ]; then
    cat >> "$input_yml" <<YAML
fastq_rev:
  class: File
  path: ${work_dir}/${srr}_2.fastq
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
genome_size: "${GENOME_SIZES[$genome]}"
YAML

  # --- Step 2: Run pipeline ---
  echo "[2/2] Running pipeline..."
  pipe_start=$(date +%s)

  if cwltool --outdir "$output_dir" "$WORKFLOW" "$input_yml" 2>&1 | tee "$output_dir/cwltool.log" | tail -5; then
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))
    echo "  Pipeline time: ${pipe_sec}s"
    echo "  Total time: ${total_sec}s"

    # Record timing
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$accession" "$genome" "$exp_type" "$num_reads" "$dl_sec" "$pipe_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"

    # Clean up intermediate files (keep only peaks, bigwig, bigbed, xls)
    rm -f "$output_dir"/*.bam "$output_dir"/*.bam.bai
  else
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))
    echo "[ERROR] Pipeline failed for $accession"
    printf "%s\t%s\t%s\t%s\t%s\tFAILED\t%s\t%s\n" \
      "$accession" "$genome" "$exp_type" "$num_reads" "$dl_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"
  fi

  # Clean up FASTQ and work files
  rm -rf "$work_dir"

  echo "[DONE] $accession"
  echo ""
done

COMPLETED=$(tail -n +2 "$TIMING_LOG" | grep -cv 'FAILED' || true)
FAILED=$(tail -n +2 "$TIMING_LOG" | grep -c 'FAILED' || true)

echo "========================================"
echo "Benchmark complete! Results in: $TIMING_LOG"
echo "Completed: $COMPLETED, Failed: $FAILED"
echo "========================================"

# Notify via Moshi
curl -s -X POST https://api.getmoshi.app/api/webhook \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"ADEnnNHEbkI20RHRpBIvf0q2ufMe9orI\", \"title\": \"ChIP-Atlas Benchmark\", \"message\": \"Benchmark finished. ${COMPLETED} completed, ${FAILED} failed. Check data/benchmark-timing.tsv\"}"
