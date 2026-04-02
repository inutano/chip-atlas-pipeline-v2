#!/bin/bash
#
# Benchmark Option A (nomodel) on selected hg38 samples.
# Uses fast-download.sh (aria2c + ENA) and caches FASTQs.
# Runs 18 samples: 1 per experiment_type × read_tier.
#
set +e  # Don't exit on errors — log failures and continue

BASE_DIR="$HOME/repos/chip-atlas-pipeline-v2"
TEST_DIR="/data3/chip-atlas-v2/test-run"
WORKFLOW="$BASE_DIR/cwl/workflows/option-a-nomodel.cwl"
DOWNLOAD_SCRIPT="$BASE_DIR/scripts/fast-download.sh"
TIMING_LOG="$BASE_DIR/data/benchmark-timing-hg38.tsv"

TARGET_GENOME="hg38"
GENOME_SIZE="hs"

genome_dir="$TEST_DIR/$TARGET_GENOME"
fa="$genome_dir/${TARGET_GENOME}.fa"

# Selected hg38 samples (1 per type × tier, low first)
SAMPLES=(
  "SRX25139082:Bisulfite-Seq:122999"
  "SRX23943861:DNase-seq:171161"
  "SRX26106775:ATAC-Seq:8319188"
  "SRX25595131:Histone:9960556"
  "SRX24105763:RNA polymerase:9921163"
  "SRX25254554:TFs and others:9844155"
  "SRX26398646:ATAC-Seq:40840577"
  "SRX26303598:Bisulfite-Seq:45663534"
  "SRX24388475:DNase-seq:49717898"
  "SRX26268299:Histone:26449798"
  "SRX26084085:RNA polymerase:20166390"
  "SRX26323825:TFs and others:21655684"
  "SRX26398647:ATAC-Seq:59661103"
  "SRX26240695:Bisulfite-Seq:314118028"
  "SRX24388482:DNase-seq:72621891"
  "SRX26084219:Histone:123470970"
  "SRX26084172:RNA polymerase:65441141"
  "SRX26159220:TFs and others:52914730"
)

# Initialize timing log
if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\ttimestamp\n" > "$TIMING_LOG"
fi

for entry in "${SAMPLES[@]}"; do
  IFS=':' read -r accession exp_type num_reads <<< "$entry"

  # Skip if already benchmarked
  if grep -q "^${accession}	" "$TIMING_LOG" 2>/dev/null; then
    echo "[SKIP] $accession — already benchmarked"
    continue
  fi

  echo "========================================"
  echo "hg38: $accession ($exp_type, ${num_reads} reads)"
  echo "========================================"

  cache_dir="$genome_dir/fastq-cache"
  work_dir="$genome_dir/work/$accession"
  output_dir="$genome_dir/results/$accession"
  mkdir -p "$cache_dir" "$work_dir" "$output_dir"

  # Resolve SRR
  srr=$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${accession}&rettype=xml" \
    | grep -oP 'SRR[0-9]{7,}' | sort -u | head -1)

  if [ -z "$srr" ]; then
    echo "[ERROR] Could not resolve SRR for $accession, skipping"
    continue
  fi

  # Download
  dl_start=$(date +%s)
  bash "$DOWNLOAD_SCRIPT" "$srr" "$cache_dir" 2>&1 | tail -5
  dl_end=$(date +%s)
  dl_sec=$((dl_end - dl_start))

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

  # Run pipeline
  echo "[PIPELINE] Running..."
  pipe_start=$(date +%s)

  if cwltool --outdir "$output_dir" "$WORKFLOW" "$input_yml" 2>&1 | tee "$output_dir/cwltool.log" | tail -5; then
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$accession" "$TARGET_GENOME" "$exp_type" "$num_reads" "$dl_sec" "$pipe_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"

    rm -f "$output_dir"/*.bam "$output_dir"/*.bam.bai
  else
    pipe_end=$(date +%s)
    pipe_sec=$((pipe_end - pipe_start))
    total_sec=$((dl_sec + pipe_sec))

    printf "%s\t%s\t%s\t%s\t%s\tFAILED\t%s\t%s\n" \
      "$accession" "$TARGET_GENOME" "$exp_type" "$num_reads" "$dl_sec" "$total_sec" \
      "$(date -Iseconds)" >> "$TIMING_LOG"
  fi

  # Clean up work dir but keep cache
  rm -rf "$work_dir"
  echo "[DONE] $accession (dl ${dl_sec}s, pipe ${pipe_sec:-?}s)"
  echo ""
done

COMPLETED=$(tail -n +2 "$TIMING_LOG" | grep -cv 'FAILED' || true)
FAILED=$(tail -n +2 "$TIMING_LOG" | grep -c 'FAILED' || true)

echo "========================================"
echo "hg38 benchmark complete!"
echo "Completed: $COMPLETED, Failed: $FAILED"
echo "========================================"

curl -s -X POST https://api.getmoshi.app/api/webhook \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"ADEnnNHEbkI20RHRpBIvf0q2ufMe9orI\", \"title\": \"hg38 Benchmark\", \"message\": \"hg38 CPU done. ${COMPLETED} OK, ${FAILED} failed.\"}"
