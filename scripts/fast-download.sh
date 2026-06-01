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
# Download routing (per run; see scripts/download-route.sh):
#   SRR/ERR → ENA HTTPS (.gz) → fasterq-dump
#   DRR     → ENA HTTPS (.gz) → DDBJ local bz2 (NIG /lustre9, transcoded) → fasterq-dump
# ENA serves ready-made .gz for DRR too, so it is tried first everywhere; the
# DDBJ-local bz2->gz transcode is only a fallback (it is CPU-heavy and, taken
# first, stalled download slots — see download-route.sh).
#
# Robustness:
#   - ENA report curl retries 3× with backoff (transient API failures)
#   - aria2c retries each URL 3× internally (transient network failures)
#   - Per-run scratch is wiped between source attempts to avoid stale-state
#     collisions (ENA partial download + SRA fallback used to collide on gzip)
#   - Concat detects actual file layout on disk (ENA metadata sometimes says
#     PAIRED while serving a single interleaved file; we trust the files)
#   - Whole script exits non-zero if any run can't be obtained from any source
#
set -eo pipefail

# Per-run source ordering (ENA-first; DDBJ-local is a DRR-only fallback).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/download-route.sh"

EXP_ACC="$1"
OUTDIR="$2"
SRA_IMG="quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"

if [ -z "$EXP_ACC" ] || [ -z "$OUTDIR" ]; then
  echo "Usage: $0 <experiment_accession> <output_dir>"
  exit 1
fi

mkdir -p "$OUTDIR"

# Cache check: only trust a non-empty file in one of the recognised layouts.
# (The previous `ls EXP*.fastq.gz` pattern matched partial-state remnants.)
have_cached() {
  if [ -s "$OUTDIR/${EXP_ACC}_1.fastq.gz" ] && [ -s "$OUTDIR/${EXP_ACC}_2.fastq.gz" ]; then
    return 0
  fi
  [ -s "$OUTDIR/${EXP_ACC}.fastq.gz" ] && return 0
  return 1
}

if have_cached; then
  echo "[CACHE] $EXP_ACC already downloaded"
  exit 0
fi

# ============================================================
# Resolve experiment → runs via ENA API (with retry)
# ============================================================

fetch_ena_report() {
  local url="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${EXP_ACC}&result=read_run&fields=run_accession,library_layout,fastq_ftp,fastq_md5,fastq_bytes&format=tsv"
  local attempt body
  for attempt in 1 2 3; do
    body=$(curl -sf --max-time 60 "$url" 2>/dev/null || true)
    if [ -n "$body" ]; then
      echo "$body"
      return 0
    fi
    [ "$attempt" -lt 3 ] && sleep $((attempt * 10))
  done
  return 1
}

echo "[ENA] Resolving runs for $EXP_ACC..."
ENA_REPORT=$(fetch_ena_report) || {
  echo "[ERROR] ENA API failed after 3 attempts for $EXP_ACC"
  exit 1
}

NUM_RUNS=$(echo "$ENA_REPORT" | tail -n +2 | grep -c . || true)
if [ "${NUM_RUNS:-0}" -eq 0 ]; then
  echo "[ERROR] No runs found for $EXP_ACC (ENA returned empty list — sample may be withdrawn)"
  exit 1
fi

LAYOUT=$(echo "$ENA_REPORT" | tail -n +2 | head -1 | cut -f2)
echo "[ENA] $EXP_ACC: $NUM_RUNS run(s), layout=$LAYOUT"

# Per-run scratch dir. TMPDIR defaults to /tmp; production callers set
# TMPDIR to a node-local NVMe path (see scripts/nig/run-sample.sh:66) so
# this doesn't fill the host root FS.
TMPDIR_DL="${TMPDIR:-/tmp}/${EXP_ACC}_dl_$$"
mkdir -p "$TMPDIR_DL"
trap "rm -rf '$TMPDIR_DL'" EXIT

# ============================================================
# Per-run download functions
#
# Each returns 0 on success, 1 on failure. All output goes to $TMPDIR_DL
# with filenames matching the run accession. Failure of one source must
# leave $TMPDIR_DL clean for that run so the next source starts fresh.
# ============================================================

clean_run_partials() {
  local run="$1"
  rm -f "$TMPDIR_DL/${run}"*.fastq "$TMPDIR_DL/${run}"*.fastq.gz 2>/dev/null || true
}

download_run_from_ddbj_local() {
  local run="$1"
  local exp_prefix="${EXP_ACC:0:3}"
  [ "$exp_prefix" = "DRX" ] || return 1

  local DDBJ_BASE="/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq"
  local found_dir
  found_dir=$(ls -d "$DDBJ_BASE"/DRA*/DRA*/"$EXP_ACC"/ 2>/dev/null | head -1)
  [ -z "$found_dir" ] && return 1

  local bz2_files
  bz2_files=$(ls "$found_dir/${run}"*.fastq.bz2 2>/dev/null)
  [ -z "$bz2_files" ] && return 1

  echo "  [DDBJ-LOCAL] Copying + decompressing bz2 from Lustre"
  local bz2 base
  for bz2 in $bz2_files; do
    base=$(basename "$bz2" .bz2)
    echo "    $bz2 → ${base}.gz"
    bzcat "$bz2" | gzip > "$TMPDIR_DL/${base}.gz" || return 1
  done
  return 0
}

