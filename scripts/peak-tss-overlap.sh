#!/bin/bash
#
# Compute peak-TSS overlaps for a single experiment.
# Uses bedtools window at ±1kb, ±5kb, ±10kb.
#
# Usage:
#   peak-tss-overlap.sh <peaks.narrowPeak> <genes_tss.bed> <experiment_id> <output.tsv>
#
set -eo pipefail

PEAKS="$1"
TSS="$2"
EXP_ID="$3"
OUTPUT="$4"

if [ -z "$PEAKS" ] || [ -z "$TSS" ] || [ -z "$EXP_ID" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $0 <peaks.narrowPeak> <genes_tss.bed> <experiment_id> <output.tsv>"
  exit 1
fi

# Header
echo -e "experiment_id\tpeak_chrom\tpeak_start\tpeak_end\tpeak_score\tgene_symbol\ttss_distance\twindow_kb" > "$OUTPUT"

for WINDOW in 1000 5000 10000; do
  KB=$((WINDOW / 1000))
  bedtools window -a "$PEAKS" -b "$TSS" -w "$WINDOW" 2>/dev/null | \
    awk -v exp="$EXP_ID" -v kb="$KB" 'BEGIN{OFS="\t"} {
      # narrowPeak: chrom(1) start(2) end(3) name(4) score(5) ... | TSS: chrom start end gene
      peak_mid = int(($2 + $3) / 2)
      tss_pos = $(NF-2)
      distance = peak_mid - tss_pos
      print exp, $1, $2, $3, $5, $NF, distance, kb
    }' >> "$OUTPUT"
done

LINES=$(($(wc -l < "$OUTPUT") - 1))
echo "Generated $LINES overlaps for $EXP_ID"
