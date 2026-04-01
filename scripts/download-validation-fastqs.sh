#!/bin/bash
set -e

BASE_DIR="$HOME/repos/chip-atlas-pipeline-v2/test-run"
SAMPLES_TSV="$HOME/repos/chip-atlas-pipeline-v2/data/validation-samples.tsv"
SRA_IMG="quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"

# Skip header, process each sample
tail -n +2 "$SAMPLES_TSV" | while IFS=$'\t' read -r accession genome rest; do
  # Only process current genome assemblies
  case "$genome" in
    hg38|mm10|rn6|dm6|ce11|sacCer3) ;;
    *) continue ;;
  esac

  outdir="$BASE_DIR/$genome/fastq"
  mkdir -p "$outdir"

  # Skip if already downloaded
  if ls "$outdir/${accession}"*.fastq 1>/dev/null 2>&1; then
    echo "[SKIP] $accession ($genome) — already downloaded"
    continue
  fi

  echo "[DOWNLOAD] $accession ($genome)..."

  # Look up SRR accession from SRX
  srr=$(docker run --rm "$SRA_IMG" \
    sh -c "esearch -db sra -query '$accession' 2>/dev/null | efetch -format runinfo 2>/dev/null | grep -oP 'SRR[0-9]+' | head -1" 2>/dev/null || true)

  # Fallback: try NCBI E-utilities via curl
  if [ -z "$srr" ]; then
    srr=$(curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=sra&id=${accession}&rettype=xml" \
      | grep -oP 'SRR[0-9]+' | sort -u | head -1)
  fi

  if [ -z "$srr" ]; then
    echo "[ERROR] Could not resolve SRR for $accession, skipping"
    continue
  fi

  echo "  SRR: $srr"

  # Download FASTQ
  docker run --rm -v "$outdir":/data -w /data "$SRA_IMG" \
    fasterq-dump "$srr" --split-files --skip-technical --threads 4 --outdir . 2>&1 \
    | tail -3

  # Rename files to include SRX accession for clarity
  for f in "$outdir/${srr}"*.fastq; do
    if [ -f "$f" ]; then
      newname=$(echo "$f" | sed "s/${srr}/${accession}/")
      mv "$f" "$newname"
    fi
  done

  echo "[DONE] $accession ($genome)"
  echo ""
done

echo "========================================"
echo "All FASTQ downloads complete!"
echo "========================================"
for genome in sacCer3 ce11 dm6 mm10 rn6 hg38; do
  count=$(ls "$BASE_DIR/$genome/fastq/"*.fastq 2>/dev/null | wc -l)
  echo "  $genome: $count FASTQ files"
done
