#!/usr/bin/env bash
#
# batch-status.sh — overall production progress, reconstructed from disk so it
# can never desync from a hand-maintained ledger. "done" = a sample's stats.tsv
# exists in the output tree (the pipeline's completion marker).
#
# Usage: batch-status.sh <batches_dir> <outbase>
#   batches_dir : dir containing manifest.tsv + <genome>-<pipeline>/batch-*.tsv
#   outbase     : production output root (e.g. /home/okishinya/chipatlas-v2)
#
set -euo pipefail

BATCHES_DIR="${1:?usage: batch-status.sh <batches_dir> <outbase>}"
OUTBASE="${2:?usage: batch-status.sh <batches_dir> <outbase>}"
MANIFEST="$BATCHES_DIR/manifest.tsv"
[ -f "$MANIFEST" ] || { echo "ERROR: no manifest at $MANIFEST" >&2; exit 1; }

DONE_SET="$(mktemp)"
trap 'rm -f "$DONE_SET"' EXIT

# All completed accessions across the output tree (accession = stats.tsv stem).
find "$OUTBASE" -name '*.stats.tsv' -printf '%f\n' 2>/dev/null \
  | sed 's/\.stats\.tsv$//' | sort -u > "$DONE_SET"

# Per batch, count its accessions present in the done set; aggregate by group.
while IFS=$'\t' read -r genome pipeline batch_id path n status; do
  bf="$BATCHES_DIR/$path"
  [ -f "$bf" ] || continue
  d=$(cut -f1 "$bf" | sort -u | comm -12 - "$DONE_SET" | wc -l)
  printf '%s-%s\t%s\t%s\n' "$genome" "$pipeline" "$n" "$d"
done < <(tail -n +2 "$MANIFEST") \
| awk -F'\t' '
  { t[$1]+=$2; dn[$1]+=$3; GT+=$2; GD+=$3; if (!($1 in seen)) { seen[$1]=1; order[++k]=$1 } }
  END {
    printf "%-18s %10s %10s %8s\n", "group", "total", "done", "pct"
    for (i=1;i<=k;i++) { g=order[i];
      printf "%-18s %10d %10d %7.1f%%\n", g, t[g], dn[g], (t[g]>0)?100*dn[g]/t[g]:0 }
    printf "%-18s %10d %10d %7.1f%%\n", "ALL", GT, GD, (GT>0)?100*GD/GT:0
  }'
