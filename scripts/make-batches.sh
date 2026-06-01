#!/usr/bin/env bash
#
# make-batches.sh — slice the SPARQL experiment list (chipatlas_fast.tsv) into
# fixed-size, per-(genome,pipeline) batch lists for sequential production.
#
# Output layout:
#   <outdir>/<genome>-<pipeline>/batch-NNNN.tsv   (4-col: accession genome strategy SINGLE)
#   <outdir>/manifest.tsv                          (one row per batch; progress ledger)
#
# Usage: make-batches.sh <chipatlas_fast.tsv> <outdir> [batch_size]
#
set -euo pipefail

SRC="${1:?usage: make-batches.sh <chipatlas_fast.tsv> <outdir> [batch_size]}"
OUTDIR="${2:?usage: make-batches.sh <chipatlas_fast.tsv> <outdir> [batch_size]}"
BATCH_SIZE="${3:-5000}"

[ -f "$SRC" ] || { echo "ERROR: source not found: $SRC" >&2; exit 1; }

mkdir -p "$OUTDIR"
MANIFEST="$OUTDIR/manifest.tsv"
printf 'genome\tpipeline\tbatch_id\tpath\tn\tstatus\n' > "$MANIFEST"

# Smallest genome first (validate cheaply before the mammalian bulk).
GENOMES="rn6 ce11 dm6 sacCer3 TAIR10 mm10 hg38"
PIPELINES="chipseq bsseq"

emit() {
  local genome="$1" pipeline="$2"
  local dir="$OUTDIR/${genome}-${pipeline}"
  mkdir -p "$dir"
  rm -f "$dir"/batch-*.tsv   # clean any prior generation

  awk -F'\t' -v OFS='\t' -v genome="$genome" -v pipeline="$pipeline" \
      -v size="$BATCH_SIZE" -v dir="$dir" -v manifest="$MANIFEST" '
    function orgmatch(org, g) {
      if (g=="sacCer3") return org ~ /^Saccharomyces cerevisiae/
      if (g=="ce11")    return org ~ /^Caenorhabditis elegans/
      if (g=="rn6")     return org ~ /^Rattus norvegicus/
      if (g=="dm6")     return org ~ /^Drosophila melanogaster/
      if (g=="TAIR10")  return org ~ /^Arabidopsis thaliana/
      if (g=="mm10")    return org ~ /^Mus musculus/
      if (g=="hg38")    return org ~ /^Homo sapiens/
      return 0
    }
    function stratmatch(s, p) {
      if (p=="chipseq") return (s=="ChIP-Seq" || s=="ATAC-seq" || s=="DNase-Hypersensitivity")
      if (p=="bsseq")   return (s=="Bisulfite-Seq")
      return 0
    }
    NR==1 { next }
    orgmatch($8, genome) && stratmatch($4, pipeline) {
      n++
      b = int((n - 1) / size) + 1
      fn = sprintf("%s/batch-%04d.tsv", dir, b)
      print $1, genome, $4, "SINGLE" > fn
      cnt[b]++
    }
    END {
      nb = (n > 0) ? int((n - 1) / size) + 1 : 0
      for (i = 1; i <= nb; i++) {
        printf "%s\t%s\t%04d\t%s-%s/batch-%04d.tsv\t%d\tpending\n", \
          genome, pipeline, i, genome, pipeline, i, cnt[i] >> manifest
      }
    }
  ' "$SRC"

  rmdir "$dir" 2>/dev/null || true   # remove if no batches were written (e.g. ce11 bsseq)
}

for g in $GENOMES; do
  for p in $PIPELINES; do
    emit "$g" "$p"
  done
done

n_batches=$(($(wc -l < "$MANIFEST") - 1))
n_exp=$(awk -F'\t' 'NR>1 {s+=$5} END {print s+0}' "$MANIFEST")
echo "Wrote $n_batches batches ($n_exp experiments) under $OUTDIR"
echo "Manifest: $MANIFEST"
