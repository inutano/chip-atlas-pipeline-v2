#!/bin/bash
#
# Fast FASTQ download with source-aware routing + aria2c.
#
# Usage: fast-download.sh <run_accession> <output_dir>
#
# Routes downloads based on accession prefix to the origin repository:
#   DRR (DDBJ/Japan) → DDBJ first → ENA → fasterq-dump
#   ERR (ENA/Europe) → ENA first → fasterq-dump
#   SRR (NCBI/US)    → ENA first → fasterq-dump
#
# Uses aria2c with 8 parallel connections for HTTP/FTP downloads.
# Falls back to fasterq-dump (Docker) when mirrored FASTQs aren't available.
#
set -eo pipefail

RUN_ACC="$1"
OUTDIR="$2"
SRA_IMG="quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"

if [ -z "$RUN_ACC" ] || [ -z "$OUTDIR" ]; then
  echo "Usage: $0 <run_accession> <output_dir>"
  exit 1
fi

mkdir -p "$OUTDIR"

# Check if already downloaded
if ls "$OUTDIR"/${RUN_ACC}*.fastq 1>/dev/null 2>&1 || ls "$OUTDIR"/${RUN_ACC}*.fastq.gz 1>/dev/null 2>&1; then
  echo "[CACHE] $RUN_ACC already downloaded"
  exit 0
fi

# Detect prefix
PREFIX="${RUN_ACC:0:3}"

# ============================================================
# Download functions
# ============================================================

download_from_ena() {
  local acc="$1"
  echo "[ENA] Querying filereport API for $acc..."
  local ena_report
  ena_report=$(curl -sf "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${acc}&result=read_run&fields=run_accession,fastq_ftp,fastq_md5,fastq_bytes&format=tsv" 2>/dev/null || true)

  local ena_lines
  ena_lines=$(echo "$ena_report" | wc -l)

  if [ "$ena_lines" -le 1 ]; then
    echo "[ENA] No data found for $acc"
    return 1
  fi

  local fastq_ftp fastq_md5
  fastq_ftp=$(echo "$ena_report" | tail -1 | cut -f2)
  fastq_md5=$(echo "$ena_report" | tail -1 | cut -f3)

  if [ -z "$fastq_ftp" ] || [ "$fastq_ftp" = "" ]; then
    echo "[ENA] No FASTQ URLs for $acc"
    return 1
  fi

  echo "[ENA] FASTQ available, downloading with aria2c..."
  IFS=';' read -ra URLS <<< "$fastq_ftp"
  IFS=';' read -ra MD5S <<< "$fastq_md5"

  for i in "${!URLS[@]}"; do
    local url="http://${URLS[$i]}"
    local md5="${MD5S[$i]:-}"
    local filename
    filename=$(basename "$url")

    echo "  Downloading: $filename"
    local aria2_args="-x 8 -s 8 -d $OUTDIR --console-log-level=warn"
    if [ -n "$md5" ]; then
      aria2_args="$aria2_args --checksum=md5=$md5"
    fi
    aria2c $aria2_args "$url" || return 1
  done

  # Decompress .fastq.gz to .fastq
  for gz in "$OUTDIR"/${acc}*.fastq.gz; do
    if [ -f "$gz" ]; then
      echo "  Decompressing: $(basename "$gz")"
      gunzip "$gz"
    fi
  done

  echo "[ENA] Download complete"
  return 0
}

download_from_ddbj() {
  local acc="$1"
  echo "[DDBJ] Looking up $acc in fastqlist..."

  # Use cached DDBJ fastqlist (file_path, md5, bytes, audit_time)
  # Cache at /data3/chip-atlas-v2/cache/ddbj-fastqlist.tsv
  local FASTQLIST="/data3/chip-atlas-v2/cache/ddbj-fastqlist.tsv"

  if [ ! -f "$FASTQLIST" ]; then
    echo "[DDBJ] fastqlist cache not found, downloading..."
    mkdir -p "$(dirname "$FASTQLIST")"
    curl -sf "https://ddbj.nig.ac.jp/public/ddbj_database/dra/meta/list/fastqlist" -o "$FASTQLIST" || {
      echo "[DDBJ] Failed to download fastqlist"
      return 1
    }
  fi

  # Grep for matching files (may return multiple lines for PE)
  local matches
  matches=$(grep "/${acc}" "$FASTQLIST" || true)

  if [ -z "$matches" ]; then
    echo "[DDBJ] $acc not found in fastqlist"
    return 1
  fi

  echo "[DDBJ] FASTQ available, downloading with aria2c..."

  local downloaded=false
  while IFS=$'\t' read -r fpath md5 bytes audit; do
    local url="https://ddbj.nig.ac.jp/public${fpath}"
    local filename
    filename=$(basename "$fpath")

    echo "  Downloading: $filename ($(echo "$bytes" | awk '{printf "%.0fMB", $1/1048576}'))"
    local aria2_args="-x 8 -s 8 -d $OUTDIR --console-log-level=warn"
    if [ -n "$md5" ]; then
      aria2_args="$aria2_args --checksum=md5=$md5"
    fi
    aria2c $aria2_args "$url" || return 1
    downloaded=true
  done <<< "$matches"

  if [ "$downloaded" = false ]; then
    return 1
  fi

  # Decompress .fastq.bz2 to .fastq
  for bz2 in "$OUTDIR"/${acc}*.fastq.bz2; do
    if [ -f "$bz2" ]; then
      echo "  Decompressing: $(basename "$bz2")"
      bunzip2 "$bz2"
    fi
  done

  echo "[DDBJ] Download complete"
  return 0
}

download_from_sra() {
  local acc="$1"
  echo "[SRA] Falling back to fasterq-dump for $acc..."
  docker run --rm -v "$OUTDIR":/data -w /data "$SRA_IMG" \
    fasterq-dump "$acc" --split-files --skip-technical --threads 4 --outdir . 2>&1 \
    | tail -3
  echo "[SRA] Download complete"
  return 0
}

# ============================================================
# Route based on accession prefix
# ============================================================

case "$PREFIX" in
  DRR)
    echo "[ROUTE] $RUN_ACC → DDBJ (Japanese origin)"
    download_from_ddbj "$RUN_ACC" || \
    download_from_ena "$RUN_ACC" || \
    download_from_sra "$RUN_ACC"
    ;;
  ERR)
    echo "[ROUTE] $RUN_ACC → ENA (European origin)"
    download_from_ena "$RUN_ACC" || \
    download_from_sra "$RUN_ACC"
    ;;
  SRR)
    echo "[ROUTE] $RUN_ACC → ENA mirror (US origin)"
    download_from_ena "$RUN_ACC" || \
    download_from_sra "$RUN_ACC"
    ;;
  *)
    echo "[ROUTE] $RUN_ACC → Unknown prefix '$PREFIX', using fasterq-dump"
    download_from_sra "$RUN_ACC"
    ;;
esac
