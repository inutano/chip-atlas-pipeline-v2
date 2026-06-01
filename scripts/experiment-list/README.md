# Experiment list — source query & reproduction

The production experiment list is **generated, not stored**. The big TSV
(`chipatlas_fast.tsv`, ~89 MB) is git-ignored; what lives here is the query
that produces it, so the list can be regenerated and audited from source.

## Files (vendored)

| file | role |
|------|------|
| `chipatlas_select_fast.rq`  | SPARQL query → the production list (`chipatlas_fast.tsv`). |
| `chipatlas_select_other.rq` | SPARQL query → CUT&Tag/CUT&RUN samples mislabeled `OTHER` (`chipatlas_other.tsv`). Not currently batched. |
| `run_chipatlas_selection.sh`| Runs both queries against a QLever endpoint and reformats QLever's `tsv_export` into the 10-column TSV. |

**Vendored from** `github.com/inutano/insdc-rdf` (`scripts/`) — note: these files
were **untracked** in that repo as of `insdc-rdf@c3ba3b0`, so this is currently
their only version-controlled home. If they change upstream, re-vendor them here.

## What the query selects

- **Organisms:** ~230 NCBI taxonomy IDs — the 7 supported genomes plus their
  strain/subspecies variants (e.g. *S. cerevisiae* W303/BY4741/S288C, mouse
  subspecies). Genome assignment (taxon → sacCer3/ce11/rn6/dm6/TAIR10/mm10/hg38)
  happens later in `scripts/make-batches.sh`.
- **Library strategy × selection** (the `fast` query): `ChIP-Seq`,
  `DNase-Hypersensitivity`, `ATAC-seq`, `Bisulfite-Seq`, restricted to
  `GENOMIC` source on `ILLUMINA` platforms.
- **Output columns (10, tab-separated):**
  `SRX  SAMN  TITLE  LIBRARY_STRATEGY  LIBRARY_SOURCE  LIBRARY_SELECTION  INSTRUMENT_MODEL  Organism  SRP  PRJ`

## Reproduce

Full regeneration needs the DDBJ DRA/BioSample/BioProject RDF loaded into a
QLever endpoint — that infrastructure is built by the `insdc-rdf` repo, not here.

```bash
# 1. Stand up the QLever endpoint (see insdc-rdf), then run the selection:
bash run_chipatlas_selection.sh  http://localhost:7001  ./chipatlas-out
#    -> chipatlas-out/chipatlas_fast.tsv

# 2. Slice into per-(genome,pipeline) batches for production:
scripts/make-batches.sh  chipatlas-out/chipatlas_fast.tsv  sample-lists/batches/  5000
```

## Snapshot used for the current production campaign

| field   | value |
|---------|-------|
| date    | 2026-05-27 |
| rows    | 532,701 (incl. header) → **532,700 experiments** |
| sha256  | `8867eb4911d3c27df575dd157e0270476f0703141f95aed50288fc199382a2cb` |
| batched | 114 batches × 5,000, smallest genome first |

Per-genome counts (chipseq / bsseq): hg38 211,667 / 33,080 · mm10 178,396 /
40,968 · TAIR10 13,824 / 7,872 · sacCer3 18,957 / 56 · dm6 16,796 / 86 · ce11
7,465 / 0 · rn6 3,120 / 413.

To confirm a run used this exact snapshot: `sha256sum chipatlas_fast.tsv`.
