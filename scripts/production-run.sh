#!/bin/bash
#
# ChIP-Atlas v2: Production job management for 100K+ samples on NIG.
#
# Manages batched SLURM submission, per-job FASTQ lifecycle, disk quota
# awareness, progress tracking, and error recovery.
#
# Usage:
#   bash production-run.sh submit  <genome> <samples.tsv> [options]
#   bash production-run.sh status  <genome>
#   bash production-run.sh retry   <genome> [--max-retries N]
#   bash production-run.sh summary <genome>
#
# Sample TSV format (tab-separated, with header):
#   accession  genome  experiment_type  num_reads
#
# Options for submit:
#   --batch-size N       Jobs per submission wave (default: 90)
#   --max-concurrent N   Max SLURM jobs queued+running (default: 90)
#   --download-slots N   Max concurrent downloads per node (default: 6)
#   --threads N          CPUs per job (default: 8)
#   --disk-limit-gb N    Pause submission when Lustre usage exceeds this (default: 800)
#   --time-limit T       SLURM time limit per job (default: 0-03:00:00)
#   --mem M              Memory per job (default: 64g)
#   --dry-run            Print what would be submitted, don't submit
#
# Environment:
#   CHIP_ATLAS_BASE  Base directory (default: ~/chip-atlas-v2)
#   SLURM_PARTITION  SLURM partition (default: kumamoto-c768)
#   SLURM_ACCOUNT    SLURM account (default: kumamoto-group)
#
set -eo pipefail

# ============================================================
# Constants & defaults
# ============================================================
VERSION="1.0.0"

BASE_DIR="${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}"
REPO_DIR="$BASE_DIR/repo"
REF_DIR="$BASE_DIR/references"
SIF="$BASE_DIR/containers/pipeline-v2.sif"
DOWNLOAD_SCRIPT="$REPO_DIR/scripts/fast-download.sh"
PIPELINE_SCRIPT="$REPO_DIR/scripts/pipeline-v2.sh"

PARTITION="${SLURM_PARTITION:-kumamoto-c768}"
ACCOUNT="${SLURM_ACCOUNT:-kumamoto-group}"

BATCH_SIZE=90
MAX_CONCURRENT=90
DOWNLOAD_SLOTS=6
THREADS=8
DISK_LIMIT_GB=800
DRY_RUN=false
MAX_RETRIES=3
TIME_LIMIT="0-03:00:00"
MEM="64g"

declare -A GSIZE=( [hg38]=hs [mm10]=mm [rn6]=2.87e9 [dm6]=dm [ce11]=ce [sacCer3]=1.2e7 [TAIR10]=1.35e8 )

# ============================================================
# Logging
# ============================================================
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

# ============================================================
# Path helpers
# ============================================================
setup_paths() {
  local genome="$1"
  PROD_DIR="$BASE_DIR/production-${genome}"
  LOG_DIR="$PROD_DIR/logs"
  RESULT_DIR="$PROD_DIR/results"
  FASTQ_DIR="$PROD_DIR/fastq"
  STATUS_FILE="$PROD_DIR/status.tsv"
  SRX_SRR_MAP="$PROD_DIR/srx-srr-map.tsv"
  FA="$REF_DIR/${genome}.fa"
  GENOME_SIZE="${GSIZE[$genome]:?Unknown genome: $genome}"
}

# ============================================================
# Status file operations
#
# Append-only TSV. Multiple SLURM jobs write concurrently.
# The latest line per accession is the authoritative status.
#
# Columns:
#   1  accession       5  status          9   end_time       13 error
#   2  genome          6  slurm_job_id    10  download_sec   14 retry_count
#   3  experiment_type 7  submit_time     11  pipeline_sec
#   4  num_reads       8  start_time      12  total_sec
# ============================================================

init_status_file() {
  if [ ! -f "$STATUS_FILE" ]; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      accession genome experiment_type num_reads status slurm_job_id \
      submit_time start_time end_time download_sec pipeline_sec total_sec \
      error retry_count > "$STATUS_FILE"
  fi
}

set_status() {
  local acc="$1" genome="$2" exp_type="$3" num_reads="$4" status="$5"
  local job_id="${6:-}" submit_time="${7:-}" start_time="${8:-}" end_time="${9:-}"
  local dl_sec="${10:-}" pipe_sec="${11:-}" total_sec="${12:-}"
  local error="${13:-}" retry_count="${14:-0}"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$acc" "$genome" "$exp_type" "$num_reads" "$status" \
    "$job_id" "$submit_time" "$start_time" "$end_time" \
    "$dl_sec" "$pipe_sec" "$total_sec" "$error" "$retry_count" \
    >> "$STATUS_FILE"
}

