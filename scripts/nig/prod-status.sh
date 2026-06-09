#!/bin/bash
#
# prod-status.sh — one-shot health snapshot of the login-node (a001) production
# downloaders + coordinators and their per-experiment SLURM jobs. Run on a001.
#
# The downloader and coordinator run as `nohup` processes on a001 (the `login`
# SLURM partition is INACTIVE, so they can't be sbatch'd), so there's no `squeue`
# row for them. We instead check process liveness + the on-disk markers. The key
# per-group verdict:
#     RUNNING  process is alive
#     done     process gone AND work finished (downloads-complete, nothing left)
#     DIED?    process gone but work NOT finished  <-- investigate / restart
#
# Usage: prod-status.sh        (snapshots every <genome>-<pipeline> staging dir)
#
set -uo pipefail
STAGEROOT=/home/okishinya/chipatlas-v2/staging
LOGROOT=$HOME/chip-atlas-v2

# One ps snapshot, taken BEFORE any grep, so the greps that read it can't self-match.
snap=$(ps -ww -u "$(whoami)" -o pid=,etime=,args= 2>/dev/null)
sq=$(squeue --me -h -o "%j" 2>/dev/null || true)

pid_of() { echo "$snap" | grep -F "$1" | grep -F "$2" | awk '{print $1}' | head -1; }
cnt()    { find "$1" -maxdepth 2 -name "$2" 2>/dev/null | wc -l; }

printf '%-16s %-8s %-8s %-9s %6s %6s %6s %6s %6s\n' \
  GROUP DOWNLOAD COORD COMPLETE done fail ready subm PXjobs
for ST in "$STAGEROOT"/*/; do
  [ -d "$ST" ] || continue
  grp=$(basename "$ST"); genome=${grp%-*}; pipe=${grp##*-}
  rdy=$(cnt "$ST" .ready); subm=$(cnt "$ST" .submitted)
  done=$(cnt "$ST" .done); fail=$(cnt "$ST" .fail)
  comp=$([ -f "$ST/.downloads-complete" ] && echo yes || echo no)
  dlp=$(pid_of production-download.sh "staging/$grp")
  cop=$(pid_of production-process.sh  "staging/$grp")
  if   [ -n "$dlp" ]; then dlv=RUNNING
  elif [ "$comp" = yes ]; then dlv=done; else dlv="DIED?"; fi
  if   [ -n "$cop" ]; then cov=RUNNING
  elif [ "$comp" = yes ] && [ "$rdy" -eq 0 ] && [ "$subm" -eq 0 ]; then cov=done; else cov="DIED?"; fi
  px=$(echo "$sq" | grep -c "px-${genome}-${pipe}-" || true)
  printf '%-16s %-8s %-8s %-9s %6s %6s %6s %6s %6s\n' \
    "$grp" "$dlv" "$cov" "$comp" "$done" "$fail" "$rdy" "$subm" "$px"
done

echo "--- .fail by reason ---"
find "$STAGEROOT" -name .fail -exec cat {} + 2>/dev/null | sort | uniq -c | sed 's/^/  /' || true
echo "--- latest downloader log line per group ---"
for L in "$LOGROOT"/production-*/logs/dl-*.log; do
  [ -e "$L" ] || continue
  printf '  %s: ' "$(basename "$L")"; tail -n 1 "$L" 2>/dev/null
done
