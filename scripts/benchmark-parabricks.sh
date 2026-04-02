#!/bin/bash
#
# Benchmark Parabricks (GPU) pipeline on the same samples already
# processed by the CPU benchmark. Downloads FASTQ fresh (to measure
# download time), but uses Parabricks fq2bam for alignment+sort+dedup.
#
set -eo pipefail

BASE_DIR="$HOME/repos/chip-atlas-pipeline-v2"
TEST_DIR="/data3/chip-atlas-v2/test-run"
CPU_TIMING="$BASE_DIR/data/benchmark-timing-nomodel.tsv"
WORKFLOW="$BASE_DIR/cwl/workflows/option-a-parabricks.cwl"
SRA_IMG="quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"
TIMING_LOG="$BASE_DIR/data/benchmark-timing-parabricks.tsv"

# Target genome (pass as argument, default ce11)
TARGET_GENOME="${1:-ce11}"

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

genome_dir="$TEST_DIR/$TARGET_GENOME"
bwa_dir="$genome_dir/bwa-index"
fa="$bwa_dir/${TARGET_GENOME}.fa"

# Check BWA index
if [ ! -f "${fa}.bwt" ]; then
  echo "ERROR: BWA index not found at $fa. Build it first."
  exit 1
fi

# Initialize timing log
if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\ttimestamp\n" > "$TIMING_LOG"
fi

# Get list of completed CPU samples for this genome
cpu_samples=$(tail -n +2 "$CPU_TIMING" | awk -F'\t' -v g="$TARGET_GENOME" '$2==g && $6!="FAILED" {print $1}')

for accession in $cpu_samples; do
  # Skip if already benchmarked
  if grep -q "^${accession}	" "$TIMING_LOG" 2>/dev/null; then
    echo "[SKIP] $accession — already benchmarked with Parabricks"
    continue
  fi

  # Get metadata from CPU timing
  meta=$(tail -n +2 "$CPU_TIMING" | awk -F'\t' -v a="$accession" '$1==a {print $3"\t"$4; exit}')
  exp_type=$(echo "$meta" | cut -f1)
  num_reads=$(echo "$meta" | cut -f2)

  echo "========================================"
  echo "Parabricks: $accession ($TARGET_GENOME, $exp_type, ${num_reads} reads)"
  echo "========================================"

  work_dir="$genome_dir/work-pb/$accession"
  output_dir="$genome_dir/results-pb/$accession"
  mkdir -p "$work_dir" "$output_dir"

  # --- Step 1: Download FASTQ (reuse if cached, otherwise download) ---
  srr=$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${accession}&rettype=xml" \
    | grep -oP 'SRR[0-9]{7,}' | sort -u | head -1)

  if [ -z "$srr" ]; then
    echo "[ERROR] Could not resolve SRR for $accession, skipping"
    continue
  fi

  # Check if FASTQs already exist in shared cache
  cache_dir="$genome_dir/fastq-cache"
  mkdir -p "$cache_dir"
  dl_sec=0

  if ls "$cache_dir"/${srr}*.fastq 1>/dev/null 2>&1; then
    echo "[CACHE] Using cached FASTQs for $srr"
  else
    echo "[DOWNLOAD] Downloading FASTQ for $srr..."
    dl_start=$(date +%s)
    docker run --rm -v "$cache_dir":/data -w /data "$SRA_IMG" \
      fasterq-dump "$srr" --split-files --skip-technical --threads 4 --outdir . 2>&1 \
      | tail -3
    dl_end=$(date +%s)
    dl_sec=$((dl_end - dl_start))
    echo "  Download time: ${dl_sec}s"
  fi

  # Determine forward read file
  if [ -f "${cache_dir}/${srr}_1.fastq" ]; then
    fwd="${cache_dir}/${srr}_1.fastq"
  elif [ -f "${cache_dir}/${srr}.fastq" ]; then
    fwd="${cache_dir}/${srr}.fastq"
  else
    fwd=$(ls "${cache_dir}/${srr}"*.fastq 2>/dev/null | head -1)
    if [ -z "$fwd" ]; then
      echo "[WARN] No FASTQ found for $srr, skipping"
      continue
    fi
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
      path: ${fa}.fai
    - class: File
      path: ${fa}.amb
    - class: File
      path: ${fa}.ann
    - class: File
      path: ${fa}.bwt
    - class: File
      path: ${fa}.pac
    - class: File
      path: ${fa}.sa
chrom_sizes:
  class: File
  path: ${genome_dir}/chrom.sizes
genome_size: "${GENOME_SIZES[$TARGET_GENOME]}"
num_gpus: 1
YAML

  # --- Step 2: Run Parabricks pipeline ---
  echo "[2/2] Running Parabricks pipeline..."
  pipe_start=$(date +%s)

  if cwltool --enable-ext --outdir "$output_dir" "$WORKFLOW" "$input_yml" 2>&1 | tee "$output_dir/cwltool.log" | tail -5; then
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))
    echo "  Pipeline time: ${pipe_sec}s"
    echo "  Total time: ${total_sec}s"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$accession" "$TARGET_GENOME" "$exp_type" "$num_reads" "$dl_sec" "$pipe_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"

    rm -f "$output_dir"/*.bam "$output_dir"/*.bam.bai
  else
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))
    echo "[ERROR] Parabricks pipeline failed for $accession"
    printf "%s\t%s\t%s\t%s\t%s\tFAILED\t%s\t%s\n" \
      "$accession" "$TARGET_GENOME" "$exp_type" "$num_reads" "$dl_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"
  fi

  rm -rf "$work_dir"
  echo "[DONE] $accession"
  echo ""
done

COMPLETED=$(tail -n +2 "$TIMING_LOG" | grep -cv 'FAILED' || true)
FAILED=$(tail -n +2 "$TIMING_LOG" | grep -c 'FAILED' || true)

echo "========================================"
echo "Parabricks benchmark complete!"
echo "Completed: $COMPLETED, Failed: $FAILED"
echo "Results in: $TIMING_LOG"
echo "========================================"

curl -s -X POST https://api.getmoshi.app/api/webhook \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"ADEnnNHEbkI20RHRpBIvf0q2ufMe9orI\", \"title\": \"Parabricks Benchmark\", \"message\": \"Benchmark finished. ${COMPLETED} completed, ${FAILED} failed.\"}"