# Deduplicate: print header + last occurrence of each accession
get_latest_statuses() {
  awk -F'\t' 'NR==1{print;next} {data[$1]=$0} END{for(k in data) print data[k]}' "$STATUS_FILE"
}

# ============================================================
# Disk usage
# ============================================================
get_disk_usage_gb() {
  local usage_kb
  usage_kb=$(lfs quota -u "$USER" "$BASE_DIR" 2>/dev/null \
    | awk '/\//{print $2}' | head -1 || true)
  if [ -n "$usage_kb" ] && [ "$usage_kb" -gt 0 ] 2>/dev/null; then
    echo $(( usage_kb / 1024 / 1024 ))
    return
  fi
  df -BG "$BASE_DIR" 2>/dev/null | awk 'NR==2{gsub(/G/,""); print $3}' || echo 0
}

check_disk_quota() {
  local usage_gb
  usage_gb=$(get_disk_usage_gb)
  if [ "$usage_gb" -ge "$DISK_LIMIT_GB" ] 2>/dev/null; then
    warn "Disk usage ${usage_gb}GB >= limit ${DISK_LIMIT_GB}GB"
    return 1
  fi
  return 0
}

# ============================================================
# SLURM helpers
# ============================================================
count_my_jobs() {
  squeue -u "$USER" -h -t PD,R -o "%j" 2>/dev/null \
    | grep -c "^ca2-" || echo 0
}

wait_for_job_slots() {
  local current
  while true; do
    current=$(count_my_jobs)
    if [ "$current" -lt "$MAX_CONCURRENT" ]; then
      return 0
    fi
    log "Job queue full: ${current}/${MAX_CONCURRENT} — waiting 60s..."
    sleep 60
  done
}

# ============================================================
# TogoID bulk SRX to SRR resolution
# ============================================================
resolve_srx_to_srr() {
  local samples_tsv="$1"

  if [ -f "$SRX_SRR_MAP" ] && [ -s "$SRX_SRR_MAP" ]; then
    local existing
    existing=$(wc -l < "$SRX_SRR_MAP")
    log "SRX-SRR map exists with $existing entries. Delete $SRX_SRR_MAP to re-resolve."
    return 0
  fi

  local all_accessions
  all_accessions=$(tail -n +2 "$samples_tsv" | cut -f1 | sort -u)
  local total
  total=$(echo "$all_accessions" | wc -l)
  log "Resolving $total SRX accessions via TogoID..."

  # TogoID URL length limit is ~8000 chars. SRX IDs are 14 chars each,
  # so 500 per request keeps us well under the limit.
  local chunk_size=500
  local offset=0
  > "$SRX_SRR_MAP"

  while true; do
    local chunk
    chunk=$(echo "$all_accessions" | tail -n +$((offset + 1)) | head -n "$chunk_size")
    [ -z "$chunk" ] && break

    local ids
    ids=$(echo "$chunk" | paste -sd,)
    local chunk_count
    chunk_count=$(echo "$chunk" | wc -l)

    log "  Batch at offset $offset ($chunk_count IDs)..."

    local attempt
    for attempt in 1 2 3; do
      if curl -sf --max-time 120 \
           "https://api.togoid.dbcls.jp/convert?ids=${ids}&route=sra_experiment,sra_run&report=pair" \
         | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pair in data['results']:
    print(pair[0] + '\t' + pair[1])
" >> "$SRX_SRR_MAP" 2>/dev/null; then
        break
      fi
      warn "TogoID attempt $attempt/3 failed, retrying in 10s..."
      sleep 10
    done

    offset=$((offset + chunk_size))
  done

  local resolved
  resolved=$(wc -l < "$SRX_SRR_MAP")
  log "Resolved $resolved / $total SRX-SRR pairs"

  if [ "$resolved" -lt "$total" ]; then
    comm -23 \
      <(echo "$all_accessions" | sort) \
      <(cut -f1 "$SRX_SRR_MAP" | sort) \
      > "$PROD_DIR/unresolved-accessions.txt"
    warn "$((total - resolved)) unresolved: $PROD_DIR/unresolved-accessions.txt"
  fi
}

