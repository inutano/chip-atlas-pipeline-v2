#!/bin/bash
#
# ChIP-Atlas Pipeline v2: NIG Supercomputer Setup & Benchmark (udocker version)
#
# Adapted from nig-setup-and-benchmark.sh for environments where only
# udocker (user-space container runtime) is available.
#
# Usage:
#   # Run setup from a login/gateway node (clones repo, downloads references)
#   bash nig-benchmark-udocker.sh setup
#
#   # Submit benchmark jobs to SLURM (epyc partition)
#   bash nig-benchmark-udocker.sh benchmark
#
#   # Check results
#   bash nig-benchmark-udocker.sh results
#
set -eo pipefail

# ============================================================
# Configuration
# ============================================================
BASE_DIR="${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}"
REPO_DIR="$BASE_DIR/repo"
DATA_DIR="$BASE_DIR/data"
REF_DIR="$BASE_DIR/references"
RESULT_DIR="$BASE_DIR/results"
LOG_DIR="$BASE_DIR/logs"
TIMING_LOG="$BASE_DIR/benchmark-timing-nig.tsv"
VENV_DIR="$HOME/venv-chipatlas"

# SLURM settings
PARTITION="${SLURM_PARTITION:-epyc}"
CPUS_PER_TASK=16
MEM_PER_CPU="8g"
TIME_LIMIT="0-12:00:00"

# Benchmark settings: 6 hg38 samples (1 per type, low tier for quick test)
BENCHMARK_SAMPLES=(
  "SRX26106775:ATAC-Seq:8319188"
  "SRX25595131:Histone:9960556"
  "SRX24105763:RNA polymerase:9921163"
  "SRX25254554:TFs and others:9844155"
  "SRX23943861:DNase-seq:171161"
  "SRX25139082:Bisulfite-Seq:122999"
)

GENOME="hg38"
GENOME_SIZE="hs"

# ============================================================
# Functions
# ============================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

activate_venv() {
  source "$VENV_DIR/bin/activate"
}

