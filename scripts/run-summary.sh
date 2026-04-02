#!/bin/bash
#
# Generate a per-sample run summary from cwltool log + fastp JSON.
#
# Usage:
#   bash run-summary.sh <cwltool.log> [fastp.json]
#   bash run-summary.sh --batch <results_dir>   # summarize all samples
#
# Output: TSV to stdout with one row per sample (batch) or detailed
# per-step report (single sample).
#
set -eo pipefail

# ============================================================
# Single-sample summary
# ============================================================
summarize_one() {
  local LOG="$1"
  local FASTP_JSON="$2"
  local SAMPLE_ID=""

  if [ ! -f "$LOG" ]; then
    echo "ERROR: Log not found: $LOG" >&2
    return 1
  fi

  # Strip ANSI color codes for reliable parsing
  CLEAN=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG")

  # --- Per-step status ---
  echo "=== Step Summary ==="
  echo "$CLEAN" | grep -E '\[step [a-z_]+\] completed' | \
    sed 's/.*\[step \([a-z_]*\)\] completed \(.*\)/  \1: \2/'

  # --- Per-step memory ---
  echo ""
  echo "=== Memory Usage ==="
  echo "$CLEAN" | grep 'Max memory used' | \
    sed 's/.*\[job \([a-z_0-9]*\)\] Max memory used: \(.*\)/  \1: \2/'

  # --- Overall status ---
  echo ""
  FINAL=$(echo "$CLEAN" | grep 'Final process status' | sed 's/.*Final process status is //')
  echo "=== Result: ${FINAL:-unknown} ==="

  # --- Failure details ---
  ERRORS=$(echo "$CLEAN" | grep -E 'exited with status:|ERROR|AssertionError|Exception' | head -5)
  if [ -n "$ERRORS" ]; then
    echo ""
    echo "=== Errors ==="
    echo "$ERRORS" | sed 's/^/  /'
  fi

  # --- fastp stats ---
  if [ -n "$FASTP_JSON" ] && [ -f "$FASTP_JSON" ]; then
    echo ""
    echo "=== fastp QC ==="
    python3 -c "
import json, sys
with open('$FASTP_JSON') as f:
    d = json.load(f)
s = d.get('summary', {})
bf = s.get('before_filtering', {})
af = s.get('after_filtering', {})
filt = d.get('filtering_result', {})
print(f'  reads_before:  {bf.get(\"total_reads\", \"?\"):>12,}')
print(f'  reads_after:   {af.get(\"total_reads\", \"?\"):>12,}')
print(f'  q30_rate:      {af.get(\"q30_rate\", 0)*100:>11.1f}%')
passed = filt.get('passed_filter_reads', 0)
total = bf.get('total_reads', 1)
print(f'  pass_rate:     {passed/total*100:>11.1f}%')
dup = d.get('duplication', {}).get('rate', 0)
print(f'  dup_rate:      {dup*100:>11.1f}%')
" 2>/dev/null || echo "  (could not parse fastp JSON)"
  fi

  # --- Peak counts ---
  local OUTDIR
  OUTDIR=$(dirname "$LOG")
  local HAS_PEAKS=0
  for q in 05 10 20; do
    local PEAKS
    PEAKS=$(ls "$OUTDIR"/*."${q}_peaks.narrowPeak" 2>/dev/null | head -1)
    if [ -n "$PEAKS" ] && [ -f "$PEAKS" ]; then
      local COUNT
      COUNT=$(wc -l < "$PEAKS")
      if [ "$HAS_PEAKS" -eq 0 ]; then
        echo ""
        echo "=== Peak Counts ==="
        HAS_PEAKS=1
      fi
      echo "  q1e-${q}: ${COUNT}"
    fi
  done
}

# ============================================================
# Batch summary (TSV)
# ============================================================
summarize_batch() {
  local RESULTS_DIR="$1"
  set +e  # batch must tolerate partial/incomplete data from running jobs

  printf "sample_id\tstatus\treads_before\treads_after\tpass_rate\tdup_rate\tpeaks_q05\tpeaks_q10\tpeaks_q20\tfailed_step\terror_message\n"

  for OUTDIR in "$RESULTS_DIR"/*/output; do
    local SAMPLE_ID
    SAMPLE_ID=$(basename "$(dirname "$OUTDIR")")
    local LOG="$OUTDIR/cwltool.log"

    if [ ! -f "$LOG" ]; then
      continue
    fi

    CLEAN=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG")

    # Status
    local STATUS
    STATUS=$(echo "$CLEAN" | grep 'Final process status' | sed 's/.*Final process status is //') || true
    STATUS="${STATUS:-running}"

    # fastp stats
    local READS_BEFORE="." READS_AFTER="." PASS_RATE="." DUP_RATE="."
    local FASTP_JSON
    FASTP_JSON=$(ls "$OUTDIR"/*_fastp.json 2>/dev/null | head -1)
    if [ -n "$FASTP_JSON" ] && [ -f "$FASTP_JSON" ]; then
      local PY_OUT
      PY_OUT=$(python3 -c "
import json
with open('$FASTP_JSON') as f:
    d = json.load(f)
s = d.get('summary', {})
bf = s.get('before_filtering', {})
af = s.get('after_filtering', {})
filt = d.get('filtering_result', {})
total = bf.get('total_reads', 1)
passed = filt.get('passed_filter_reads', 0)
dup = d.get('duplication', {}).get('rate', 0)
print(f'READS_BEFORE={bf.get(\"total_reads\", 0)}')
print(f'READS_AFTER={af.get(\"total_reads\", 0)}')
print(f'PASS_RATE={passed/total*100:.1f}')
print(f'DUP_RATE={dup*100:.1f}')
" 2>/dev/null) && eval "$PY_OUT" || true
    fi

    # Peak counts
    local Q05="." Q10="." Q20="."
    local F
    F=$(ls "$OUTDIR"/*.05_peaks.narrowPeak 2>/dev/null | head -1) || true
    [ -n "$F" ] && [ -f "$F" ] && Q05=$(wc -l < "$F")
    F=$(ls "$OUTDIR"/*.10_peaks.narrowPeak 2>/dev/null | head -1) || true
    [ -n "$F" ] && [ -f "$F" ] && Q10=$(wc -l < "$F")
    F=$(ls "$OUTDIR"/*.20_peaks.narrowPeak 2>/dev/null | head -1) || true
    [ -n "$F" ] && [ -f "$F" ] && Q20=$(wc -l < "$F")

    # Failed step and error
    local FAILED_STEP="." ERROR_MSG="."
    if [ "$STATUS" = "permanentFail" ]; then
      FAILED_STEP=$(echo "$CLEAN" | grep '\[step.*completed permanentFail' | head -1 | sed 's/.*\[step \([a-z_0-9]*\)\].*/\1/') || true
      ERROR_MSG=$(echo "$CLEAN" | grep -E 'AssertionError|Exception|ERROR.*Job error' | head -1 | sed 's/.*ERROR //' | cut -c1-80) || true
      ERROR_MSG="${ERROR_MSG:-.}"
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$SAMPLE_ID" "$STATUS" "$READS_BEFORE" "$READS_AFTER" "$PASS_RATE" "$DUP_RATE" \
      "$Q05" "$Q10" "$Q20" "$FAILED_STEP" "$ERROR_MSG"
  done
}

# ============================================================
# Main
# ============================================================
case "${1:-}" in
  --batch)
    RESULTS_DIR="${2:?Usage: $0 --batch <results_dir>}"
    summarize_batch "$RESULTS_DIR"
    ;;
  --help|-h)
    echo "Usage:"
    echo "  $0 <cwltool.log> [fastp.json]   Single-sample detailed report"
    echo "  $0 --batch <results_dir>         Batch TSV summary"
    ;;
  *)
    LOG="${1:?Usage: $0 <cwltool.log> [fastp.json]}"
    FASTP_JSON="${2:-}"
    # Auto-detect fastp JSON in same directory
    if [ -z "$FASTP_JSON" ]; then
      FASTP_JSON=$(ls "$(dirname "$LOG")"/*_fastp.json 2>/dev/null | head -1)
    fi
    summarize_one "$LOG" "$FASTP_JSON"
    ;;
esac