# ============================================================
# Generate per-sample SLURM job script
#
# Each job is self-contained: download, process, record, cleanup.
# The script is written with placeholder tokens then filled via sed.
# ============================================================
generate_job_script() {
  local acc="$1" genome="$2" exp_type="$3" num_reads="$4" retry="${5:-0}"
  local work_dir="$RESULT_DIR/$acc"
  local out_dir="$work_dir/output"
  local job_script="$work_dir/run.sh"

  mkdir -p "$out_dir"

  # Write job template with __PLACEHOLDER__ tokens (single-quoted heredoc
  # prevents premature expansion of $variables in the template)
  cat > "$job_script" <<'JOBTPL'
#!/bin/bash
#SBATCH -p __PARTITION__
#SBATCH --account=__ACCOUNT__
#SBATCH --cpus-per-task=__THREADS__
#SBATCH --mem=__MEM__
#SBATCH -t __TIME_LIMIT__
#SBATCH -J ca2-__ACC__
#SBATCH -o __LOG_DIR__/__ACC__.log
#SBATCH -e __LOG_DIR__/__ACC__.err
set -o pipefail  # no -e: we handle errors explicitly for proper recording

export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

ACC="__ACC__"
GENOME="__GENOME__"
EXP_TYPE="__EXP_TYPE__"
NUM_READS="__NUM_READS__"
SIF="__SIF__"
FA="__FA__"
REF_DIR="__REF_DIR__"
GENOME_SIZE="__GENOME_SIZE__"
THREADS=__THREADS__
FASTQ_DIR="__FASTQ_DIR__"
OUT_DIR="__OUT_DIR__"
STATUS_FILE="__STATUS_FILE__"
DOWNLOAD_SCRIPT="__DOWNLOAD_SCRIPT__"
PIPELINE_SCRIPT="__PIPELINE_SCRIPT__"
SRX_SRR_MAP="__SRX_SRR_MAP__"
DOWNLOAD_SLOTS=__DOWNLOAD_SLOTS__
RETRY_COUNT=__RETRY_COUNT__

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Append status line (concurrent-safe: one printf = one write syscall)
record_status() {
  local status="$1" error="${2:-}"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$ACC" "$GENOME" "$EXP_TYPE" "$NUM_READS" "$status" \
    "${SLURM_JOB_ID:-}" "" "$JOB_START" "$(date -Iseconds)" \
    "${DL_SEC:-}" "${PIPE_SEC:-}" "${TOTAL_SEC:-}" \
    "$error" "$RETRY_COUNT" \
    >> "$STATUS_FILE"
}

# Download throttle: flock-based semaphore on node-local NVMe.
# Each node has DOWNLOAD_SLOTS lock files. A job tries each slot with
# non-blocking flock; if all are taken, it blocks on a random slot.
acquire_download_slot() {
  local lock_dir="/data1/.ca2-download-locks"
  mkdir -p "$lock_dir"
  # Try each slot non-blocking
  local i
  for i in $(seq 1 "$DOWNLOAD_SLOTS"); do
    DOWNLOAD_LOCK_FILE="$lock_dir/slot-${i}.lock"
    exec 9>"$DOWNLOAD_LOCK_FILE"
    if flock -n 9 2>/dev/null; then
      log "Download slot $i acquired"
      return 0
    fi
    exec 9>&-  # close FD if we didn't get the lock
  done
  # All slots busy — block on a random slot to spread contention
  local slot=$(( (RANDOM % DOWNLOAD_SLOTS) + 1 ))
  DOWNLOAD_LOCK_FILE="$lock_dir/slot-${slot}.lock"
  exec 9>"$DOWNLOAD_LOCK_FILE"
  log "All download slots busy, waiting on slot $slot..."
  flock 9
  log "Download slot $slot acquired (after wait)"
}

release_download_slot() {
  if [ -n "${DOWNLOAD_LOCK_FILE:-}" ]; then
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    DOWNLOAD_LOCK_FILE=""
  fi
}

# Cleanup handler: always release locks and remove NVMe scratch
cleanup() {
  release_download_slot
  rm -rf "${LOCAL_TMP:-}" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Main job execution
# ============================================================
JOB_START=$(date -Iseconds)
DL_SEC=""
PIPE_SEC=""
TOTAL_SEC=""
LOCAL_TMP=""

echo "============================================"
echo "ChIP-Atlas v2 Production: $ACC"
echo "Genome: $GENOME | Type: $EXP_TYPE | Reads: $NUM_READS"
echo "Node: $(hostname) | CPUs: $SLURM_CPUS_PER_TASK | Job: $SLURM_JOB_ID"
echo "Retry: $RETRY_COUNT | Start: $(date)"
echo "============================================"

record_status "running"

# --- Resolve SRR ---
log "Looking up SRR for $ACC..."
SRR=$(grep "^${ACC}	" "$SRX_SRR_MAP" | head -1 | cut -f2)
if [ -z "$SRR" ]; then
  log "ERROR: No SRR mapping for $ACC"
  record_status "failed" "no_srr_mapping"
  exit 1
fi
log "SRR: $SRR"

# --- Download FASTQ (throttled, with retry) ---
log "Downloading FASTQ..."
acquire_download_slot
DL_START=$(date +%s)

download_ok=false
for dl_attempt in 1 2 3; do
  if bash "$DOWNLOAD_SCRIPT" "$SRR" "$FASTQ_DIR" 2>&1; then
    download_ok=true
    break
  fi
  log "Download attempt $dl_attempt/3 failed, retrying in 30s..."
  # Remove partial files before retry
  rm -f "$FASTQ_DIR/${SRR}"*.fastq* 2>/dev/null || true
  sleep 30
done

release_download_slot

DL_END=$(date +%s)
DL_SEC=$((DL_END - DL_START))

if [ "$download_ok" = false ]; then
  log "ERROR: Download failed after 3 attempts for $SRR"
  record_status "failed" "download_failed"
  exit 1
fi
log "Download: ${DL_SEC}s"

# --- Locate FASTQ files ---
FWD=""
if [ -f "$FASTQ_DIR/${SRR}_1.fastq" ]; then
  FWD="$FASTQ_DIR/${SRR}_1.fastq"
elif [ -f "$FASTQ_DIR/${SRR}.fastq" ]; then
  FWD="$FASTQ_DIR/${SRR}.fastq"
else
  FWD=$(ls "$FASTQ_DIR/${SRR}"*.fastq 2>/dev/null | head -1 || true)
fi

if [ -z "$FWD" ] || [ ! -f "$FWD" ]; then
  log "ERROR: No FASTQ found for $SRR in $FASTQ_DIR"
  record_status "failed" "no_fastq_found"
  exit 1
fi

REV_ARG=""
if [ -f "$FASTQ_DIR/${SRR}_2.fastq" ]; then
  REV_ARG="--fastq-rev $FASTQ_DIR/${SRR}_2.fastq"
fi

log "FASTQ: $(basename "$FWD") $([ -n "$REV_ARG" ] && echo '(PE)' || echo '(SE)')"

# --- Pipeline ---
log "Running pipeline-v2.sh..."
LOCAL_TMP="/data1/ca2-${SLURM_JOB_ID}"
mkdir -p "$LOCAL_TMP"
export APPTAINER_TMPDIR="$LOCAL_TMP"

PIPE_START=$(date +%s)

pipe_rc=0
apptainer exec --bind "$LOCAL_TMP:/tmp" "$SIF" \
  bash "$PIPELINE_SCRIPT" \
    --sample-id "$ACC" \
    --fastq-fwd "$FWD" \
    $REV_ARG \
    --genome-fasta "$FA" \
    --chrom-sizes "$REF_DIR/chrom.sizes" \
    --genome-size "$GENOME_SIZE" \
    --outdir "$OUT_DIR" \
    --threads "$THREADS" \
  || pipe_rc=$?

PIPE_END=$(date +%s)
PIPE_SEC=$((PIPE_END - PIPE_START))
TOTAL_SEC=$((DL_SEC + PIPE_SEC))

log "Pipeline: ${PIPE_SEC}s | Download: ${DL_SEC}s | Total: ${TOTAL_SEC}s ($(( TOTAL_SEC/60 ))m)"

# --- Cleanup FASTQ + NVMe scratch ---
log "Cleaning up..."
rm -f "$FASTQ_DIR/${SRR}"*.fastq "$FASTQ_DIR/${SRR}"*.fastq.gz "$FASTQ_DIR/${SRR}"*.fastq.bz2
rm -rf "$LOCAL_TMP"
LOCAL_TMP=""  # prevent double-cleanup in trap

if [ $pipe_rc -ne 0 ]; then
  log "ERROR: Pipeline exited $pipe_rc"
  record_status "failed" "pipeline_exit_${pipe_rc}"
  exit 1
fi

# Verify BigWig was produced (minimum success criterion)
if [ ! -f "$OUT_DIR/${ACC}.bw" ]; then
  log "ERROR: No BigWig output"
  record_status "failed" "no_bigwig_output"
  exit 1
fi

record_status "done"
log "Done: $ACC"
JOBTPL

  # Fill placeholders with actual values
  sed -i \
    -e "s|__PARTITION__|${PARTITION}|g" \
    -e "s|__ACCOUNT__|${ACCOUNT}|g" \
    -e "s|__THREADS__|${THREADS}|g" \
    -e "s|__MEM__|${MEM}|g" \
    -e "s|__TIME_LIMIT__|${TIME_LIMIT}|g" \
    -e "s|__ACC__|${acc}|g" \
    -e "s|__GENOME__|${genome}|g" \
    -e "s|__EXP_TYPE__|${exp_type}|g" \
    -e "s|__NUM_READS__|${num_reads}|g" \
    -e "s|__LOG_DIR__|${LOG_DIR}|g" \
    -e "s|__SIF__|${SIF}|g" \
    -e "s|__FA__|${FA}|g" \
    -e "s|__REF_DIR__|${REF_DIR}|g" \
    -e "s|__GENOME_SIZE__|${GENOME_SIZE}|g" \
    -e "s|__FASTQ_DIR__|${FASTQ_DIR}|g" \
    -e "s|__OUT_DIR__|${out_dir}|g" \
    -e "s|__STATUS_FILE__|${STATUS_FILE}|g" \
    -e "s|__DOWNLOAD_SCRIPT__|${DOWNLOAD_SCRIPT}|g" \
    -e "s|__PIPELINE_SCRIPT__|${PIPELINE_SCRIPT}|g" \
    -e "s|__SRX_SRR_MAP__|${SRX_SRR_MAP}|g" \
    -e "s|__DOWNLOAD_SLOTS__|${DOWNLOAD_SLOTS}|g" \
    -e "s|__RETRY_COUNT__|${retry}|g" \
    "$job_script"

  echo "$job_script"
}

# ============================================================
# cmd_submit: Batched submission with progress tracking
# ============================================================
cmd_submit() {
  local genome="${1:?Usage: production-run.sh submit <genome> <samples.tsv> [options]}"
  local samples_tsv="${2:?Usage: production-run.sh submit <genome> <samples.tsv>}"
  shift 2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --batch-size)     BATCH_SIZE="$2"; shift 2 ;;
      --max-concurrent) MAX_CONCURRENT="$2"; shift 2 ;;
      --download-slots) DOWNLOAD_SLOTS="$2"; shift 2 ;;
      --threads)        THREADS="$2"; shift 2 ;;
      --disk-limit-gb)  DISK_LIMIT_GB="$2"; shift 2 ;;
      --time-limit)     TIME_LIMIT="$2"; shift 2 ;;
      --mem)            MEM="$2"; shift 2 ;;
      --dry-run)        DRY_RUN=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  setup_paths "$genome"

  log "========================================="
  log " ChIP-Atlas v2 Production Run"
  log "========================================="
  log "Genome:         $genome"
  log "Samples file:   $samples_tsv"
  log "Batch size:     $BATCH_SIZE"
  log "Max concurrent: $MAX_CONCURRENT"
  log "Download slots: $DOWNLOAD_SLOTS (per node)"
  log "Threads/job:    $THREADS"
  log "Time limit:     $TIME_LIMIT"
  log "Memory:         $MEM"
  log "Disk limit:     ${DISK_LIMIT_GB}GB"
  log "Dry run:        $DRY_RUN"
  log ""

  # ---- Pre-flight ----
  [ -f "$samples_tsv" ]          || die "Samples file not found: $samples_tsv"
  [ -f "$SIF" ]                  || die "Container SIF not found: $SIF"
  [ -f "$FA" ]                   || die "Reference not found: $FA"
  [ -f "$REF_DIR/chrom.sizes" ]  || die "chrom.sizes not found: $REF_DIR/chrom.sizes"
  [ -f "$DOWNLOAD_SCRIPT" ]      || die "Download script not found: $DOWNLOAD_SCRIPT"
  [ -f "$PIPELINE_SCRIPT" ]      || die "Pipeline script not found: $PIPELINE_SCRIPT"
  [ -f "${FA}.bwt.2bit.64" ]     || warn "bwa-mem2 index not found — jobs may fail"

  local header
  header=$(head -1 "$samples_tsv")
  echo "$header" | grep -q "accession" || die "TSV header must contain 'accession'"

  local total_samples
  total_samples=$(tail -n +2 "$samples_tsv" | wc -l)
  log "Samples in file: $total_samples"

  mkdir -p "$PROD_DIR" "$LOG_DIR" "$RESULT_DIR" "$FASTQ_DIR"
  init_status_file

  # ---- SRX to SRR resolution ----
  resolve_srx_to_srr "$samples_tsv"

  # ---- Disk check ----
  if ! check_disk_quota; then
    die "Disk usage exceeds limit. Free space first."
  fi

  # ---- Build submission list ----
  # Skip accessions that are done, submitted, or running
  local skip_set="$PROD_DIR/.skip-set.tmp"
  local to_submit="$PROD_DIR/.to-submit.tmp"
  get_latest_statuses \
    | awk -F'\t' 'NR>1 && ($5=="done" || $5=="submitted" || $5=="running") {print $1}' \
    | sort -u > "$skip_set"

  > "$to_submit"
  tail -n +2 "$samples_tsv" | while IFS=$'\t' read -r acc genome_col exp_type num_reads rest; do
    if grep -qx "$acc" "$skip_set" 2>/dev/null; then
      continue
    fi
    if ! grep -q "^${acc}	" "$SRX_SRR_MAP" 2>/dev/null; then
      continue  # no SRR mapping — already warned during resolution
    fi
    printf "%s\t%s\t%s\n" "$acc" "$exp_type" "$num_reads" >> "$to_submit"
  done

  local submit_count
  submit_count=$(wc -l < "$to_submit")
  log "To submit: $submit_count  (skipping $((total_samples - submit_count)))"

  if [ "$submit_count" -eq 0 ]; then
    log "Nothing to submit."
    rm -f "$skip_set" "$to_submit"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would submit $submit_count jobs. First 20:"
    head -20 "$to_submit" | while IFS=$'\t' read -r acc exp_type num_reads; do
      log "  $acc  $exp_type  $num_reads reads"
    done
    rm -f "$skip_set" "$to_submit"
    return 0
  fi

  # ---- Submit in waves ----
  local submitted=0
  local wave=1

  log ""
  log "=== Wave $wave ==="

  while IFS=$'\t' read -r acc exp_type num_reads; do
    # Wave boundary: check disk quota every BATCH_SIZE jobs
    if [ $((submitted % BATCH_SIZE)) -eq 0 ] && [ "$submitted" -gt 0 ]; then
      wave=$((wave + 1))
      log ""
      log "=== Wave $wave ($submitted/$submit_count submitted) ==="
      if ! check_disk_quota; then
        warn "Pausing: disk limit. Re-run to continue."
        break
      fi
    fi

    # Backpressure: wait if SLURM queue is full
    wait_for_job_slots

    local job_script
    job_script=$(generate_job_script "$acc" "$genome" "$exp_type" "$num_reads" "0")

    local sbatch_out
    sbatch_out=$(sbatch --account="$ACCOUNT" "$job_script" 2>&1)
    local job_id
    job_id=$(echo "$sbatch_out" | grep -oP '\d+' | tail -1)

    if [ -n "$job_id" ]; then
      set_status "$acc" "$genome" "$exp_type" "$num_reads" "submitted" "$job_id" "$(date -Iseconds)"
      submitted=$((submitted + 1))
      # Progress every 100 jobs, or every 10 in small runs
      local interval=$(( submit_count > 500 ? 100 : 10 ))
      if [ $((submitted % interval)) -eq 0 ]; then
        log "  Progress: $submitted/$submit_count  (latest: $acc job=$job_id)"
      fi
    else
      warn "sbatch failed for $acc: $sbatch_out"
      set_status "$acc" "$genome" "$exp_type" "$num_reads" "failed" "" "$(date -Iseconds)" "" "" "" "" "" "sbatch_failed" "0"
    fi
  done < "$to_submit"

  rm -f "$skip_set" "$to_submit"

  log ""
  log "========================================="
  log " Submission complete: $submitted jobs"
  log "========================================="
  log "Status:   bash $0 status $genome"
  log "Retry:    bash $0 retry $genome"
  log "Queue:    squeue -u \$USER | grep ca2-"
  log "========================================="
}

