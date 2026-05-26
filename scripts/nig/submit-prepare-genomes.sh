#!/bin/bash
#
# Submit one SLURM job per genome to build references on NIG (flat layout).
#
# Usage:
#   bash submit-prepare-genomes.sh <genome> [genome ...]
#
# Each genome runs on an exclusive kumamoto-c768 node — bwa-mem2 index for
# mammalian genomes needs ~80 GB RAM during build, so don't squeeze.
#
set -eo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <genome> [genome ...]"
  echo "  Known: hg38 mm10 rn6 dm6 ce11 sacCer3 TAIR10"
  exit 1
fi

SCRIPTS="${SCRIPTS:-$HOME/chip-atlas-v2/scripts}"
LOG_DIR="${LOG_DIR:-$HOME/chip-atlas-v2/prepare-logs}"
mkdir -p "$LOG_DIR"

for GENOME in "$@"; do
  JOB_ID=$(sbatch --parsable \
    -p kumamoto-c768 --account=kumamoto-group \
    --exclusive --mem=0 -t 0-04:00:00 \
    -J "prep-${GENOME}" \
    -o "$LOG_DIR/prep-${GENOME}-%j.out" \
    -e "$LOG_DIR/prep-${GENOME}-%j.err" \
    --wrap="bash $SCRIPTS/prepare-genome.sh $GENOME")
  echo "  $GENOME → job $JOB_ID  (log: $LOG_DIR/prep-${GENOME}-${JOB_ID}.out)"
done
