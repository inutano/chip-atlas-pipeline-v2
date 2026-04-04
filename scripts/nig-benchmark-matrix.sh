#!/bin/bash
#
# Submit benchmark matrix: multiple samples × multiple core counts.
# Measures wall time + MaxRSS for each combination.
#
# Usage: bash nig-benchmark-matrix.sh <genome> <cores...>
# Example: bash nig-benchmark-matrix.sh hg38 8 16
#
set -eo pipefail

GENOME="${1:?Usage: $0 <genome> <cores...>}"
shift
CORE_COUNTS=("$@")
[ ${#CORE_COUNTS[@]} -eq 0 ] && CORE_COUNTS=(8 16)

BASE_DIR="${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}"
REPO_DIR="$BASE_DIR/repo"
REF_DIR="$BASE_DIR/references"
FASTQ_DIR="$BASE_DIR/data/fastq-cache"
VENV_DIR="$HOME/venv-chipatlas"

PARTITION="${SLURM_PARTITION:-kumamoto-c768}"
ACCOUNT="${SLURM_ACCOUNT:-kumamoto-group}"

declare -A GSIZE=( [hg38]=hs [mm10]=mm [rn6]=2.87e9 [dm6]=dm [ce11]=ce [sacCer3]=1.2e7 [TAIR10]=1.35e8 )
GENOME_SIZE="${GSIZE[$GENOME]:?Unknown genome: $GENOME}"
FA="$REF_DIR/${GENOME}.fa"
SRX_SRR_MAP="$BASE_DIR/data/srx-srr-map-${GENOME}.tsv"

# Benchmark sample list (hardcoded for hg38, 20 samples across tiers)
SAMPLES=(
  SRX22536539 SRX23943860 SRX25139082 SRX25139081 SRX23943859
  SRX18646733 SRX18298170 SRX25793268 SRX26106775 SRX25595128
  SRX26208417 SRX26084085 SRX26323825 SRX26208418 SRX26084084
  SRX26084170 SRX26159220 SRX26159217 SRX26398644 SRX26398647
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

for CORES in "${CORE_COUNTS[@]}"; do
  BENCH_DIR="$BASE_DIR/bench-${CORES}c"
  LOG_DIR="$BENCH_DIR/logs"
  TIMING_LOG="$BENCH_DIR/timing.tsv"
  mkdir -p "$BENCH_DIR" "$LOG_DIR"

  if [ ! -f "$TIMING_LOG" ]; then
    printf "accession\tgenome\tnum_reads\tcores\tpipeline_sec\ttotal_sec\tslurm_job_id\ttimestamp\n" > "$TIMING_LOG"
  fi

  log "Submitting ${CORES}c jobs..."

  for ACC in "${SAMPLES[@]}"; do
    # Skip if already done
    if grep -q "^${ACC}	" "$TIMING_LOG" 2>/dev/null; then
      log "  SKIP: $ACC (${CORES}c, already done)"
      continue
    fi

    SRR=$(grep "^${ACC}	" "$SRX_SRR_MAP" | head -1 | cut -f2)
    if [ -z "$SRR" ]; then
      log "  ERROR: No SRR for $ACC"
      continue
    fi

    # Determine FASTQ
    FWD=""
    REV_ARG=""
    if [ -f "$FASTQ_DIR/${SRR}_1.fastq" ]; then
      FWD="$FASTQ_DIR/${SRR}_1.fastq"
      [ -f "$FASTQ_DIR/${SRR}_2.fastq" ] && REV_ARG="--fastq-rev $FASTQ_DIR/${SRR}_2.fastq"
    elif [ -f "$FASTQ_DIR/${SRR}.fastq" ]; then
      FWD="$FASTQ_DIR/${SRR}.fastq"
    fi

    if [ -z "$FWD" ]; then
      log "  ERROR: No FASTQ for $SRR"
      continue
    fi

    WORK_DIR="$BENCH_DIR/$ACC"
    mkdir -p "$WORK_DIR/output"

    cat > "$WORK_DIR/run.sh" <<JOBSCRIPT
#!/bin/bash
#SBATCH -p $PARTITION
#SBATCH --cpus-per-task=$CORES
#SBATCH --mem=128g
#SBATCH -t 0-06:00:00
#SBATCH -J bm-${CORES}c-${ACC}
#SBATCH -o $LOG_DIR/${ACC}.log
set -eo pipefail

source $VENV_DIR/bin/activate
export PATH=/opt/pkg/apptainer/1.4.5/bin:\$PATH
export APPTAINER_CACHEDIR=$BASE_DIR/apptainer-cache

LOCAL_TMP="/data1/bench-\$SLURM_JOB_ID"
mkdir -p "\$LOCAL_TMP"
export APPTAINER_TMPDIR="\$LOCAL_TMP"

echo "=== Benchmark: ${CORES}c, $ACC ==="
echo "Node: \$(hostname)"
echo "Start: \$(date)"

START=\$(date +%s)

bash $REPO_DIR/scripts/pipeline-option-b-fast.sh \
  --sample-id $ACC \
  --fastq-fwd $FWD \
  $REV_ARG \
  --genome-fasta $FA \
  --chrom-sizes $REF_DIR/chrom.sizes \
  --genome-size $GENOME_SIZE \
  --outdir $WORK_DIR/output \
  --threads $CORES

END=\$(date +%s)
PIPE_SEC=\$((END - START))

echo "Pipeline time: \${PIPE_SEC}s (\$(( PIPE_SEC/60 ))m)"

# Get read count from fastp JSON
READS=\$(python3 -c "import json; d=json.load(open('$WORK_DIR/output/${ACC}_fastp.json')); print(d['summary']['before_filtering']['total_reads'])" 2>/dev/null || echo 0)

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "$ACC" "$GENOME" "\$READS" "$CORES" "\$PIPE_SEC" "\$PIPE_SEC" \
  "\$SLURM_JOB_ID" "\$(date -Iseconds)" >> $TIMING_LOG

rm -rf "\$LOCAL_TMP"
echo "=== Done: $ACC ==="
JOBSCRIPT

    sbatch --account=$ACCOUNT "$WORK_DIR/run.sh" 2>&1 | sed "s/^/  /"
  done
done

log "=============================="
log "Benchmark matrix submitted."
log "Configs: ${CORE_COUNTS[*]}"
log "Samples: ${#SAMPLES[@]}"
log "Total jobs: $(( ${#SAMPLES[@]} * ${#CORE_COUNTS[@]} ))"
log ""
log "After completion:"
log "  sacct -u \$USER --format=JobID,JobName%25,Elapsed,MaxRSS,State -S today"
log "  cat $BASE_DIR/bench-*/timing.tsv"
log "=============================="