# ============================================================
# cmd_status: Progress dashboard
# ============================================================
cmd_status() {
  local genome="${1:?Usage: production-run.sh status <genome>}"
  setup_paths "$genome"

  [ -f "$STATUS_FILE" ] || die "No status file: $STATUS_FILE"

  local latest
  latest=$(get_latest_statuses)

  local total done failed submitted running pending
  total=$(echo "$latest" | tail -n +2 | wc -l)
  done=$(echo "$latest"  | awk -F'\t' '$5=="done"'      | wc -l)
  failed=$(echo "$latest"  | awk -F'\t' '$5=="failed"'    | wc -l)
  submitted=$(echo "$latest" | awk -F'\t' '$5=="submitted"' | wc -l)
  running=$(echo "$latest"  | awk -F'\t' '$5=="running"'   | wc -l)
  pending=$(echo "$latest"  | awk -F'\t' '$5=="pending"'   | wc -l)

  local avg_total avg_dl avg_pipe
  avg_total=$(echo "$latest" | awk -F'\t' '$5=="done" && $12+0>0 {s+=$12;n++} END{if(n) printf "%.0f",s/n; else print "N/A"}')
  avg_dl=$(echo "$latest"    | awk -F'\t' '$5=="done" && $10+0>0 {s+=$10;n++} END{if(n) printf "%.0f",s/n; else print "N/A"}')
  avg_pipe=$(echo "$latest"  | awk -F'\t' '$5=="done" && $11+0>0 {s+=$11;n++} END{if(n) printf "%.0f",s/n; else print "N/A"}')

  local slurm_running slurm_pending
  slurm_running=$(squeue -u "$USER" -h -t R  -o "%j" 2>/dev/null | grep -c "^ca2-" || echo 0)
  slurm_pending=$(squeue -u "$USER" -h -t PD -o "%j" 2>/dev/null | grep -c "^ca2-" || echo 0)

  local disk_gb
  disk_gb=$(get_disk_usage_gb)

  local pct=0
  [ "$total" -gt 0 ] && pct=$(( done * 100 / total ))

  echo ""
  echo "===== ChIP-Atlas v2 Production: $genome ====="
  echo ""
  printf "  %-18s %7d\n"         "Total samples:" "$total"
  printf "  %-18s %7d  (%d%%)\n" "Done:"          "$done" "$pct"
  printf "  %-18s %7d\n"         "Failed:"        "$failed"
  printf "  %-18s %7d\n"         "Running:"       "$running"
  printf "  %-18s %7d\n"         "Submitted:"     "$submitted"
  printf "  %-18s %7d\n"         "Pending:"       "$pending"
  echo ""
  echo "  SLURM: ${slurm_running} running, ${slurm_pending} pending"
  echo "  Disk:  ~${disk_gb}GB / ${DISK_LIMIT_GB}GB limit"
  echo ""
  echo "  Avg timing (completed):"
  echo "    Download:  ${avg_dl}s"
  echo "    Pipeline:  ${avg_pipe}s"
  echo "    Total:     ${avg_total}s"

  if [ "$failed" -gt 0 ]; then
    echo ""
    echo "  Top failure reasons:"
    echo "$latest" | awk -F'\t' '$5=="failed" && $13!="" {print $13}' \
      | sort | uniq -c | sort -rn | head -5 \
      | while read -r cnt reason; do
          printf "    %5d  %s\n" "$cnt" "$reason"
        done
  fi

  if [ "$done" -gt 0 ] && [ "$avg_total" != "N/A" ]; then
    local remaining=$((total - done - failed))
    if [ "$remaining" -gt 0 ]; then
      local eta_sec=$(( (remaining * avg_total) / MAX_CONCURRENT ))
      local eta_h=$(( eta_sec / 3600 ))
      echo ""
      echo "  ETA: ~${eta_h}h for $remaining remaining (at $MAX_CONCURRENT concurrent, ${avg_total}s/sample)"
    fi
  fi

  echo ""
  echo "  Status: $STATUS_FILE"
  echo "  Logs:   $LOG_DIR/"
  echo "============================================="
  echo ""
}

