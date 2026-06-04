#!/bin/bash
#
# bench-experiment.sh — measure peak RSS for one staged experiment. Runs the
# pipeline at the given cores, then records the job cgroup's memory.peak (the
# exact kernel-tracked peak of all processes), wall time, and exit code.
# Submitted by bench-run.sh with a generous --mem ceiling (never the constraint).
#
# Usage: bench-experiment.sh <staging> <exp> <pipeline> <genome> <outbase> <cpus> <resultdir>
#
set -uo pipefail
STAGING="$1"; EXP="$2"; PIPELINE="$3"; GENOME="$4"; OUTBASE="$5"; CPUS="$6"; RESULTDIR="$7"
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
REF=$SHARED/references
declare -A GS=([sacCer3]=12157105 [ce11]=100286401 [dm6]=142573017 [rn6]=2870184193 [mm10]=2652783500 [hg38]=2913022398 [TAIR10]=119146348)

staging="$STAGING/$EXP"
outdir="$OUTBASE/$GENOME/$EXP"; mkdir -p "$outdir"
fwd=$(ls "$staging/${EXP}_1.fastq.gz" 2>/dev/null || ls "$staging/${EXP}.fastq.gz" 2>/dev/null || true)
rev=$(ls "$staging/${EXP}_2.fastq.gz" 2>/dev/null || true); rev_arg=""; [ -n "$rev" ] && rev_arg="--fastq-rev $rev"
mkdir -p "$RESULTDIR"
if [ -z "$fwd" ]; then printf '%s\t%s\t%s\t%s\t0\t0\tNOFASTQ\n' "$EXP" "$GENOME" "$PIPELINE" "$CPUS" > "$RESULTDIR/$EXP.result"; exit 1; fi

work=/data1/tmp/bench-${EXP}_$$; mkdir -p "$work"
bind="--bind /data1/tmp:/data1/tmp --bind $OUTBASE:$OUTBASE --bind $REF:$REF --bind $STAGING:$STAGING"
t0=$(date +%s); rc=0
if [ "$PIPELINE" = chipseq ]; then
  TMPDIR=$work apptainer exec $bind "$SHARED/containers/pipeline-v2.sif" \
    bash "$SCRIPTS_DIR/pipeline-v2.sh" --sample-id "$EXP" --fastq-fwd "$fwd" $rev_arg \
    --genome-fasta "$REF/$GENOME.fa" --chrom-sizes "$REF/$GENOME.chrom.sizes" \
    --genome-size "${GS[$GENOME]}" --outdir "$outdir" --threads "$CPUS" >"$work/log" 2>&1 || rc=$?
else
  TMPDIR=$work apptainer exec $bind "$SHARED/containers/pipeline-v2-bs.sif" \
    bash "$SCRIPTS_DIR/pipeline-v2-bs.sh" --sample-id "$EXP" --fastq-fwd "$fwd" $rev_arg \
    --genome-fasta "$REF/$GENOME.fa" --abismal-index "$REF/$GENOME.abismal.idx" \
    --chrom-sizes "$REF/$GENOME.chrom.sizes" --genome "$GENOME" --outdir "$outdir" --threads "$CPUS" >"$work/log" 2>&1 || rc=$?
fi
t1=$(date +%s)
cg=$(sed -n 's/^0:://p' /proc/self/cgroup | head -1)
peak=$(cat "/sys/fs/cgroup${cg}/memory.peak" 2>/dev/null || cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0)
tail -3 "$work/log" > "$RESULTDIR/$EXP.tail" 2>/dev/null || true
rm -rf "$work"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$EXP" "$GENOME" "$PIPELINE" "$CPUS" "$peak" "$((t1-t0))" "$rc" > "$RESULTDIR/$EXP.result"
