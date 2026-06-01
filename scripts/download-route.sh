#!/usr/bin/env bash
#
# download-route.sh — per-run FASTQ source ordering for fast-download.sh.
# Pure; safe to source.
#
# ENA serves ready-made .gz for SRR/ERR and DRR alike, so it is always tried
# first (a plain aria2c download — no CPU transcode, network-bound). DDBJ-local
# is the on-cluster /lustre9 bz2 archive: using it requires a bz2->gz transcode,
# so it is only a *fallback* for DRR runs ENA doesn't have. SRA fasterq-dump is
# the last resort everywhere.
#
# Rationale: DRR is ~1.6% of the catalogue, but DDBJ-local-first made those few
# samples stall on a single-threaded bzcat|gzip transcode and clog all the
# download slots (head-of-line blocking), stalling the whole run. ENA-first
# removes the transcode from the hot path entirely.

# download_sources_for <run_prefix> -> space-separated ordered source names
#   (one of: ena | ddbj_local | sra)
download_sources_for() {
  case "$1" in
    DRR) echo "ena ddbj_local sra" ;;
    *)   echo "ena sra" ;;
  esac
}