download_run_from_ena() {
  local run="$1"
  local ftp="$2"
  local md5="$3"

  IFS=';' read -ra URLS <<< "$ftp"
  IFS=';' read -ra MD5S <<< "$md5"

  local i url checksum fname
  local aria2_base=(-x 8 -s 8 -d "$TMPDIR_DL" --console-log-level=warn --retry-wait=10 --max-tries=3)
  for i in "${!URLS[@]}"; do
    url="https://${URLS[$i]}"
    checksum="${MD5S[$i]:-}"
    fname=$(basename "$url")
    echo "  Downloading: $fname"
    local args=("${aria2_base[@]}")
    [ -n "$checksum" ] && args+=("--checksum=md5=$checksum")
    aria2c "${args[@]}" "$url" || return 1
  done
  return 0
}

download_run_from_sra() {
  local run="$1"
  echo "  [SRA] Falling back to fasterq-dump for $run..."
  # --temp pins fasterq-dump's internal scratch under TMPDIR_DL.
  # Without it, fasterq-dump writes fasterq.tmp.<host>.<pid> in CWD ($HOME on
  # SLURM jobs without --workdir), and on killed jobs those orphan dirs are
  # not removed by the EXIT trap on TMPDIR_DL.
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
  # Compress fasterq-dump output and confirm we actually got something.
  local fq
  for fq in "$TMPDIR_DL/${run}"*.fastq; do
    [ -f "$fq" ] && gzip "$fq"
  done
  ls "$TMPDIR_DL/${run}"*.fastq.gz >/dev/null 2>&1 || return 1
  return 0
}

# Download one run, trying sources in priority order. Each source wipes its
# own partial state on failure so the next source starts clean.
download_one_run() {
  local run="$1"
  local ftp="$2"
  local md5="$3"
  local prefix="${run:0:3}"

  # Source order comes from download-route.sh: ENA first (ready .gz, no CPU
  # transcode), DDBJ-local only as a DRR fallback, SRA last. Each failed source
  # wipes its partial state so the next source starts clean.
  local src
  for src in $(download_sources_for "$prefix"); do
    case "$src" in
      ena)        if download_run_from_ena "$run" "$ftp" "$md5"; then return 0; fi ;;
      ddbj_local) if download_run_from_ddbj_local "$run" 2>/dev/null; then return 0; fi ;;
      sra)        if download_run_from_sra "$run"; then return 0; fi ;;
    esac
    clean_run_partials "$run"
  done
  return 1
}

# ============================================================
# Download all runs.
#
# Process substitution (not a pipe) keeps the loop in the current shell so
# failures aren't swallowed by a subshell. Any run that can't be obtained
# from any source fails the entire experiment — never quietly drop a run
# and produce a half-paired FASTQ.
# ============================================================
FAILED_RUNS=()
while IFS=$'\t' read -r run layout ftp md5 bytes; do
  echo "[RUN] $run ($layout)"
  if download_one_run "$run" "$ftp" "$md5"; then
    echo "  [RUN-OK] $run"
  else
    echo "  [RUN-FAIL] $run"
    FAILED_RUNS+=("$run")
  fi
done < <(echo "$ENA_REPORT" | tail -n +2)

if [ "${#FAILED_RUNS[@]}" -gt 0 ]; then
  echo "[ERROR] $EXP_ACC: ${#FAILED_RUNS[@]}/$NUM_RUNS run(s) failed: ${FAILED_RUNS[*]}"
  exit 1
fi

# ============================================================
# Concatenate runs.
#
# Detect the actual layout from files on disk rather than trusting the ENA
# metadata. Some records that ENA reports as PAIRED ship a single interleaved
# .fastq.gz per run — the previous logic ran `cat *_1.fastq.gz` blindly and
# failed with "No such file or directory". This was the largest single source
# of production "FAILED" jobs at the 20K-sample scale.
# ============================================================
shopt -s nullglob
files_1=("$TMPDIR_DL"/*_1.fastq.gz)
files_2=("$TMPDIR_DL"/*_2.fastq.gz)
files_single=()
for f in "$TMPDIR_DL"/*.fastq.gz; do
  case "$f" in
    *_1.fastq.gz|*_2.fastq.gz) ;;
    *) files_single+=("$f") ;;
  esac
done
shopt -u nullglob

echo "[CONCAT] Merging $NUM_RUNS run(s) → $EXP_ACC (paired_1=${#files_1[@]} paired_2=${#files_2[@]} single=${#files_single[@]})"

if [ "${#files_1[@]}" -gt 0 ] && [ "${#files_2[@]}" -gt 0 ]; then
  if [ "${#files_1[@]}" -ne "${#files_2[@]}" ]; then
    echo "[ERROR] PE file-count mismatch: ${#files_1[@]} _1 vs ${#files_2[@]} _2"
    exit 1
  fi
  cat "${files_1[@]}" > "$OUTDIR/${EXP_ACC}_1.fastq.gz"
  cat "${files_2[@]}" > "$OUTDIR/${EXP_ACC}_2.fastq.gz"
  echo "  → ${EXP_ACC}_1.fastq.gz ($(du -h "$OUTDIR/${EXP_ACC}_1.fastq.gz" | cut -f1))"
  echo "  → ${EXP_ACC}_2.fastq.gz ($(du -h "$OUTDIR/${EXP_ACC}_2.fastq.gz" | cut -f1))"
elif [ "${#files_single[@]}" -gt 0 ]; then
  if [ "$LAYOUT" = "PAIRED" ]; then
    echo "  [WARN] ENA metadata says PAIRED but received single-file FASTQ (likely interleaved upload)"
  fi
  cat "${files_single[@]}" > "$OUTDIR/${EXP_ACC}.fastq.gz"
  echo "  → ${EXP_ACC}.fastq.gz ($(du -h "$OUTDIR/${EXP_ACC}.fastq.gz" | cut -f1))"
else
  echo "[ERROR] No FASTQ files in $TMPDIR_DL after download — nothing to concat"
  exit 1
fi

echo "[DONE] $EXP_ACC: $NUM_RUNS run(s) downloaded and merged"
