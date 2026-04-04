#!/bin/bash
#
# Submit pipeline-v2.sh benchmark jobs on NIG.
# Uses single container (SIF) with NVMe scratch.
#
# Usage: bash nig-benchmark-v2.sh <genome> [threads]
#
set -eo pipefail

GENOME="${1:?Usage: $0 <genome> [threads]}"
THREADS="${2:-8}"

BASE_DIR="${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}"
REPO_DIR="$BASE_DIR/repo"
REF_DIR="$BASE_DIR/references"
FASTQ_DIR="$BASE_DIR/data/fastq-cache"
SIF="$BASE_DIR/containers/pipeline-v2.sif"

BENCH_DIR="$BASE_DIR/bench-v2-${THREADS}c"
LOG_DIR="$BENCH_DIR/logs"
TIMING_LOG="$BENCH_DIR/timing.tsv"

PARTITION="${SLURM_PARTITION:-kumamoto-c768}"
ACCOUNT="${SLURM_ACCOUNT:-kumamoto-group}"

declare -A GSIZE=( [hg38]=hs [mm10]=mm [rn6]=2.87e9 [dm6]=dm [ce11]=ce [sacCer3]=1.2e7 [TAIR10]=1.35e8 )
GENOME_SIZE="${GSIZE[$GENOME]:?Unknown genome: $GENOME}"
FA="$REF_DIR/${GENOME}.fa"
SRX_SRR_MAP="$BASE_DIR/data/srx-srr-map-${GENOME}.tsv"

SAMPLES=(
  SRX22536539 SRX23943860 SRX25139082 SRX25139081 SRX23943859
  SRX18646733 SRX18298170 SRX25793268 SRX26106775 SRX25595128
  SRX26208417 SRX26084085 SRX26323825 SRX26208418 SRX26084084
  SRX26084170 SRX26159220 SRX26159217 SRX26398644 SRX26398647
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

[ -f "$SIF" ] || { log "ERROR: SIF not found: $SIF"; exit 1; }
[ -f "$FA" ]  || { log "ERROR: Reference not found: $FA"; exit 1; }

mkdir -p "$BENCH_DIR" "$LOG_DIR"

if [ ! -f "$TIMING_LOG" ]; then
  printf "accession\tgenome\tnum_reads\tcores\tstep1_sec\tstep2_sec\ttotal_sec\tslurm_job_id\ttimestamp\n" > "$TIMING_LOG"
fi

for ACC in "${SAMPLES[@]}"; do
  if grep -q "^${ACC}	" "$TIMING_LOG" 2>/dev/null; then
    log "SKIP: $ACC (already done)"
    continue
  fi

  SRR=$(grep "^${ACC}	" "$SRX_SRR_MAP" | head -1 | cut -f2)
  [ -z "$SRR" ] && { log "ERROR: No SRR for $ACC"; continue; }

  FWD=""
  REV_ARG=""
  if [ -f "$FASTQ_DIR/${SRR}_1.fastq" ]; then
    FWD="$FASTQ_DIR/${SRR}_1.fastq"
    [ -f "$FASTQ_DIR/${SRR}_2.fastq" ] && REV_ARG="--fastq-rev $FASTQ_DIR/${SRR}_2.fastq"
  elif [ -f "$FASTQ_DIR/${SRR}.fastq" ]; then
    FWD="$FASTQ_DIR/${SRR}.fastq"
  fi
  [ -z "$FWD" ] && { log "ERROR: No FASTQ for $SRR"; continue; }

  WORK_DIR="$BENCH_DIR/$ACC"
  mkdir -p "$WORK_DIR/output"

  cat > "$WORK_DIR/run.sh" <<JOBSCRIPT
#!/bin/bash
#SBATCH -p $PARTITION
#SBATCH --cpus-per-task=$THREADS
#SBATCH --mem=128g
#SBATCH -t 0-06:00:00
#SBATCH -J v2-${THREADS}c-${ACC}
#SBATCH -o $LOG_DIR/${ACC}.log
set -eo pipefail
export PATH=/opt/pkg/apptainer/1.4.5/bin:\$PATH

LOCAL_TMP=/data1/v2-\$SLURM_JOB_ID
mkdir -p \$LOCAL_TMP

echo "=== v2 benchmark: ${THREADS}c, $ACC ==="
echo "Node: \$(hostname)"
echo "Start: \$(date)"

START=\$(date +%s)

apptainer exec --bind "\$LOCAL_TMP:/tmp" $SIF \
  bash $REPO_DIR/scripts/pipeline-v2.sh \
  --sample-id $ACC \
  --fastq-fwd $FWD \
  $REV_ARG \
  --genome-fasta $FA \
  --chrom-sizes $REF_DIR/chrom.sizes \
  --genome-size $GENOME_SIZE \
  --outdir $WORK_DIR/output \
  --threads $THREADS

END=\$(date +%s)
TOTAL=\$((END - START))

# Extract step times from pipeline output
S1=\$(grep "Step 1 done:" $LOG_DIR/${ACC}.log | grep -oP '\d+(?=s)' || echo 0)
S2=\$(grep "Step 2 done:" $LOG_DIR/${ACC}.log | grep -oP '\d+(?=s)' || echo 0)

# Get read count from fastp JSON
READS=\$(python3 -c "import json; d=json.load(open('$WORK_DIR/output/${ACC}_fastp.json')); print(d['summary']['before_filtering']['total_reads'])" 2>/dev/null || echo 0)

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "$ACC" "$GENOME" "\$READS" "$THREADS" "\$S1" "\$S2" "\$TOTAL" \
  "\$SLURM_JOB_ID" "\$(date -Iseconds)" >> $TIMING_LOG

echo "Total: \${TOTAL}s (\$(( TOTAL/60 ))m)"
rm -rf \$LOCAL_TMP
JOBSCRIPT

  sbatch --account=$ACCOUNT "$WORK_DIR/run.sh" 2>&1 | sed "s/^/  /"
  log "Submitted: $ACC ($THREADS cores)"
done

log "=============================="
log "Submitted for $GENOME at ${THREADS}c"
log "Timing: $TIMING_LOG"
log "=============================="
