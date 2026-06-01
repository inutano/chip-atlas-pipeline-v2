#!/bin/bash
# Run ChIP-Atlas sample-selection queries against a QLever endpoint.
# Usage: bash scripts/run_chipatlas_selection.sh [endpoint] [outdir]

set -euo pipefail

ENDPOINT="${1:-http://localhost:7001}"
OUTDIR="${2:-./chipatlas-out}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$OUTDIR"

# Rewrite QLever's tsv_export into ChIP-Atlas metadata.tab style:
#   header  -> SRX, SAMN, TITLE, LIBRARY_STRATEGY, LIBRARY_SOURCE,
#              LIBRARY_SELECTION, INSTRUMENT_MODEL, Organism, SRP, PRJ
#   "..."   -> bare string (strip surrounding double quotes)
#   <IRI>   -> local name (segment after the last '/')
#   empty   -> kept empty
format_tsv() {
  awk -F'\t' -v OFS='\t' '
    NR == 1 {
      print "SRX","SAMN","TITLE","LIBRARY_STRATEGY","LIBRARY_SOURCE","LIBRARY_SELECTION","INSTRUMENT_MODEL","Organism","SRP","PRJ"
      next
    }
    {
      for (i = 1; i <= NF; i++) {
        v = $i
        n = length(v)
        if (n >= 2 && substr(v,1,1) == "\"" && substr(v,n,1) == "\"") {
          $i = substr(v, 2, n-2)
        } else if (n >= 2 && substr(v,1,1) == "<" && substr(v,n,1) == ">") {
          inner = substr(v, 2, n-2)
          k = split(inner, parts, "/")
          $i = parts[k]
        }
      }
      print
    }
  '
}

run_query() {
  local name="$1"
  local query_file="$2"
  local raw_file="$OUTDIR/${name}.raw.tsv"
  local out_file="$OUTDIR/${name}.tsv"
  echo "=== $name ==="
  local start
  start=$(date +%s%N)
  curl -s --max-time 1800 "$ENDPOINT" \
    --data-urlencode "query@${query_file}" \
    --data-urlencode 'action=tsv_export' \
    > "$raw_file"
  local end
  end=$(date +%s%N)
  local ms=$(( (end - start) / 1000000 ))
  if head -c 1 "$raw_file" | grep -q '{'; then
    echo "  ERROR: QLever returned JSON (likely an error). First 1KB:"
    head -c 1024 "$raw_file"
    echo
    return 1
  fi
  format_tsv < "$raw_file" > "$out_file"
  rm -f "$raw_file"
  local rows=$(( $(wc -l < "$out_file") - 1 ))
  echo "  $out_file: $rows rows in ${ms} ms"
}

echo "Endpoint: $ENDPOINT"
echo "Output:   $OUTDIR"
echo "Date:     $(date -u)"
echo

run_query "chipatlas_fast"  "$SCRIPT_DIR/chipatlas_select_fast.rq"
run_query "chipatlas_other" "$SCRIPT_DIR/chipatlas_select_other.rq"

echo
echo "=== Done ==="
