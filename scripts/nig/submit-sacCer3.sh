#!/bin/bash
#
# Submit sacCer3 production runs to SLURM kumamoto partition.
# Uses job arrays — one task per sample.
#
set -eo pipefail

SCRIPTS_DIR=~/chip-atlas-v2/scripts
SAMPLE_DIR=~/chip-atlas-v2/sample-lists
OUTBASE=/home/okishinya/chipatlas-v2
LOG_DIR=~/chip-atlas-v2/production-sacCer3/logs
GENOME=sacCer3

# sacCer3 is small: 4 cores/job, all 128 cores → 32 concurrent
CPUS=4
# sacCer3 index is ~40 MB, so memory is not a concern
MEM="24g"
TIME="0-02:00:00"

mkdir -p "$LOG_DIR"

# ============================================================
# ChIP-seq: 20,648 experiments
# ============================================================
CHIP_LIST=$SAMPLE_DIR/chipseq-sacCer3.tsv
CHIP_N=$(wc -l < "$CHIP_LIST")

echo "=== sacCer3 ChIP-seq: $CHIP_N experiments ==="
echo "  Config: ${CPUS}c, ${MEM}, ${TIME}"
echo "  Output: $OUTBASE/$GENOME/{prefix}/{experiment}/"

CHIP_JOB=$(sbatch --parsable \
  -p kumamoto-c768 --account=kumamoto-group \
  --array=1-${CHIP_N}%32 \
  --cpus-per-task=$CPUS --mem=$MEM -t $TIME \
  -J "ca2-chip-${GENOME}" \
  -o "$LOG_DIR/chip-%A_%a.out" \
  -e "$LOG_DIR/chip-%A_%a.err" \
  --wrap="bash $SCRIPTS_DIR/run-sample.sh $CHIP_LIST \$SLURM_ARRAY_TASK_ID chipseq $GENOME $OUTBASE")

echo "  Submitted: job $CHIP_JOB (array 1-${CHIP_N}, 32 concurrent)"

# ============================================================
# BS-seq: 62 experiments
# ============================================================
BS_LIST=$SAMPLE_DIR/bsseq-sacCer3.tsv
BS_N=$(wc -l < "$BS_LIST")

echo ""
echo "=== sacCer3 BS-seq: $BS_N experiments ==="

BS_JOB=$(sbatch --parsable \
  -p kumamoto-c768 --account=kumamoto-group \
  --array=1-${BS_N}%32 \
  --cpus-per-task=$CPUS --mem=$MEM -t $TIME \
  -J "ca2-bs-${GENOME}" \
  -o "$LOG_DIR/bs-%A_%a.out" \
  -e "$LOG_DIR/bs-%A_%a.err" \
  --wrap="bash $SCRIPTS_DIR/run-sample.sh $BS_LIST \$SLURM_ARRAY_TASK_ID bsseq $GENOME $OUTBASE")

echo "  Submitted: job $BS_JOB (array 1-${BS_N}, 32 concurrent)"

echo ""
echo "=== Queue ==="
squeue -u $USER -l | head -20