# ============================================================
# cmd_retry: Resubmit failed samples
# ============================================================
cmd_retry() {
  local genome="${1:?Usage: production-run.sh retry <genome> [--max-retries N]}"
  shift

  local max_retries=$MAX_RETRIES
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-retries) max_retries="$2"; shift 2 ;;
      --dry-run)     DRY_RUN=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  setup_paths "$genome"
  [ -f "$STATUS_FILE" ] || die "No status file for $genome"

  local latest
  latest=$(get_latest_statuses)

  # Eligible: failed AND retry_count < max_retries
  local retry_list="$PROD_DIR/.to-retry.tmp"
  echo "$latest" | awk -F'\t' -v max="$max_retries" \
    '$5=="failed" && ($14+0)<max {print $1 "\t" $3 "\t" $4 "\t" $14}' \
    > "$retry_list"

  local eligible
  eligible=$(wc -l < "$retry_list")
  local exhausted
  exhausted=$(echo "$latest" | awk -F'\t' -v max="$max_retries" '$5=="failed" && ($14+0)>=max' | wc -l)

  log "Failed: $((eligible + exhausted))  Eligible: $eligible  Exhausted ($max_retries+ retries): $exhausted"

  if [ "$eligible" -eq 0 ]; then
    log "Nothing to retry."
    rm -f "$retry_list"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would retry $eligible samples:"
    head -20 "$retry_list" | while IFS=$'\t' read -r acc exp_type num_reads prev; do
      log "  $acc  attempt=$((prev + 1))"
    done
    rm -f "$retry_list"
    return 0
  fi

  local submitted=0
  while IFS=$'\t' read -r acc exp_type num_reads prev_retries; do
    local new_retry=$((prev_retries + 1))
    wait_for_job_slots

    # Remove leftover files from previous attempt
    local srr
    srr=$(grep "^${acc}	" "$SRX_SRR_MAP" | head -1 | cut -f2)
    [ -n "$srr" ] && rm -f "$FASTQ_DIR/${srr}"*.fastq* 2>/dev/null

    local job_script
    job_script=$(generate_job_script "$acc" "$genome" "$exp_type" "$num_reads" "$new_retry")

    local sbatch_out
    sbatch_out=$(sbatch --account="$ACCOUNT" "$job_script" 2>&1)
    local job_id
    job_id=$(echo "$sbatch_out" | grep -oP '\d+' | tail -1)

    if [ -n "$job_id" ]; then
      set_status "$acc" "$genome" "$exp_type" "$num_reads" "submitted" "$job_id" "$(date -Iseconds)" "" "" "" "" "" "" "$new_retry"
      submitted=$((submitted + 1))
      log "Retry $new_retry: $acc (job $job_id)"
    else
      warn "sbatch failed for $acc: $sbatch_out"
    fi
  done < "$retry_list"

  rm -f "$retry_list"
  log "Retried: $submitted samples"
}

