#!/bin/bash
#
# Fast FASTQ download for ChIP-Atlas experiments.
#
# Accepts an experiment accession (SRX/DRX/ERX), resolves all run accessions
# via the ENA API, downloads FASTQs, and concatenates multiple runs into a
# single FASTQ pair per experiment.
#
# Usage: fast-download.sh <experiment_accession> <output_dir>
#
# Output:
#   PE: <output_dir>/<experiment>_1.fastq.gz, <experiment>_2.fastq.gz
#   SE: <output_dir>/<experiment>.fastq.gz
#
# Download routing (per run):
#   DRR → DDBJ local bz2 (NIG only) → ENA HTTPS → fasterq-dump
#   ERR → ENA HTTPS → fasterq-dump
#   SRR → ENA HTTPS → fasterq-dump
#
set -eo pipefail

EXP_ACC="$1"
OUTDIR="$2"
SRA_IMG="quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"

if [ -z "$EXP_ACC" ] || [ -z "$OUTDIR" ]; then
  echo "Usage: $0 <experiment_accession> <output_dir>"
  exit 1
fi

mkdir -p "$OUTDIR"

# Check if already downloaded
if ls "$OUTDIR"/${EXP_ACC}*.fastq.gz 1>/dev/null 2>&1; then
  echo "[CACHE] $EXP_ACC already downloaded"
  exit 0
fi

# ============================================================
# Resolve experiment → runs via ENA API
# ============================================================

echo "[ENA] Resolving runs for $EXP_ACC..."
ENA_REPORT=$(curl -sf "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${EXP_ACC}&result=read_run&fields=run_accession,library_layout,fastq_ftp,fastq_md5,fastq_bytes&format=tsv" 2>/dev/null || true)

NUM_RUNS=$(echo "$ENA_REPORT" | tail -n +2 | grep -c . || echo 0)

if [ "$NUM_RUNS" -eq 0 ]; then
  echo "[ERROR] No runs found for $EXP_ACC"
  exit 1
fi

# Detect layout from first run (consistent across runs per experiment)
LAYOUT=$(echo "$ENA_REPORT" | tail -n +2 | head -1 | cut -f2)
echo "[ENA] $EXP_ACC: $NUM_RUNS run(s), layout=$LAYOUT"

# Temporary directory for per-run downloads
TMPDIR_DL="${TMPDIR:-/tmp}/${EXP_ACC}_dl_$$"
mkdir -p "$TMPDIR_DL"
trap "rm -rf $TMPDIR_DL" EXIT

# ============================================================
# Download functions (per run)
# ============================================================

download_run_from_ena() {
  local run="$1"
  local ftp="$2"
  local md5="$3"

  IFS=';' read -ra URLS <<< "$ftp"
  IFS=';' read -ra MD5S <<< "$md5"

  for i in "${!URLS[@]}"; do
    local url="https://${URLS[$i]}"
    local checksum="${MD5S[$i]:-}"
    local fname
    fname=$(basename "$url")

    echo "  Downloading: $fname"
    local aria2_args="-x 8 -s 8 -d $TMPDIR_DL --console-log-level=warn"
    if [ -n "$checksum" ]; then
      aria2_args="$aria2_args --checksum=md5=$checksum"
    fi
    aria2c $aria2_args "$url" || return 1
  done
  return 0
}

download_run_from_ddbj_local() {
  local run="$1"
  local exp_prefix="${EXP_ACC:0:3}"

  # Only DRX experiments have local bz2 on NIG
  [ "$exp_prefix" = "DRX" ] || return 1

  local DDBJ_BASE="/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq"
  local found_dir
  found_dir=$(ls -d "$DDBJ_BASE"/DRA*/DRA*/"$EXP_ACC"/ 2>/dev/null | head -1)

  if [ -z "$found_dir" ]; then
    return 1
  fi

  local bz2_files
  bz2_files=$(ls "$found_dir"/${run}*.fastq.bz2 2>/dev/null)

  if [ -z "$bz2_files" ]; then
    return 1
  fi

  echo "  [DDBJ-LOCAL] Copying + decompressing bz2 from Lustre"
  for bz2 in $bz2_files; do
    local base
    base=$(basename "$bz2" .bz2)
    echo "    $bz2 → ${base}.gz"
    bzcat "$bz2" | gzip > "$TMPDIR_DL/${base}.gz"
  done
  return 0
}

