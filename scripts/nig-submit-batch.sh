#!/bin/bash
#
# Submit ChIP-Atlas v2 benchmark jobs for a set of validation samples on NIG.
#
# Usage:
#   bash nig-submit-batch.sh <genome> [workflow]
#
# Examples:
#   bash nig-submit-batch.sh hg38                    # Option B (default)
#   bash nig-submit-batch.sh hg38 option-a-nomodel   # Option A nomodel
#
# Reads samples from data/validation-samples.tsv, filters by genome,
# skips samples already in the timing log.
#
set -eo pipefail

GENOME="${1:?Usage: $0 <genome> [workflow]}"
WORKFLOW_NAME="${2:-option-b}"

BASE_DIR="${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}"
REPO_DIR="$BASE_DIR/repo"
DATA_DIR="$BASE_DIR/data"
REF_DIR="$BASE_DIR/references"
RESULT_DIR="$BASE_DIR/results"
LOG_DIR="$BASE_DIR/logs"
VENV_DIR="$HOME/venv-chipatlas"
TIMING_LOG="$BASE_DIR/benchmark-${WORKFLOW_NAME}-${GENOME}.tsv"

WORKFLOW="$REPO_DIR/cwl/workflows/${WORKFLOW_NAME}.cwl"
FA="$REF_DIR/${GENOME}.fa"
DOWNLOAD_SCRIPT="$REPO_DIR/scripts/fast-download.sh"
SAMPLES_TSV="$REPO_DIR/data/validation-samples.tsv"

# SLURM settings
PARTITION="${SLURM_PARTITION:-epyc}"
ACCOUNT="${SLURM_ACCOUNT:-}"
CPUS_PER_TASK=16
MEM_PER_CPU="8g"
TIME_LIMIT="0-12:00:00"

# Genome size for MACS3
declare -A GSIZE=( [hg38]=hs [mm10]=mm [rn6]=2.87e9 [dm6]=dm [ce11]=ce [sacCer3]=1.2e7 )
GENOME_SIZE="${GSIZE[$GENOME]:?Unknown genome: $GENOME}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Validate
source "$VENV_DIR/bin/activate"
[ -f "$WORKFLOW" ] || { log "ERROR: Workflow not found: $WORKFLOW"; exit 1; }
[ -f "$FA" ]       || { log "ERROR: Reference not found: $FA"; exit 1; }
[ -f "$SAMPLES_TSV" ] || { log "ERROR: Samples TSV not found: $SAMPLES_TSV"; exit 1; }

mkdir -p "$RESULT_DIR" "$LOG_DIR" "$DATA_DIR/fastq-cache"

# Initialize timing log
if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\tslurm_job_id\ttimestamp\n" > "$TIMING_LOG"
fi

SUBMITTED=0
SKIPPED=0

# Read validation samples, filter by genome
tail -n +2 "$SAMPLES_TSV" | awk -F'\t' -v g="$GENOME" '$2==g {print $1 "\t" $3 "\t" $8}' | while IFS=$'\t' read -r accession exp_type num_reads; do

  # Skip if already in timing log
  if grep -q "^${accession}	" "$TIMING_LOG" 2>/dev/null; then
    log "SKIP: $accession (already done)"
    continue
  fi

  log "Submitting: $accession ($exp_type, ${num_reads} reads)"

  SAMPLE_DIR="$RESULT_DIR/$accession"
  WORK_DIR="$SAMPLE_DIR/work"
  OUT_DIR="$SAMPLE_DIR/output"
  FASTQ_DIR="$DATA_DIR/fastq-cache"
  mkdir -p "$WORK_DIR" "$OUT_DIR"

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
export PATH=/opt/pkg/apptainer/1.4.5/bin:\$PATH
export APPTAINER_CACHEDIR=$BASE_DIR/apptainer-cache
export FASTQLIST="$DATA_DIR/ddbj-fastqlist.tsv"

echo "=== ChIP-Atlas v2: $accession ==="
echo "Workflow: $WORKFLOW_NAME"
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
echo "[PIPELINE] Running ${WORKFLOW_NAME}..."
PIPE_START=\$(date +%s)

# Use node-local NVMe for intermediates (3x faster I/O than Lustre)
LOCAL_TMP="/data1/cwltool-\$SLURM_JOB_ID"
mkdir -p "\$LOCAL_TMP"
cwltool --singularity --tmpdir-prefix "\$LOCAL_TMP/tmp/" --tmp-outdir-prefix "\$LOCAL_TMP/out/" \
  --outdir "$OUT_DIR" "$WORKFLOW" "$WORK_DIR/input.yml" 2>&1 | tee "$OUT_DIR/cwltool.log" | tail -10
rm -rf "\$LOCAL_TMP"

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

# --- Cleanup large intermediates ---
rm -f "$OUT_DIR"/*.bam "$OUT_DIR"/*.bam.bai
rm -rf "$WORK_DIR"
# Clean cached FASTQ to save disk (can re-download if needed)
rm -f "$FASTQ_DIR/\${SRR}"*.fastq "$FASTQ_DIR/\${SRR}"*.fastq.gz

echo "=== Done: $accession ==="
JOBSCRIPT

  sbatch ${ACCOUNT:+--account=$ACCOUNT} "$WORK_DIR/run.sh" 2>&1
done

log "=============================="
log "All $GENOME samples submitted for $WORKFLOW_NAME."
log "Timing log: $TIMING_LOG"
log "Monitor: squeue -u \$USER"
log "=============================="