# ============================================================
# cmd_summary: Extended report with file inventory
# ============================================================
cmd_summary() {
  local genome="${1:?Usage: production-run.sh summary <genome>}"
  setup_paths "$genome"
  [ -f "$STATUS_FILE" ] || die "No status file for $genome"

  cmd_status "$genome"

  echo "===== Output Inventory ====="
  echo ""

  local bw_count bb_count peak_count fastp_count
  bw_count=$(find "$RESULT_DIR" -name "*.bw" 2>/dev/null | wc -l)
  bb_count=$(find "$RESULT_DIR" -name "*.bb" 2>/dev/null | wc -l)
  peak_count=$(find "$RESULT_DIR" -name "*_peaks.narrowPeak" 2>/dev/null | wc -l)
  fastp_count=$(find "$RESULT_DIR" -name "*_fastp.json" 2>/dev/null | wc -l)

  printf "  BigWig files:    %6d\n" "$bw_count"
  printf "  BigBed files:    %6d\n" "$bb_count"
  printf "  Peak files:      %6d\n" "$peak_count"
  printf "  fastp reports:   %6d\n" "$fastp_count"
  echo ""

  echo "  Disk usage:"
  echo "    Results:  $(du -sh "$RESULT_DIR" 2>/dev/null | cut -f1 || echo '0')"
  echo "    FASTQs:   $(du -sh "$FASTQ_DIR" 2>/dev/null | cut -f1 || echo '0')  (should be ~0 if cleanup works)"
  echo "    Logs:     $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo '0')"
  echo ""

  # Write failed list for easy inspection
  local latest
  latest=$(get_latest_statuses)
  local fail_count
  fail_count=$(echo "$latest" | awk -F'\t' '$5=="failed"' | wc -l)
  if [ "$fail_count" -gt 0 ]; then
    local fail_file="$PROD_DIR/failed-samples.tsv"
    echo "$latest" | awk -F'\t' 'NR==1 || $5=="failed"' > "$fail_file"
    echo "  Failed sample list: $fail_file"
  fi

  echo "============================="
}

# ============================================================
# Dispatch
# ============================================================
case "${1:-}" in
  submit)   shift; cmd_submit "$@" ;;
  status)   shift; cmd_status "$@" ;;
  retry)    shift; cmd_retry "$@" ;;
  summary)  shift; cmd_summary "$@" ;;
  -h|--help|help|"")
    sed -n '/^#/!q; s/^# \{0,1\}//; /^!/d; p' "$0" | tail -n +2
    ;;
  *)
    die "Unknown subcommand: $1 (use: submit, status, retry, summary)"
    ;;
esac