# ============================================================
# Phase 1: Setup
# ============================================================
do_setup() {
  log "=============================="
  log "Phase 1: Setup (udocker version)"
  log "=============================="

  mkdir -p "$BASE_DIR" "$DATA_DIR" "$REF_DIR" "$RESULT_DIR" "$LOG_DIR"

  # --- 1.1 Check venv and dependencies ---
  log ""
  log "--- 1.1 Checking dependencies ---"

  if [ ! -f "$VENV_DIR/bin/activate" ]; then
    log "ERROR: Python venv not found at $VENV_DIR"
    log "Create it first: python3 -m venv $VENV_DIR && source $VENV_DIR/bin/activate && pip install udocker cwltool"
    exit 1
  fi

  activate_venv

  for cmd in udocker cwltool git curl aria2c python3; do
    if command -v "$cmd" &>/dev/null; then
      log "OK: $cmd ($(command -v "$cmd"))"
    else
      log "MISSING: $cmd"
      exit 1
    fi
  done

  # Initialize udocker if needed
  if [ ! -d "$HOME/.udocker" ]; then
    log "Initializing udocker..."
    udocker install 2>&1 | tail -3
  fi

  # --- 1.2 Clone repository ---
  log ""
  log "--- 1.2 Cloning repository ---"

  if [ -d "$REPO_DIR/.git" ]; then
    log "Repository already exists, pulling latest..."
    cd "$REPO_DIR" && git pull
  else
    git clone https://github.com/inutano/chip-atlas-pipeline-v2.git "$REPO_DIR"
  fi

  # --- 1.3 Pre-pull container images ---
  log ""
  log "--- 1.3 Pre-pulling container images (udocker) ---"

  IMAGES=(
    "quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8"
    "quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"
    "quay.io/biocontainers/bedtools:2.31.1--hf5e1c6e_2"
    "quay.io/biocontainers/macs3:3.0.4--py312h71493bf_0"
    "quay.io/biocontainers/ucsc-bedgraphtobigwig:482--hdc0a859_0"
    "quay.io/biocontainers/ucsc-bedtobigbed:482--hdc0a859_0"
    "quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"
    "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"
    "quay.io/biocontainers/deeptools:3.5.6--pyhdfd78af_0"
  )

  for img in "${IMAGES[@]}"; do
    if udocker images 2>/dev/null | grep -q "$(echo "$img" | cut -d: -f1)"; then
      log "CACHED: $img"
    else
      log "PULLING: $img"
      udocker pull "$img" 2>&1 | tail -3
    fi
  done

  # --- 1.4 Download and prepare reference genome ---
  log ""
  log "--- 1.4 Preparing hg38 reference ---"

  FA="$REF_DIR/hg38.fa"

  if [ -f "${FA}.bwt.2bit.64" ]; then
    log "hg38 BWA-MEM2 index already exists, skipping."
  else
    if [ ! -f "$FA" ]; then
      log "Downloading hg38 reference genome..."
      curl -s -o "${FA}.gz" "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz"
      gunzip "${FA}.gz"
    fi

    log "Creating FASTA index..."
    udocker run --rm -v "$REF_DIR:$REF_DIR" \
      "quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1" \
      samtools faidx "$FA"
    cut -f1,2 "${FA}.fai" > "$REF_DIR/chrom.sizes"

    log "Building BWA-MEM2 index (this takes ~30-60 min for hg38)..."
    log "Submitting as SLURM job (needs ~64GB RAM)..."

    cat > "$LOG_DIR/bwamem2-index.sh" <<'INDEXSCRIPT'
#!/bin/bash
#SBATCH -p PARTITION_PLACEHOLDER
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=16g
#SBATCH -t 0-02:00:00
#SBATCH -J bwamem2-index
#SBATCH -o LOG_DIR_PLACEHOLDER/bwamem2-index.log
set -eo pipefail
source VENV_PLACEHOLDER/bin/activate
udocker run --rm -v REF_DIR_PLACEHOLDER:REF_DIR_PLACEHOLDER \
  "quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8" \
  bwa-mem2 index FA_PLACEHOLDER
INDEXSCRIPT

    sed -i "s|PARTITION_PLACEHOLDER|$PARTITION|g" "$LOG_DIR/bwamem2-index.sh"
    sed -i "s|LOG_DIR_PLACEHOLDER|$LOG_DIR|g" "$LOG_DIR/bwamem2-index.sh"
    sed -i "s|VENV_PLACEHOLDER|$VENV_DIR|g" "$LOG_DIR/bwamem2-index.sh"
    sed -i "s|REF_DIR_PLACEHOLDER|$REF_DIR|g" "$LOG_DIR/bwamem2-index.sh"
    sed -i "s|FA_PLACEHOLDER|$FA|g" "$LOG_DIR/bwamem2-index.sh"

    sbatch --wait "$LOG_DIR/bwamem2-index.sh"

    if [ -f "${FA}.bwt.2bit.64" ]; then
      log "BWA-MEM2 index complete."
    else
      log "ERROR: BWA-MEM2 indexing failed. Check $LOG_DIR/bwamem2-index.log"
      exit 1
    fi
  fi

  # --- 1.5 Download DDBJ fastqlist cache ---
  log ""
  log "--- 1.5 Downloading DDBJ fastqlist cache ---"

  FASTQLIST="$DATA_DIR/ddbj-fastqlist.tsv"
  if [ -f "$FASTQLIST" ]; then
    log "DDBJ fastqlist already cached."
  else
    log "Downloading (this is ~430MB)..."
    curl -s -o "$FASTQLIST" "https://ddbj.nig.ac.jp/public/ddbj_database/dra/meta/list/fastqlist"
    log "Downloaded: $(wc -l < "$FASTQLIST") entries"
  fi

  log ""
  log "=============================="
  log "Setup complete!"
  log "Base directory: $BASE_DIR"
  log "Run 'bash $0 benchmark' to start benchmarking."
  log "=============================="
}

