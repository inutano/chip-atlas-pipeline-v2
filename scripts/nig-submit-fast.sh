#!/bin/bash
#
# Submit Option B Fast pipeline jobs for validation samples on NIG.
#
# Usage:
#   bash nig-submit-fast.sh <genome> [threads]
#
# Example:
#   bash nig-submit-fast.sh hg38        # 16 cores per job (default)
#   bash nig-submit-fast.sh hg38 32     # 32 cores per job
#
set -eo pipefail

GENOME="${1:?Usage: $0 <genome> [threads]}"
THREADS="${2:-16}"

BASE_DIR="${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}"
REPO_DIR="$BASE_DIR/repo"
DATA_DIR="$BASE_DIR/data"
REF_DIR="$BASE_DIR/references"
RESULT_DIR="$BASE_DIR/results-fast-${THREADS}t"
LOG_DIR="$BASE_DIR/logs-fast-${THREADS}t"
VENV_DIR="$HOME/venv-chipatlas"
TIMING_LOG="$BASE_DIR/benchmark-option-b-fast-${THREADS}t-${GENOME}.tsv"

PIPELINE_SCRIPT="$REPO_DIR/scripts/pipeline-option-b-fast.sh"
DOWNLOAD_SCRIPT="$REPO_DIR/scripts/fast-download.sh"
SAMPLES_TSV="$REPO_DIR/data/validation-samples.tsv"
FA="$REF_DIR/${GENOME}.fa"

# SLURM settings
PARTITION="${SLURM_PARTITION:-epyc}"
ACCOUNT="${SLURM_ACCOUNT:-}"
MEM_PER_CPU="8g"
TIME_LIMIT="0-12:00:00"

# Genome size for MACS3
declare -A GSIZE=( [hg38]=hs [mm10]=mm [rn6]=2.87e9 [dm6]=dm [ce11]=ce [sacCer3]=1.2e7 [TAIR10]=1.35e8 )
GENOME_SIZE="${GSIZE[$GENOME]:?Unknown genome: $GENOME}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Validate
source "$VENV_DIR/bin/activate"
[ -f "$PIPELINE_SCRIPT" ] || { log "ERROR: Pipeline script not found: $PIPELINE_SCRIPT"; exit 1; }
[ -f "$FA" ] || { log "ERROR: Reference not found: $FA"; exit 1; }

mkdir -p "$RESULT_DIR" "$LOG_DIR" "$DATA_DIR/fastq-cache"

# Initialize timing log
if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\texperiment_type\tnum_reads\tdownload_sec\tpipeline_sec\ttotal_sec\tslurm_job_id\ttimestamp\n" > "$TIMING_LOG"
fi

# Pre-resolve SRX→SRR via TogoID
SRX_SRR_MAP="$DATA_DIR/srx-srr-map-${GENOME}.tsv"
ACCESSIONS=$(tail -n +2 "$SAMPLES_TSV" | awk -F'\t' -v g="$GENOME" '$2==g {print $1}' | paste -sd,)
log "Resolving SRX→SRR for ${GENOME} via TogoID..."
curl -sf --max-time 60 "https://api.togoid.dbcls.jp/convert?ids=${ACCESSIONS}&route=sra_experiment,sra_run&report=pair" \
  | python3 -c "
import json,sys
data = json.load(sys.stdin)
for pair in data['results']:
    print(pair[0] + '\t' + pair[1])
" > "$SRX_SRR_MAP"
log "Resolved $(wc -l < "$SRX_SRR_MAP") SRX→SRR pairs"

# Submit jobs
tail -n +2 "$SAMPLES_TSV" | awk -F'\t' -v g="$GENOME" '$2==g {print $1 "\t" $3 "\t" $8}' | while IFS=$'\t' read -r accession exp_type num_reads; do

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
#SBATCH --cpus-per-task=$THREADS
#SBATCH --mem-per-cpu=$MEM_PER_CPU
#SBATCH -t $TIME_LIMIT
#SBATCH -J cf-${accession}
#SBATCH -o $LOG_DIR/${accession}.log
set -eo pipefail

source $VENV_DIR/bin/activate
export PATH=/opt/pkg/apptainer/1.4.5/bin:\$PATH
export APPTAINER_CACHEDIR=$BASE_DIR/apptainer-cache
export FASTQLIST="$DATA_DIR/ddbj-fastqlist.tsv"

echo "=== ChIP-Atlas v2 Fast: $accession ==="
echo "Start: \$(date)"
echo "Node: \$(hostname)"
echo "CPUs: \$SLURM_CPUS_PER_TASK"

# --- Download ---
echo "[DOWNLOAD] Looking up SRR for $accession..."
SRR=\$(grep "^${accession}	" "$DATA_DIR/srx-srr-map-$GENOME.tsv" | head -1 | cut -f2)
if [ -z "\$SRR" ]; then
  echo "ERROR: No SRR mapping found for $accession"
  exit 1
fi
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

REV_ARG=""
if [ -f "$FASTQ_DIR/\${SRR}_2.fastq" ]; then
  REV_ARG="--fastq-rev $FASTQ_DIR/\${SRR}_2.fastq"
fi

# --- Run fast pipeline ---
echo "[PIPELINE] Running Option B Fast..."
PIPE_START=\$(date +%s)

# Use node-local NVMe as tmpdir for containers
LOCAL_TMP="/data1/chipatlasv2-\$SLURM_JOB_ID"
mkdir -p "\$LOCAL_TMP"
export APPTAINER_TMPDIR="\$LOCAL_TMP"

bash "$PIPELINE_SCRIPT" \
  --sample-id "$accession" \
  --fastq-fwd "\$FWD" \
  \$REV_ARG \
  --genome-fasta "$FA" \
  --chrom-sizes "$REF_DIR/chrom.sizes" \
  --genome-size "$GENOME_SIZE" \
  --outdir "$OUT_DIR" \
  --threads $THREADS

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
rm -rf "\$LOCAL_TMP"
rm -f "$FASTQ_DIR/\${SRR}"*.fastq "$FASTQ_DIR/\${SRR}"*.fastq.gz

echo "=== Done: $accession ==="
JOBSCRIPT

  sbatch ${ACCOUNT:+--account=$ACCOUNT} "$WORK_DIR/run.sh" 2>&1
done

log "=============================="
log "All $GENOME samples submitted (Option B Fast, ${THREADS} threads)."
log "Timing log: $TIMING_LOG"
log "Results: $RESULT_DIR"
log "Monitor: squeue -u \$USER"
log "=============================="