download_run_from_sra() {
  local run="$1"
  echo "  [SRA] Falling back to fasterq-dump for $run..."
  # --temp pins fasterq-dump's internal scratch under TMPDIR_DL.
  # Without it, fasterq-dump writes fasterq.tmp.<host>.<pid> in CWD ($HOME on
  # SLURM jobs without --workdir), and on killed jobs those orphan dirs are
  # not removed by the EXIT trap on TMPDIR_DL — they accumulate in $HOME and
  # eventually fill the user's quota.
  if command -v apptainer &>/dev/null; then
    apptainer exec "docker://$SRA_IMG" \
      fasterq-dump "$run" --split-files --skip-technical --threads 4 \
        --temp "$TMPDIR_DL" --outdir "$TMPDIR_DL" 2>&1 | tail -3
  elif command -v singularity &>/dev/null; then
    singularity exec "docker://$SRA_IMG" \
      fasterq-dump "$run" --split-files --skip-technical --threads 4 \
        --temp "$TMPDIR_DL" --outdir "$TMPDIR_DL" 2>&1 | tail -3
  elif command -v docker &>/dev/null; then
    docker run --rm -v "$TMPDIR_DL":/data -w /data "$SRA_IMG" \
      fasterq-dump "$run" --split-files --skip-technical --threads 4 \
        --temp . --outdir . 2>&1 | tail -3
  else
    echo "  [SRA] ERROR: No container runtime found"
    return 1
  fi
  # Compress fasterq-dump output (produces uncompressed .fastq)
  for fq in "$TMPDIR_DL"/${run}*.fastq; do
    [ -f "$fq" ] && gzip "$fq"
  done
  return 0
}

# ============================================================
# Download all runs
# ============================================================

echo "$ENA_REPORT" | tail -n +2 | while IFS=$'\t' read -r run layout ftp md5 bytes; do
  echo "[RUN] $run ($layout)"

  local_prefix="${run:0:3}"

  # Try sources in priority order
  if [ "$local_prefix" = "DRR" ]; then
    download_run_from_ddbj_local "$run" 2>/dev/null || \
    download_run_from_ena "$run" "$ftp" "$md5" || \
    download_run_from_sra "$run"
  else
    download_run_from_ena "$run" "$ftp" "$md5" || \
    download_run_from_sra "$run"
  fi
done

# ============================================================
# Concatenate runs into per-experiment FASTQs
# ============================================================

echo "[CONCAT] Merging $NUM_RUNS run(s) → $EXP_ACC"

if [ "$LAYOUT" = "PAIRED" ]; then
  # Concatenate all _1.fastq.gz and _2.fastq.gz files
  cat "$TMPDIR_DL"/*_1.fastq.gz > "$OUTDIR/${EXP_ACC}_1.fastq.gz"
  cat "$TMPDIR_DL"/*_2.fastq.gz > "$OUTDIR/${EXP_ACC}_2.fastq.gz"
  echo "  → ${EXP_ACC}_1.fastq.gz ($(du -h "$OUTDIR/${EXP_ACC}_1.fastq.gz" | cut -f1))"
  echo "  → ${EXP_ACC}_2.fastq.gz ($(du -h "$OUTDIR/${EXP_ACC}_2.fastq.gz" | cut -f1))"
else
  # SE: concatenate all .fastq.gz files (may be .fastq.gz or _1.fastq.gz without _2)
  cat "$TMPDIR_DL"/*.fastq.gz > "$OUTDIR/${EXP_ACC}.fastq.gz"
  echo "  → ${EXP_ACC}.fastq.gz ($(du -h "$OUTDIR/${EXP_ACC}.fastq.gz" | cut -f1))"
fi

echo "[DONE] $EXP_ACC: $NUM_RUNS run(s) downloaded and merged"
