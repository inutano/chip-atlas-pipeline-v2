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

# Downloader + coordinator run as SLURM jobs on kumamoto-c768, NOT on the a001-a003
# login partition. They're cgroup-capped, so the SRA fasterq-dump fallback (real
# compute + scratch) runs safely on a compute node. We tried the login partition
# (2026-06-09) and the fallback ran heavy fasterq-dump writing to /tmp ON a001 —
# unsafe on a shared login node — so we reverted. A 2-core downloader slot is
# negligible; protecting the shared nodes wins. The per-experiment pipeline jobs are
# separate sbatch'd jobs the coordinator submits.

# Downloader: 2 cores, long-running.
DL_JOB=$(sbatch --parsable \
  -p kumamoto-c768 --account=kumamoto-group \
  -n 2 --mem=4g -t 2-00:00:00 \
  -J "dl-${GENOME}-${PIPELINE}" \
  -o "$LOG_DIR/dl-${PIPELINE}-%j.out" \
  -e "$LOG_DIR/dl-${PIPELINE}-%j.err" \
  --wrap="bash $SCRIPTS/production-download.sh $SAMPLE_LIST $STAGING $DL_CONCURRENT $DL_BUFFER")
echo "  Download job: $DL_JOB"

# Coordinator: tiny (1 core / 2 GB — only sbatches + polls). Starts 1 min after the
# downloader. EXCLUDE_NODES is passed through to the per-experiment jobs.
PROC_JOB=$(sbatch --parsable \
  -p kumamoto-c768 --account=kumamoto-group \
  -n 1 --mem=2g -t 2-00:00:00 \
  -J "proc-${GENOME}-${PIPELINE}" \
  -o "$LOG_DIR/proc-${PIPELINE}-%j.out" \
  -e "$LOG_DIR/proc-${PIPELINE}-%j.err" \
  --dependency=after:${DL_JOB}+1 \
  --export="ALL,EXCLUDE_NODES=${EXCLUDE_NODES}" \
  --wrap="bash $SCRIPTS/production-process.sh $STAGING $PIPELINE $GENOME $OUTBASE $PROC_MAX_INFLIGHT $PROC_INTERVAL")
echo "  Process job:  $PROC_JOB (starts 1 min after download begins)"
echo ""
echo "  Monitor: bash $SCRIPTS/prod-status.sh   (or: squeue --me; tail $LOG_DIR/{dl,proc}-${PIPELINE}-*.out)"
