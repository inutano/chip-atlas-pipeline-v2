# Secondary Analysis: Implementation Summary

## Overview

Three secondary analyses aggregate peak call results across experiments. All are implemented and tested on ce11.

| Analysis | Input | Output | Serving | Query speed |
|----------|-------|--------|---------|-------------|
| Target genes | Per-experiment peaks + TSS | JSON per antigen | Static HTML (GitHub Pages) | Instant (client-side) |
| Colocalization | Peaks from same cell class | JSON per experiment | Static HTML (GitHub Pages) | Instant (client-side) |
| Enrichment | User BED + compiled peaks | JSON result | Interactive (backend) | <1 sec |

**Demo:** https://inutano.github.io/chip-atlas-pipeline-v2/demo/

## 1. Target Genes

**Question:** What genes are near the peaks for a given antigen?

**Approach:**
1. `bedtools window` at ±1/5/10 kb between each experiment's peaks and gene TSS positions
2. Aggregate overlaps per antigen (all experiments for H3K27ac, all for CTCF, etc.)
3. Output as JSON: genes × experiments matrix with MACS scores
4. One HTML template renders any JSON with search, sort, filter, column sorting, TSV/JSON download

**Data flow:**
```
narrowPeak files → bedtools window × genes_tss.bed → per-experiment overlap TSV
→ aggregate by antigen → per-antigen JSON → HTML template
```

**v1 comparison:**
- v1: pre-generated static HTML per antigen × cell type, with STRING integration
- v2: one HTML template + JSON data files, STRING links per gene, window navigation (±1/5/10 kb)

**Scripts:**
- `scripts/prepare-gene-reference.py` — UCSC refFlat → TSS BED (protein-coding, deduplicated)
- `scripts/peak-tss-overlap.sh` — bedtools window for one experiment
- `scripts/generate-antigen-target-json.py` — aggregate overlaps into per-antigen JSON
- `scripts/generate-demo-pages.py` — embed JSON into self-contained HTML

**Storage (estimated):**
- ~4 MB per antigen JSON (±5kb, average)
- hg38: ~2000 antigens × 3 windows × 4 MB = ~24 GB total

## 2. Colocalization

**Question:** What transcription factors co-bind in the same cell type?

**Approach:**
1. For each experiment, classify peak scores into H/M/L using Gaussian-fitted Z-scores
2. Compare all pairs of experiments within the same cell type class
3. Score 9 pairwise H/M/L combinations (H-H=9, H-M=6, M-M=4, etc.)
4. Output as JSON per experiment with ranked partners

**Data flow:**
```
narrowPeak files → Gaussian fit → Z-score classification (H/M/L)
→ pairwise comparison within cell class → per-experiment JSON → HTML template
```

**v1 comparison:**
- v1: custom Java tool (`coloCA.jar`), STRING integration, static HTML
- v2: Python implementation (same algorithm), STRING links, color-coded H/M/L categories

**Scripts:**
- `scripts/compute-colocalization.py` — pairwise scoring with H/M/L classification

**Storage:**
- ~10 KB per experiment JSON
- hg38: 200K experiments × 10 KB = ~2 GB total

## 3. Enrichment (In Silico ChIP)

**Question:** Are the user's genomic regions enriched for peaks from specific experiments?

This is ChIP-Atlas's unique interactive feature — no other database offers this at scale.

**Approach:**
1. Build one **compiled BED file** per genome containing ALL peaks from all experiments, annotated with experiment ID, antigen, and cell type
2. User uploads a BED file
3. `bedtools intersect` against the compiled BED — one operation, exact peak boundaries
4. Count overlaps per experiment, Fisher's exact test with BH correction
5. Return ranked experiments by enrichment significance

**Data flow:**
```
All narrowPeak files → compiled BED (sorted, annotated)

User query:
  user.bed → bedtools intersect × compiled BED → count per experiment
  → Fisher's exact test → BH correction → ranked JSON result
```

**Why compiled BED (not binned index):**
- Exact peak boundaries — no resolution loss
- bedtools intersect is fast even on large files (<1 sec for ce11, ~5-10 sec estimated for hg38)
- One sorted file per genome — simple, no database
- Same statistics as v1 (Fisher's test on exact overlaps)

**v1 comparison:**
- v1: bedtools intersect per experiment (slow at 400K scale), static HTML for FANTOM5/GWAS
- v2: single compiled BED, one intersect operation, real-time results

**Scripts:**
- `scripts/enrichment-analysis.py` — compiled BED builder + Fisher's test + BH correction

**Storage:**
- ce11 (45 experiments): 9 MB compiled BED
- hg38 (197K experiments, estimated): ~12 GB compiled BED

**Performance (tested on ce11):**
- 100 query regions × 172K peaks: <1 second
- hg38 estimate: 5-10 seconds per query

## Storage Summary

| Data | ce11 (45 exp) | hg38 (197K exp, est.) |
|------|--------------|----------------------|
| Target genes JSON | 56 MB | ~24 GB |
| Colocalization JSON | 0.5 MB | ~2 GB |
| Compiled BED (enrichment) | 9 MB | ~12 GB |
| Primary outputs (BigWig + peaks) | — | ~55 TB |

Secondary analysis adds <40 GB on top of the ~55 TB primary data for hg38 — negligible.

## Architecture Decision

**Static files for target genes + colocalization.** Pre-generate JSON data, serve with one HTML template per analysis type. No backend needed — works from any CDN, S3, or GitHub Pages.

**Interactive service for enrichment.** User uploads BED, server runs bedtools intersect against compiled BED, returns JSON. Needs a lightweight backend, but the query itself is just one bedtools command.

This matches v1's architecture (static for target/colo, interactive for enrichment) while modernizing the data format (JSON instead of pre-rendered HTML) and the delivery mechanism (one template + data instead of thousands of static pages).
