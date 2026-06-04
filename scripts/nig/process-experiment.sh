#!/bin/bash
#
# process-experiment.sh — the per-experiment SLURM job body. Runs the pipeline on
# one already-staged experiment, then transitions its staging-dir markers.
#
# The processor (production-process.sh) submits one of these per ready experiment
# with cgroup-enforced --cpus-per-task/--mem (from job-settings.sh), and writes a
# `.submitted` marker (containing this job's id) before sbatch. This job clears
# `.submitted` and writes the terminal marker on exit.
#
# Usage: process-experiment.sh <staging_dir> <exp_acc> <pipeline> <genome> <outbase> <cpus>
#
set -eo pipefail

STAGING_DIR="$1"; EXP_ACC="$2"; PIPELINE="$3"; GENOME="$4"; OUTBASE="$5"; CPUS="$6"

if [ -z "$EXP_ACC" ] || [ -z "$PIPELINE" ] || [ -z "$GENOME" ] || [ -z "$OUTBASE" ] || [ -z "$CPUS" ]; then
  echo "Usage: $0 <staging_dir> <exp_acc> <pipeline> <genome> <outbase> <cpus>" >&2
  exit 1
fi

export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared failure-classification + outcome helpers (flat on cluster; ../ in repo).
if [ -f "$SCRIPTS_DIR/failure-classify.sh" ]; then
  source "$SCRIPTS_DIR/failure-classify.sh"
else
  source "$SCRIPTS_DIR/../failure-classify.sh"
fi
MAX_RETRIES="${MAX_RETRIES:-2}"

# MACS3 effective genome size (error on unknown genome — never silently default).
declare -A MACS3_GSIZE=(
  [sacCer3]=12157105 [ce11]=100286401 [dm6]=142573017
  [rn6]=2870184193 [mm10]=2652783500 [hg38]=2913022398 [TAIR10]=119146348
)

SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
REF=$SHARED/references
CHIP_SIF=$SHARED/containers/pipeline-v2.sif
BS_SIF=$SHARED/containers/pipeline-v2-bs.sif

staging="$STAGING_DIR/$EXP_ACC"
prefix=${EXP_ACC:0:6}
outdir=$OUTBASE/$GENOME/$prefix/$EXP_ACC
mkdir -p "$outdir"

# Idempotent: if already processed, just mark done (handles re-submission /
# orphan-recovery double-runs). stats.tsv is the completion invariant.
if [ -f "$outdir/${EXP_ACC}.stats.tsv" ]; then
  echo "[SKIP] $EXP_ACC already has stats.tsv"
  rm -f "$staging/.submitted" "$staging/.running" "$staging"/*.fastq.gz "$staging"/*.fastq "$staging/.attempts" 2>/dev/null || true
  touch "$staging/.done"
  exit 0
fi

# Locate the staged FASTQ(s).
fwd=$(ls "$staging/${EXP_ACC}_1.fastq.gz" 2>/dev/null || ls "$staging/${EXP_ACC}.fastq.gz" 2>/dev/null || true)
rev=$(ls "$staging/${EXP_ACC}_2.fastq.gz" 2>/dev/null || true)
if [ -z "$fwd" ]; then
  echo "[FAIL] $EXP_ACC: no staged FASTQ in $staging"
  rm -f "$staging/.submitted"
  mv -f "$staging/.running" "$staging/.fail" 2>/dev/null || touch "$staging/.fail"
  exit 1
fi
rev_arg=""; [ -n "$rev" ] && rev_arg="--fastq-rev $rev"

work=/data1/tmp/${EXP_ACC}_$$
mkdir -p "$work"
bind_args="--bind /data1/tmp:/data1/tmp --bind $OUTBASE:$OUTBASE --bind $REF:$REF --bind $STAGING_DIR:$STAGING_DIR"
rc=0

if [ "$PIPELINE" = "chipseq" ]; then
  gsize="${MACS3_GSIZE[$GENOME]:-}"
  if [ -z "$gsize" ]; then echo "[FAIL] $EXP_ACC: no MACS3 gsize for genome $GENOME" >&2; rm -f "$staging/.submitted"; touch "$staging/.fail"; exit 1; fi
  TMPDIR=$work apptainer exec $bind_args "$CHIP_SIF" \
    bash "$SCRIPTS_DIR/pipeline-v2.sh" \
      --sample-id "$EXP_ACC" --fastq-fwd "$fwd" $rev_arg \
      --genome-fasta "$REF/${GENOME}.fa" --chrom-sizes "$REF/${GENOME}.chrom.sizes" \
      --genome-size "$gsize" --outdir "$outdir" --threads "$CPUS" || rc=$?
elif [ "$PIPELINE" = "bsseq" ]; then
  TMPDIR=$work apptainer exec $bind_args "$BS_SIF" \
    bash "$SCRIPTS_DIR/pipeline-v2-bs.sh" \
      --sample-id "$EXP_ACC" --fastq-fwd "$fwd" $rev_arg \
      --genome-fasta "$REF/${GENOME}.fa" --abismal-index "$REF/${GENOME}.abismal.idx" \
      --chrom-sizes "$REF/${GENOME}.chrom.sizes" --genome "$GENOME" \
      --outdir "$outdir" --threads "$CPUS" || rc=$?
else
  echo "[FAIL] $EXP_ACC: unknown pipeline $PIPELINE" >&2; rm -f "$staging/.submitted"; touch "$staging/.fail"; exit 1
fi

rm -rf "$work"

# Decide outcome (done / datafail / retry / infrafail) and transition markers.
stats_exists=0; [ -f "$outdir/${EXP_ACC}.stats.tsv" ] && stats_exists=1
attempts=$(read_attempts "$staging")
outcome=$(classify_outcome "$rc" "$stats_exists" "$attempts" "$MAX_RETRIES")
rm -f "$staging/.submitted"
apply_outcome "$staging" "$outcome"
echo "[${outcome^^}] $EXP_ACC (rc=$rc, attempt $attempts/$MAX_RETRIES)"
[ "$outcome" = "done" ]
