#!/bin/bash
#
# bench-experiment.sh — measure peak NON-RECLAIMABLE memory for one staged
# experiment. Runs the pipeline at the given cores while a background poller
# samples the job cgroup's memory.stat every 2s, tracking peak `anon` (heap/stack/
# index buffers — the real OOM floor under a cgroup cap), peak total
# memory.current (incl. reclaimable page cache — the OLD inflated metric, kept
# only for contrast), and peak swap. At the end it also reads memory.events
# oom_kill so a confirmation round can detect a cap that was too tight.
#
# Why anon, not memory.peak: under a --mem cgroup cap the kernel evicts page
# cache before OOM-killing, so only non-reclaimable (anon, swap off) memory
# forces an OOM. memory.peak counts cache too -> inflated 1.5-2x under a generous
# cap. See docs/memory-benchmark.md.
#
# Result row (BYTES for memory fields):
#   exp genome pipeline cpus peak_anon peak_current peak_swap oom_kill wall_s rc
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
if [ -z "$fwd" ]; then printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\t0\tNOFASTQ\n' "$EXP" "$GENOME" "$PIPELINE" "$CPUS" > "$RESULTDIR/$EXP.result"; exit 1; fi

work=/data1/tmp/bench-${EXP}_$$; mkdir -p "$work"
bind="--bind /data1/tmp:/data1/tmp --bind $OUTBASE:$OUTBASE --bind $REF:$REF --bind $STAGING:$STAGING"

# --- cgroup poller: track peak non-reclaimable (anon), total, swap ------------
# This shell and the apptainer-exec children share the SLURM task cgroup (v2,
# hierarchical stats), so polling our own cgroup captures the whole pipeline.
cg=$(sed -n 's/^0:://p' /proc/self/cgroup | head -1)
CGDIR="/sys/fs/cgroup${cg}"
PA="$work/peak_anon"; PC="$work/peak_cur"; PS="$work/peak_swap"
printf 0 > "$PA"; printf 0 > "$PC"; printf 0 > "$PS"
(
  while :; do
    a=$(awk '/^anon /{print $2; exit}' "$CGDIR/memory.stat" 2>/dev/null); a=${a:-0}
    c=$(cat "$CGDIR/memory.current" 2>/dev/null); c=${c:-0}
    s=$(cat "$CGDIR/memory.swap.current" 2>/dev/null); s=${s:-0}
    [ "$a" -gt "$(cat "$PA")" ] 2>/dev/null && printf '%s' "$a" > "$PA"
    [ "$c" -gt "$(cat "$PC")" ] 2>/dev/null && printf '%s' "$c" > "$PC"
    [ "$s" -gt "$(cat "$PS")" ] 2>/dev/null && printf '%s' "$s" > "$PS"
    sleep 2
  done
) &
POLLER=$!

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
kill "$POLLER" 2>/dev/null; wait "$POLLER" 2>/dev/null
peak_anon=$(cat "$PA" 2>/dev/null || echo 0)
peak_cur=$(cat "$PC" 2>/dev/null || echo 0)
peak_swap=$(cat "$PS" 2>/dev/null || echo 0)
oom=$(awk '/^oom_kill /{print $2; exit}' "$CGDIR/memory.events" 2>/dev/null); oom=${oom:-0}
tail -3 "$work/log" > "$RESULTDIR/$EXP.tail" 2>/dev/null || true
rm -rf "$work"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$EXP" "$GENOME" "$PIPELINE" "$CPUS" "$peak_anon" "$peak_cur" "$peak_swap" "$oom" "$((t1-t0))" "$rc" \
  > "$RESULTDIR/$EXP.result"