# ============================================================
# Phase 2: Benchmark
# ============================================================
do_benchmark() {
  log "=============================="
  log "Phase 2: Submitting benchmark jobs"
  log "=============================="

  activate_venv

  WORKFLOW="$REPO_DIR/cwl/workflows/option-b.cwl"
  FA="$REF_DIR/hg38.fa"
  DOWNLOAD_SCRIPT="$REPO_DIR/scripts/fast-download.sh"

  export FASTQLIST="$DATA_DIR/ddbj-fastqlist.tsv"

  # Initialize timing log
  if [ ! -f "$TIMING_LOG" ]; then
    printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\tslurm_job_id\ttimestamp\n" > "$TIMING_LOG"
  fi

  for entry in "${BENCHMARK_SAMPLES[@]}"; do
    IFS=':' read -r accession exp_type num_reads <<< "$entry"

    # Skip if already benchmarked
    if grep -q "^${accession}	" "$TIMING_LOG" 2>/dev/null; then
      log "SKIP: $accession (already benchmarked)"
      continue
    fi

    log "Submitting: $accession ($exp_type, ${num_reads} reads)"

    SAMPLE_DIR="$RESULT_DIR/$accession"
    WORK_DIR="$SAMPLE_DIR/work"
    OUT_DIR="$SAMPLE_DIR/output"
    FASTQ_DIR="$DATA_DIR/fastq-cache"
    mkdir -p "$WORK_DIR" "$OUT_DIR" "$FASTQ_DIR"

    cat > "$WORK_DIR/run.sh" <<JOBSCRIPT
#!/bin/bash
#SBATCH -p $PARTITION
#SBATCH --cpus-per-task=$CPUS_PER_TASK
#SBATCH --mem-per-cpu=$MEM_PER_CPU
#SBATCH -t $TIME_LIMIT
#SBATCH -J ca-${accession}
#SBATCH -o $LOG_DIR/${accession}.log
set -eo pipefail

source $VENV_DIR/bin/activate
export PATH="\$HOME/.local/bin:\$PATH"
export FASTQLIST="$DATA_DIR/ddbj-fastqlist.tsv"

echo "=== ChIP-Atlas v2 Benchmark: $accession ==="
echo "Start: \$(date)"
echo "Node: \$(hostname)"
echo "CPUs: \$SLURM_CPUS_PER_TASK"

# --- Download ---
echo "[DOWNLOAD] Resolving SRR for $accession..."
SRR=\$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${accession}&rettype=xml" | grep -oP '[DES]RR[0-9]{7,}' | sort -u | head -1)
echo "SRR: \$SRR"

DL_START=\$(date +%s)
bash "$DOWNLOAD_SCRIPT" "\$SRR" "$FASTQ_DIR" 2>&1 | tail -5
DL_END=\$(date +%s)
DL_SEC=\$((DL_END - DL_START))
echo "Download time: \${DL_SEC}s"

# --- Determine FASTQ files ---
if [ -f "$FASTQ_DIR/\${SRR}_1.fastq" ]; then
  FWD="$FASTQ_DIR/\${SRR}_1.fastq"
elif [ -f "$FASTQ_DIR/\${SRR}.fastq" ]; then
  FWD="$FASTQ_DIR/\${SRR}.fastq"
else
  FWD=\$(ls "$FASTQ_DIR/\${SRR}"*.fastq 2>/dev/null | head -1)
fi

if [ -z "\$FWD" ]; then
  echo "ERROR: No FASTQ found for \$SRR"
  exit 1
fi

# --- Build input YAML ---
cat > "$WORK_DIR/input.yml" <<YAML
sample_id: ${accession}
fastq_fwd:
  class: File
  path: \$FWD
YAML

if [ -f "$FASTQ_DIR/\${SRR}_2.fastq" ]; then
  cat >> "$WORK_DIR/input.yml" <<YAML
fastq_rev:
  class: File
  path: $FASTQ_DIR/\${SRR}_2.fastq
format: BAMPE
YAML
else
  cat >> "$WORK_DIR/input.yml" <<YAML
format: BAM
YAML
fi

cat >> "$WORK_DIR/input.yml" <<YAML
genome_fasta:
  class: File
  path: $FA
  secondaryFiles:
    - class: File
      path: ${FA}.0123
    - class: File
      path: ${FA}.amb
    - class: File
      path: ${FA}.ann
    - class: File
      path: ${FA}.bwt.2bit.64
    - class: File
      path: ${FA}.pac
chrom_sizes:
  class: File
  path: $REF_DIR/chrom.sizes
genome_size: "$GENOME_SIZE"
YAML

# --- Run pipeline ---
echo "[PIPELINE] Running Option B with udocker..."
PIPE_START=\$(date +%s)

cwltool --udocker --outdir "$OUT_DIR" "$WORKFLOW" "$WORK_DIR/input.yml" 2>&1 | tee "$OUT_DIR/cwltool.log" | tail -10

PIPE_END=\$(date +%s)
PIPE_SEC=\$((PIPE_END - PIPE_START))
TOTAL_SEC=\$((DL_SEC + PIPE_SEC))

echo "Pipeline time: \${PIPE_SEC}s"
echo "Total time: \${TOTAL_SEC}s"
echo "End: \$(date)"

# --- Record timing ---
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \\
  "$accession" "$GENOME" "$exp_type" "$num_reads" "\$DL_SEC" "\$PIPE_SEC" "\$TOTAL_SEC" \\
  "\$SLURM_JOB_ID" "\$(date -Iseconds)" >> "$TIMING_LOG"

# --- Cleanup ---
rm -f "$OUT_DIR"/*.bam "$OUT_DIR"/*.bam.bai
rm -rf "$WORK_DIR"

echo "=== Done: $accession ==="
JOBSCRIPT

    JOB_ID=$(sbatch "$WORK_DIR/run.sh" 2>&1 | grep -oP '\d+')
    log "  Submitted: job $JOB_ID"

  done

  log ""
  log "=============================="
  log "All jobs submitted."
  log "Monitor with: squeue -u \$USER"
  log "Check results with: bash $0 results"
  log "Logs in: $LOG_DIR/"
  log "=============================="
}

# ============================================================
# Phase 3: Results
# ============================================================
do_results() {
  log "=============================="
  log "Benchmark Results"
  log "=============================="

  if [ ! -f "$TIMING_LOG" ]; then
    log "No results yet. Run 'bash $0 benchmark' first."
    exit 0
  fi

  echo ""
  cat "$TIMING_LOG"

  echo ""
  COMPLETED=$(tail -n +2 "$TIMING_LOG" | wc -l)
  TOTAL=${#BENCHMARK_SAMPLES[@]}
  echo "Completed: $COMPLETED / $TOTAL"

  if [ "$COMPLETED" -gt 0 ]; then
    echo ""
    echo "=== Summary ==="
    tail -n +2 "$TIMING_LOG" | awk -F'\t' '
    {
      n++; dl+=$5; pipe+=$6; total+=$7
    }
    END {
      printf "Avg download: %dm\n", dl/n/60
      printf "Avg pipeline: %dm\n", pipe/n/60
      printf "Avg total:    %dm\n", total/n/60
    }'

    echo ""
    echo "=== Comparison with workstation benchmark ==="
    echo "Workstation (Xeon Gold 6226R, 32 cores, RTX 6000 Ada):"
    echo "  Option B CPU avg: 61 min (hg38)"
    echo "  Option B GPU avg: 36 min (hg38)"
    echo ""
    echo "NIG supercomputer (AMD EPYC, $CPUS_PER_TASK cores, udocker):"
    tail -n +2 "$TIMING_LOG" | awk -F'\t' '{n++; p+=$6} END {printf "  Option B CPU avg: %dm (hg38)\n", p/n/60}'
  fi

  echo ""
  echo "=== Job status ==="
  squeue -u "$USER" --format="%.10i %.20j %.8T %.10M %.6D %R" 2>/dev/null || echo "(not on login node)"
}

# ============================================================
# Main
# ============================================================
case "${1:-}" in
  setup)
    do_setup
    ;;
  benchmark)
    do_benchmark
    ;;
  results)
    do_results
    ;;
  *)
    echo "ChIP-Atlas Pipeline v2: NIG Benchmark (udocker)"
    echo ""
    echo "Usage: bash $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup      Clone repo, pull images, download references"
    echo "  benchmark  Submit SLURM benchmark jobs"
    echo "  results    Show benchmark results and comparison"
    ;;
esac
