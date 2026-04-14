#!/bin/bash
#
# Download reference genomes and build indexes for the v2 pipeline.
#
# Uses the pipeline containers (same tool versions as production):
#   - ChIP-seq container: bwa-mem2 index + samtools faidx
#   - BS-seq container:   dnmtools abismalidx (for Bisulfite-seq)
#
# Usage:
#   bash prepare-genomes.sh [BASE_DIR]
#
# Default BASE_DIR: ~/chip-atlas-v2/references
#
set -e

BASE_DIR="${1:-${CHIP_ATLAS_BASE:-$HOME/chip-atlas-v2}/references}"
CHIPSEQ_IMG="ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0"
BSSEQ_IMG="ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.0.0"
UID_GID="$(id -u):$(id -g)"

# Container runtime
if command -v apptainer &>/dev/null; then
  RUN="apptainer exec"
elif command -v singularity &>/dev/null; then
  RUN="singularity exec"
elif command -v docker &>/dev/null; then
  RUN="docker run --rm -u $UID_GID -v __BIND__ -w /data"
else
  echo "ERROR: No container runtime found (apptainer/singularity/docker)"
  exit 1
fi

run_chipseq() {
  local dir="$1"; shift
  if [[ "$RUN" == docker* ]]; then
    docker run --rm -u "$UID_GID" -v "$dir":/data -w /data "$CHIPSEQ_IMG" "$@"
  else
    $RUN "$CHIPSEQ_IMG" bash -c "cd $dir && $*"
  fi
}

run_bsseq() {
  local dir="$1"; shift
  if [[ "$RUN" == docker* ]]; then
    docker run --rm -u "$UID_GID" -v "$dir":/data -w /data "$BSSEQ_IMG" "$@"
  else
    $RUN "$BSSEQ_IMG" bash -c "cd $dir && $*"
  fi
}

declare -A GENOME_URLS
GENOME_URLS=(
  ["hg38"]="https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz"
  ["mm10"]="https://hgdownload.soe.ucsc.edu/goldenPath/mm10/bigZips/mm10.fa.gz"
  ["rn6"]="https://hgdownload.soe.ucsc.edu/goldenPath/rn6/bigZips/rn6.fa.gz"
  ["dm6"]="https://hgdownload.soe.ucsc.edu/goldenPath/dm6/bigZips/dm6.fa.gz"
  ["ce11"]="https://hgdownload.soe.ucsc.edu/goldenPath/ce11/bigZips/ce11.fa.gz"
  ["sacCer3"]="https://hgdownload.soe.ucsc.edu/goldenPath/sacCer3/bigZips/sacCer3.fa.gz"
  ["TAIR10"]="https://ftp.ensemblgenomes.org/pub/plants/release-60/fasta/arabidopsis_thaliana/dna/Arabidopsis_thaliana.TAIR10.dna.toplevel.fa.gz"
)

for genome in "${!GENOME_URLS[@]}"; do
  dir="$BASE_DIR/$genome"
  fa="$dir/${genome}.fa"
  url="${GENOME_URLS[$genome]}"

  echo "========================================"
  echo "Processing $genome"
  echo "========================================"

  mkdir -p "$dir"

  # Download reference FASTA
  if [ ! -f "$fa" ]; then
    echo "[$genome] Downloading reference..."
    curl -sL -o "${fa}.gz" "$url"
    echo "[$genome] Decompressing..."
    gunzip "${fa}.gz"
  else
    echo "[$genome] Reference already exists, skipping download"
  fi

  echo "[$genome] File size: $(du -h "$fa" | cut -f1)"

  # FASTA index + chrom.sizes
  if [ ! -f "$dir/chrom.sizes" ]; then
    echo "[$genome] Creating FASTA index and chrom.sizes..."
    run_chipseq "$dir" samtools faidx "${genome}.fa"
    cut -f1,2 "${fa}.fai" > "$dir/chrom.sizes"
    echo "[$genome] chrom.sizes: $(wc -l < "$dir/chrom.sizes") chromosomes"
  else
    echo "[$genome] chrom.sizes already exists, skipping"
  fi

  # BWA-MEM2 index (for ChIP-seq / ATAC-seq / DNase-seq)
  if [ ! -f "${fa}.bwt.2bit.64" ]; then
    echo "[$genome] Building BWA-MEM2 index (this may take a while)..."
    run_chipseq "$dir" bwa-mem2 index "${genome}.fa"
    echo "[$genome] BWA-MEM2 index complete"
  else
    echo "[$genome] BWA-MEM2 index already exists, skipping"
  fi

  # abismal index (for Bisulfite-seq)
  if [ ! -f "${fa%.fa}.abismal.idx" ]; then
    echo "[$genome] Building abismal index..."
    run_bsseq "$dir" dnmtools abismalidx "${genome}.fa" "${genome}.abismal.idx"
    echo "[$genome] abismal index complete"
  else
    echo "[$genome] abismal index already exists, skipping"
  fi

  echo "[$genome] Done!"
  echo ""
done

echo "========================================"
echo "All genomes prepared!"
echo "========================================"
echo ""
echo "ChIP-seq indexes (bwa-mem2):"
ls -lh "$BASE_DIR"/*/*.bwt.2bit.64 2>/dev/null || echo "  (none)"
echo ""
echo "BS-seq indexes (abismal):"
ls -lh "$BASE_DIR"/*/*.abismal.idx 2>/dev/null || echo "  (none)"
echo ""
echo "Chrom sizes:"
ls -lh "$BASE_DIR"/*/chrom.sizes 2>/dev/null || echo "  (none)"
