#!/bin/bash
#
# Submit separated download + process jobs for a genome.
#
# Usage: submit-separated.sh <genome> <pipeline> <sample_list>
#
set -eo pipefail

GENOME="$1"
PIPELINE="$2"       # "chipseq" or "bsseq"
SAMPLE_LIST="$3"

if [ -z "$GENOME" ] || [ -z "$PIPELINE" ] || [ -z "$SAMPLE_LIST" ]; then
  echo "Usage: $0 <genome> <pipeline> <sample_list>"
  exit 1
fi

SCRIPTS=~/chip-atlas-v2/scripts
OUTBASE=/home/okishinya/chipatlas-v2
STAGING=/home/okishinya/chipatlas-v2/staging/${GENOME}-${PIPELINE}
LOG_DIR=~/chip-atlas-v2/production-${GENOME}/logs

# Config
# DL_CONCURRENT × aria2c connections-per-file (4, see fast-download.sh) = total
# simultaneous connections to ENA. Kept at 4×4=16; 6×8=48 got ENA to rate-limit
# the IP to a ~98% failure rate (2026-06-02).
DL_CONCURRENT=4
DL_BUFFER=100
# The processor is now a lightweight coordinator that sbatches ONE cgroup-capped
# job per experiment; per-job cores/mem/time come from scripts/job-settings.sh
# (keyed by pipeline+genome), NOT from here.
PROC_MAX_INFLIGHT=300   # max submitted-but-not-terminal per-experiment jobs
PROC_INTERVAL=30
EXCLUDE_NODES="${EXCLUDE_NODES:-}"   # comma-list of unhealthy nodes to avoid

N=$(wc -l < "$SAMPLE_LIST")

mkdir -p "$STAGING" "$LOG_DIR"

echo "=== Separated production: $GENOME $PIPELINE ==="
echo "  Samples: $N"
echo "  Staging: $STAGING"
echo "  Output:  $OUTBASE/$GENOME/{prefix}/{experiment}/"
echo "  Download: $DL_CONCURRENT concurrent, buffer $DL_BUFFER"
echo "  Process:  per-experiment sbatch (cores/mem from job-settings.sh), max in-flight ${PROC_MAX_INFLIGHT}"
echo ""

# Downloader + coordinator run as nohup processes on THIS login node (a001-a003),
# not on kumamoto: the `login` SLURM partition is INACTIVE so they can't be
# sbatch'd, and neither is heavy (downloader = aria2c/curl I/O; coordinator only
# sbatches + polls). The real work runs as cgroup-capped per-experiment jobs the
# coordinator submits to kumamoto-c768. They survive this SSH session (nohup) and
# self-exit when done. Monitor with scripts/prod-status.sh.
DL_LOG="$LOG_DIR/dl-${PIPELINE}.log"
PROC_LOG="$LOG_DIR/proc-${PIPELINE}.log"

# Clear any stale completion marker so the coordinator can't terminate on it before
# the downloader has produced work (we no longer have a SLURM dependency to gate it).
rm -f "$STAGING/.downloads-complete"

nohup bash "$SCRIPTS/production-download.sh" "$SAMPLE_LIST" "$STAGING" \
      "$DL_CONCURRENT" "$DL_BUFFER" > "$DL_LOG" 2>&1 &
DL_PID=$!
echo "  Downloader:  a001 login (nohup) PID $DL_PID  -> $DL_LOG"

sleep 60   # head start: let the downloader stage the first .ready before polling begins

nohup env EXCLUDE_NODES="$EXCLUDE_NODES" \
      bash "$SCRIPTS/production-process.sh" "$STAGING" "$PIPELINE" "$GENOME" \
      "$OUTBASE" "$PROC_MAX_INFLIGHT" "$PROC_INTERVAL" > "$PROC_LOG" 2>&1 &
PROC_PID=$!
echo "  Coordinator: a001 login (nohup) PID $PROC_PID  -> $PROC_LOG"
echo "  (per-experiment jobs run on kumamoto-c768; monitor: bash $SCRIPTS/prod-status.sh)"
