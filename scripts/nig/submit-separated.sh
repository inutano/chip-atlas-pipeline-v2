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
DL_CONCURRENT=6
DL_BUFFER=100
PROC_CPUS=4
PROC_MEM="24g"
PROC_TIME="0-02:00:00"
PROC_CONCURRENT=32
PROC_INTERVAL=30

N=$(wc -l < "$SAMPLE_LIST")

mkdir -p "$STAGING" "$LOG_DIR"

echo "=== Separated production: $GENOME $PIPELINE ==="
echo "  Samples: $N"
echo "  Staging: $STAGING"
echo "  Output:  $OUTBASE/$GENOME/{prefix}/{experiment}/"
echo "  Download: $DL_CONCURRENT concurrent, buffer $DL_BUFFER"
echo "  Process:  ${PROC_CPUS}c, ${PROC_MEM}, ${PROC_CONCURRENT} concurrent"
echo ""

# Submit downloader (1 core, long-running)
DL_JOB=$(sbatch --parsable \
  -p kumamoto-c768 --account=kumamoto-group \
  -n 2 --mem=4g -t 2-00:00:00 \
  -J "dl-${GENOME}-${PIPELINE}" \
  -o "$LOG_DIR/dl-${PIPELINE}-%j.out" \
  -e "$LOG_DIR/dl-${PIPELINE}-%j.err" \
  --wrap="bash $SCRIPTS/production-download.sh $SAMPLE_LIST $STAGING $DL_CONCURRENT $DL_BUFFER")

echo "  Download job: $DL_JOB"

# Submit processor (exclusive node, starts after downloader has had 60s head start)
PROC_JOB=$(sbatch --parsable \
  -p kumamoto-c768 --account=kumamoto-group \
  --exclusive --mem=0 -t 2-00:00:00 \
  -J "proc-${GENOME}-${PIPELINE}" \
  -o "$LOG_DIR/proc-${PIPELINE}-%j.out" \
  -e "$LOG_DIR/proc-${PIPELINE}-%j.err" \
  --dependency=after:${DL_JOB}+1 \
  --wrap="bash $SCRIPTS/production-process.sh $STAGING $PIPELINE $GENOME $OUTBASE $PROC_CPUS $PROC_MEM $PROC_TIME $PROC_CONCURRENT $PROC_INTERVAL")

echo "  Process job:  $PROC_JOB (starts 1 min after download begins)"
echo ""
echo "  Monitor: tail -f $LOG_DIR/dl-${PIPELINE}-${DL_JOB}.out"
echo "           tail -f $LOG_DIR/proc-${PIPELINE}-${PROC_JOB}.out"
