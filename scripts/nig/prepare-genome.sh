#!/bin/bash
#
# Prepare a single genome reference in the NIG flat layout.
#
# Builds (idempotent — skips any step whose output already exists):
#   - ${REF}/${GENOME}.fa            (download + decompress)
#   - ${REF}/${GENOME}.fa.fai        (samtools faidx)
#   - ${REF}/${GENOME}.chrom.sizes   (cut from .fai)
#   - ${REF}/${GENOME}.fa.bwt.2bit.64 + sibling bwa-mem2 files
#   - ${REF}/${GENOME}.abismal.idx
#
# Usage (inside a SLURM job on a compute node):
#   bash prepare-genome.sh <genome>
#
# Requires:
#   - apptainer on PATH (or set APPTAINER_BIN)
#   - $SHARED/containers/{pipeline-v2.sif,pipeline-v2-bs.sif}
#
set -euo pipefail

GENOME="${1:?usage: $0 <genome>}"

# Apptainer (NIG-specific path; override via env)
export PATH="${APPTAINER_BIN:-/opt/pkg/apptainer/1.4.5/bin}:$PATH"

SHARED="${SHARED:-/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2}"
REF="$SHARED/references"
CHIP_SIF="$SHARED/containers/pipeline-v2.sif"
BS_SIF="$SHARED/containers/pipeline-v2-bs.sif"

# Per-job scratch on node-local NVMe (always a unique dir we own — never reuse
# system $TMPDIR or /tmp; the trap deletes WORK on exit so it must be ours).
WORK="/data1/tmp/prep-${GENOME}-${SLURM_JOB_ID:-$$}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

declare -A URLS=(
  [hg38]="https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz"
  [mm10]="https://hgdownload.soe.ucsc.edu/goldenPath/mm10/bigZips/mm10.fa.gz"
  [rn6]="https://hgdownload.soe.ucsc.edu/goldenPath/rn6/bigZips/rn6.fa.gz"
  [dm6]="https://hgdownload.soe.ucsc.edu/goldenPath/dm6/bigZips/dm6.fa.gz"
  [ce11]="https://hgdownload.soe.ucsc.edu/goldenPath/ce11/bigZips/ce11.fa.gz"
  [sacCer3]="https://hgdownload.soe.ucsc.edu/goldenPath/sacCer3/bigZips/sacCer3.fa.gz"
  [TAIR10]="https://ftp.ensemblgenomes.org/pub/plants/release-60/fasta/arabidopsis_thaliana/dna/Arabidopsis_thaliana.TAIR10.dna.toplevel.fa.gz"
)

URL="${URLS[$GENOME]:-}"
if [ -z "$URL" ]; then
  echo "ERROR: unknown genome '$GENOME' (known: ${!URLS[*]})" >&2
  exit 1
fi

FA="$REF/${GENOME}.fa"
FAI="$REF/${GENOME}.fa.fai"
CHROM="$REF/${GENOME}.chrom.sizes"
BWA_MARK="$REF/${GENOME}.fa.bwt.2bit.64"
ABISMAL="$REF/${GENOME}.abismal.idx"

mkdir -p "$REF"

echo "=== prepare $GENOME ==="
echo "  REF=$REF"
echo "  WORK=$WORK"
echo "  start: $(date -Iseconds)"

# 1. FASTA
if [ ! -s "$FA" ]; then
  echo "[$GENOME] download FASTA"
  # TAIR10 source (ftp.ensemblgenomes.org) presents a cert that doesn't list
  # its own hostname in SAN — accept that one source insecurely. Everything
  # else stays strict.
  CURL_FLAGS=(-fsSL --retry 5 --retry-delay 10)
  [ "$GENOME" = "TAIR10" ] && CURL_FLAGS+=(-k)
  curl "${CURL_FLAGS[@]}" -o "$WORK/${GENOME}.fa.gz" "$URL"
  echo "[$GENOME] decompress"
  gunzip -c "$WORK/${GENOME}.fa.gz" > "$FA.tmp"
  mv "$FA.tmp" "$FA"
  rm -f "$WORK/${GENOME}.fa.gz"
else
  echo "[$GENOME] FASTA already present ($(du -h "$FA" | cut -f1))"
fi

# 2. samtools faidx + chrom.sizes  (use ChIP container; both ship samtools but ChIP is the canonical one)
if [ ! -s "$FAI" ]; then
  echo "[$GENOME] samtools faidx"
  apptainer exec --bind "$REF:/ref" "$CHIP_SIF" \
    bash -c "cd /ref && samtools faidx ${GENOME}.fa"
fi
if [ ! -s "$CHROM" ]; then
  echo "[$GENOME] chrom.sizes from .fai"
  cut -f1,2 "$FAI" > "$CHROM"
fi
echo "[$GENOME] $(wc -l < "$CHROM") chromosomes"

# 3. bwa-mem2 index
if [ ! -s "$BWA_MARK" ]; then
  echo "[$GENOME] bwa-mem2 index (this is the memory-heavy step)"
  apptainer exec --bind "$REF:/ref" --bind "$WORK:/tmp" "$CHIP_SIF" \
    bash -c "cd /ref && bwa-mem2 index ${GENOME}.fa"
else
  echo "[$GENOME] bwa-mem2 index already present"
fi

# 4. abismal index
if [ ! -s "$ABISMAL" ]; then
  echo "[$GENOME] dnmtools abismalidx"
  apptainer exec --bind "$REF:/ref" --bind "$WORK:/tmp" "$BS_SIF" \
    bash -c "cd /ref && dnmtools abismalidx ${GENOME}.fa ${GENOME}.abismal.idx"
else
  echo "[$GENOME] abismal index already present"
fi

echo "[$GENOME] done: $(date -Iseconds)"
ls -lh "$REF/${GENOME}".*
