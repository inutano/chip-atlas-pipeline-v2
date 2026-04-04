#!/bin/bash
#
# Submit memory/performance profiling jobs for different core counts.
# Runs the same sample with 4, 8, 16, 32 cores to measure MaxRSS and wall time.
#
# Usage: bash nig-profile-cores.sh <accession> <srr> <genome>
#
set -eo pipefail

ACC="${1:?Usage: $0 <accession> <srr> <genome>}"
SRR="${2:?Usage: $0 <accession> <srr> <genome>}"
GENOME="${3:-hg38}"

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

# Determine FASTQ files
FWD=""
REV_ARG=""
if [ -f "$FASTQ_DIR/${SRR}_1.fastq" ]; then
  FWD="$FASTQ_DIR/${SRR}_1.fastq"
  [ -f "$FASTQ_DIR/${SRR}_2.fastq" ] && REV_ARG="--fastq-rev $FASTQ_DIR/${SRR}_2.fastq"
elif [ -f "$FASTQ_DIR/${SRR}.fastq" ]; then
  FWD="$FASTQ_DIR/${SRR}.fastq"
else
  echo "ERROR: No FASTQ found for $SRR in $FASTQ_DIR"
  exit 1
fi

echo "Sample: $ACC ($SRR, $(wc -l < "$FWD" 2>/dev/null | awk '{printf "%.0fM reads", $1/4/1e6}'))"
echo "FASTQ: $FWD"

for CORES in 4 8 16 32; do
  PROF_DIR="$BASE_DIR/profile/${ACC}-${CORES}c"
  mkdir -p "$PROF_DIR/output"

  cat > "$PROF_DIR/run.sh" <<JOBSCRIPT
#!/bin/bash
#SBATCH -p $PARTITION
#SBATCH --cpus-per-task=$CORES
#SBATCH --mem=128g
#SBATCH -t 0-06:00:00
#SBATCH -J prof-${CORES}c-${ACC}
#SBATCH -o $PROF_DIR/job.log
set -eo pipefail

source $VENV_DIR/bin/activate
export PATH=/opt/pkg/apptainer/1.4.5/bin:\$PATH
export APPTAINER_CACHEDIR=$BASE_DIR/apptainer-cache

LOCAL_TMP="/data1/profile-\$SLURM_JOB_ID"
mkdir -p "\$LOCAL_TMP"
export APPTAINER_TMPDIR="\$LOCAL_TMP"

echo "=== Profile: $CORES cores, $ACC ==="
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
  --outdir $PROF_DIR/output \
  --threads $CORES

END=\$(date +%s)
echo "Total wall time: \$((END - START))s (\$(( (END-START)/60 ))m)"
echo "End: \$(date)"

rm -rf "\$LOCAL_TMP"
JOBSCRIPT

  JOB=$(sbatch --account=$ACCOUNT "$PROF_DIR/run.sh" 2>&1 | grep -oP '\d+')
  echo "Submitted ${CORES}c: job $JOB"
done

echo ""
echo "After completion, check results with:"
echo "  sacct -j <jobid> --format=JobID,JobName,Elapsed,MaxRSS,MaxVMSize,State"
echo "  cat $BASE_DIR/profile/${ACC}-*/job.log | grep -E 'Total wall|Step|Peaks'"
