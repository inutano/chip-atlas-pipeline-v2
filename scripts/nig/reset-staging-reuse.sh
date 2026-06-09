#!/bin/bash
#
# reset-staging-reuse.sh <staging_dir> — re-queue a staging dir for a fresh
# processing pass while REUSING already-downloaded FASTQ. Clears stale terminal
# markers (.done/.fail/.running/.submitted/.attempts) and the .downloads-complete
# signal; sets .ready on any experiment that still has staged FASTQ (so the
# downloader skips re-download and the coordinator reprocesses it). Experiments
# without FASTQ are left bare for the downloader to re-fetch.
#
# Use when a prior run left a dirty staging dir but its FASTQ are worth keeping.
#
# Usage: reset-staging-reuse.sh <staging_dir>
#
set -uo pipefail
ST="${1:?usage: reset-staging-reuse.sh <staging_dir>}"
[ -d "$ST" ] || { echo "no such staging dir: $ST" >&2; exit 1; }

rm -f "$ST/.downloads-complete"
total=0; requeued=0; refetch=0
for d in "$ST"/*/; do
  [ -d "$d" ] || continue
  total=$((total + 1))
  rm -f "$d/.fail" "$d/.done" "$d/.running" "$d/.submitted" "$d/.attempts"
  if ls "$d"/*.fastq.gz >/dev/null 2>&1; then
    touch "$d/.ready"; requeued=$((requeued + 1))
  else
    refetch=$((refetch + 1))
  fi
done
echo "reset $ST"
echo "  $total dirs: $requeued re-queued (staged FASTQ reused) + $refetch need re-download"
