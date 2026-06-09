#!/bin/bash
#
# prod-status.sh — one-shot health snapshot of the production downloaders +
# coordinators (SLURM jobs on kumamoto-c768) and their per-experiment jobs.
# Run on a SLURM submit host (a001 or any compute node).
#
# Per <genome>-<pipeline> group it shows the downloader and coordinator verdict:
#     RUNNING / PENDING   the SLURM job is in the queue
#     done                downloads-complete and the job is gone (normal finish)
#     DIED?               job gone but work NOT finished  <-- investigate / resubmit
# plus marker counts, the per-experiment job count, and a .fail-by-reason tally.
#
# Usage: prod-status.sh
#
set -uo pipefail
STAGEROOT=/home/okishinya/chipatlas-v2/staging
LOGROOT=$HOME/chip-atlas-v2

sq=$(squeue --me -h -o "%j|%T" 2>/dev/null || true)        # NAME|STATE per job
jobstate() { echo "$sq" | awk -F'|' -v n="$1" '$1==n{print $2; exit}'; }
cnt() { find "$1" -maxdepth 2 -name "$2" 2>/dev/null | wc -l; }

printf '%-16s %-9s %-9s %-9s %6s %6s %6s %6s %6s\n' \
  GROUP DOWNLOAD COORD COMPLETE done fail ready subm PXjobs
for ST in "$STAGEROOT"/*/; do
  grp=$(basename "$ST")
  case "$grp" in *-chipseq|*-bsseq) ;; *) continue ;; esac  # skip non-group dirs (e.g. proc-logs)
  genome=${grp%-*}; pipe=${grp##*-}
  rdy=$(cnt "$ST" .ready); subm=$(cnt "$ST" .submitted)
  done=$(cnt "$ST" .done); fail=$(cnt "$ST" .fail)
  comp=$([ -f "$ST/.downloads-complete" ] && echo yes || echo no)
  dls=$(jobstate "dl-${genome}-${pipe}"); cos=$(jobstate "proc-${genome}-${pipe}")
  if   [ -n "$dls" ]; then dlv="$dls"
  elif [ "$comp" = yes ]; then dlv=done; else dlv="DIED?"; fi
  if   [ -n "$cos" ]; then cov="$cos"
  elif [ "$comp" = yes ] && [ "$rdy" -eq 0 ] && [ "$subm" -eq 0 ]; then cov=done; else cov="DIED?"; fi
  px=$(echo "$sq" | grep -c "^px-${genome}-${pipe}-" || true)
  printf '%-16s %-9s %-9s %-9s %6s %6s %6s %6s %6s\n' \
    "$grp" "$dlv" "$cov" "$comp" "$done" "$fail" "$rdy" "$subm" "$px"
done

echo "--- .fail by reason (integer = download give-up count; word = processing) ---"
find "$STAGEROOT" -name .fail -exec cat {} + 2>/dev/null | sort | uniq -c | sed 's/^/  /' || true
echo "--- latest downloader log line per job ---"
for L in "$LOGROOT"/production-*/logs/dl-*.out; do
  [ -e "$L" ] || continue
  printf '  %s: ' "$(basename "$L")"; tail -n 1 "$L" 2>/dev/null
done
