#!/bin/bash
#
# smoke-sacCer3.sh — end-to-end smoke test of the production path on sacCer3.
# Takes the first N experiments of the real chipseq + bsseq lists (so outputs are
# valid first-batch production) and runs the full download->stage->coordinate path
# for both pipelines. Validates: ENA(ERX)+DDBJ(DRX) routing, staging, the
# sbatch-per-experiment coordinator, both pipelines, marker transitions
# (.done / .fail tagged by reason), outputs, and clean termination.
#
# Usage: smoke-sacCer3.sh [N]    (default 15)
#
set -uo pipefail
N="${1:-15}"
BD=~/chip-atlas-v2; SL=$BD/sample-lists; SM=$SL/smoke
mkdir -p "$SM"
head -n "$N" "$SL/chipseq-sacCer3.tsv" > "$SM/chipseq-sacCer3-smoke.tsv"
head -n "$N" "$SL/bsseq-sacCer3.tsv"   > "$SM/bsseq-sacCer3-smoke.tsv"
echo "chip smoke: $(wc -l < "$SM/chipseq-sacCer3-smoke.tsv") exp | bs smoke: $(wc -l < "$SM/bsseq-sacCer3-smoke.tsv") exp"

export EXCLUDE_NODES=$(sinfo -N -p kumamoto-c768 -h -o "%n %t" 2>/dev/null \
  | awk '$2 ~ /down|drain|fail|drng|boot|unk/ {print $1}' | sort -u | paste -sd, -)
echo "exclude=[$EXCLUDE_NODES]"

echo "=== CHIPSEQ ==="
bash "$BD/scripts/submit-separated.sh" sacCer3 chipseq "$SM/chipseq-sacCer3-smoke.tsv"
echo "=== BSSEQ ==="
bash "$BD/scripts/submit-separated.sh" sacCer3 bsseq "$SM/bsseq-sacCer3-smoke.tsv"
