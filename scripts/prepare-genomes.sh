#!/bin/bash
set -e

BASE_DIR="/data3/chip-atlas-v2/test-run"
BWA_MEM2_IMG="quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8"
SAMTOOLS_IMG="quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"
UID_GID="$(id -u):$(id -g)"

declare -A GENOME_URLS
GENOME_URLS=(
  ["hg38"]="https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz"
  ["rn6"]="https://hgdownload.soe.ucsc.edu/goldenPath/rn6/bigZips/rn6.fa.gz"
  ["dm6"]="https://hgdownload.soe.ucsc.edu/goldenPath/dm6/bigZips/dm6.fa.gz"
  ["ce11"]="https://hgdownload.soe.ucsc.edu/goldenPath/ce11/bigZips/ce11.fa.gz"
)

for genome in ce11 dm6 rn6 hg38; do
  dir="$BASE_DIR/$genome"
  fa="$dir/${genome}.fa"
  url="${GENOME_URLS[$genome]}"

  echo "========================================"
  echo "Processing $genome"
  echo "========================================"

  mkdir -p "$dir"

  # Download if not present
  if [ ! -f "$fa" ]; then
    echo "[$genome] Downloading reference..."
    curl -s -o "${fa}.gz" "$url"
    echo "[$genome] Decompressing..."
    gunzip "${fa}.gz"
  else
    echo "[$genome] Reference already exists, skipping download"
  fi

  echo "[$genome] File size: $(du -h "$fa" | cut -f1)"

  # FASTA index + chrom.sizes
  if [ ! -f "$dir/chrom.sizes" ]; then
    echo "[$genome] Creating FASTA index and chrom.sizes..."
    docker run --rm -u "$UID_GID" -v "$dir":/data -w /data "$SAMTOOLS_IMG" \
      samtools faidx "${genome}.fa"
    cut -f1,2 "${fa}.fai" > "$dir/chrom.sizes"
    echo "[$genome] chrom.sizes: $(wc -l < "$dir/chrom.sizes") chromosomes"
  else
    echo "[$genome] chrom.sizes already exists, skipping"
  fi

  # BWA-MEM2 index
  if [ ! -f "${fa}.bwt.2bit.64" ]; then
    echo "[$genome] Building BWA-MEM2 index (this may take a while)..."
    docker run --rm -u "$UID_GID" -v "$dir":/data -w /data "$BWA_MEM2_IMG" \
      bwa-mem2 index "${genome}.fa"
    echo "[$genome] BWA-MEM2 index complete"
  else
    echo "[$genome] BWA-MEM2 index already exists, skipping"
  fi

  echo "[$genome] Done!"
  echo ""
done

echo "========================================"
echo "All genomes prepared!"
echo "========================================"
ls -lhR "$BASE_DIR"/*/chrom.sizes "$BASE_DIR"/*/*.bwt.2bit.64 2>/dev/null
