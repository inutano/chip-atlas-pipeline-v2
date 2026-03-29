# Secondary Analysis Plan

## Overview

The v1 pipeline produces three types of secondary analyses from peak call results:

1. **Target Genes** — which genes are near each peak (peak-TSS overlap)
2. **Colocalization** — which transcription factors bind together in the same cell type
3. **Enrichment (In Silico ChIP)** — are user-provided regions enriched for specific peaks

v1 pre-computes all combinations and generates static HTML/TSV. This is rigid and expensive to recompute. v2 should produce structured data that enables both static export and dynamic queries.

## Data Architecture

### Per-sample outputs (from primary pipeline)

Already produced by v2:
- BigWig (.bw) — coverage tracks
- narrowPeak (.narrowPeak) — peak calls at 3 q-value thresholds
- BigBed (.bb) — peak tracks for browsers

### Aggregated data (new in v2)

| Data | Format | Content |
|------|--------|---------|
| Peak-TSS overlaps | SQLite | Every peak × nearby TSS within ±1/5/10 kb |
| Colocalization scores | SQLite | Pairwise TF binding correlation per cell type |
| Sample metadata | SQLite | experimentList with standardized antigen/cell type |
| Peak index | SQLite | All peaks across all samples, queryable by region |

### Why SQLite

- Single file per genome — no database server, portable, shippable
- Users can download and query locally
- Web app queries via thin API wrapper
- Can export to static TSV/HTML for backward compatibility
- Well-supported everywhere (Python, R, command line, browsers via sql.js)

## Analysis 1: Target Genes

### What it does

For each experiment's peaks, find protein-coding genes whose TSS falls within a window (±1 kb, ±5 kb, ±10 kb).

### v1 approach
- `bedtools window` per experiment
- Filter for NM_ RefSeq (protein-coding)
- Integrate STRING protein interaction scores
- Output: static TSV and HTML per antigen × cell type

### v2 approach

**Step 1: Prepare reference data (once per genome)**

```
genes.tsv — protein-coding gene list with TSS coordinates
  columns: gene_id, gene_symbol, chrom, tss_position, strand
  source: UCSC refFlat → filter NM_ → deduplicate TSS
```

**Step 2: CWL tool — peak-tss-overlap**

```
Input:  narrowPeak (from primary pipeline) + genes.tsv
Output: overlaps.tsv
  columns: peak_chrom, peak_start, peak_end, peak_score,
           gene_symbol, tss_distance, window_size
```

Implementation: `bedtools window` with ±1/5/10 kb, one pass per window size.

**Step 3: Load into SQLite**

```sql
CREATE TABLE peak_tss_overlap (
  experiment_id TEXT,
  peak_chrom TEXT,
  peak_start INTEGER,
  peak_end INTEGER,
  peak_score REAL,
  gene_symbol TEXT,
  tss_distance INTEGER,
  window_kb INTEGER    -- 1, 5, or 10
);

CREATE INDEX idx_experiment ON peak_tss_overlap(experiment_id);
CREATE INDEX idx_gene ON peak_tss_overlap(gene_symbol);
CREATE INDEX idx_window ON peak_tss_overlap(window_kb);
```

**Queries this enables:**

```sql
-- "What genes does H3K4me3 target in HeLa cells?"
SELECT gene_symbol, AVG(peak_score) as mean_score, COUNT(*) as n_experiments
FROM peak_tss_overlap
JOIN metadata ON experiment_id = metadata.accession
WHERE metadata.antigen = 'H3K4me3'
  AND metadata.cell_type = 'HeLa'
  AND window_kb = 5
GROUP BY gene_symbol
ORDER BY mean_score DESC;

-- "What experiments have peaks near TP53?"
SELECT experiment_id, peak_score, tss_distance
FROM peak_tss_overlap
WHERE gene_symbol = 'TP53'
  AND window_kb = 10
ORDER BY peak_score DESC;
```

## Analysis 2: Colocalization

### What it does

Identify transcription factors that co-bind in the same cell type. If TF-A and TF-B both have peaks in the same genomic regions in the same cell type, they are "colocalized."

### v1 approach
- Fit MACS2 scores to Gaussian distribution
- Assign Z-score groups: H (>0.5), M (-0.5 to 0.5), L (<-0.5)
- Score 9 pairwise H/M/L combinations
- Custom Java tool (`coloCA.jar`)
- Integrate STRING scores
- Output: static HTML matrices per cell type

### v2 approach

**Step 1: CWL tool — colocalization-score**

```
Input:  All narrowPeak files for a given cell type
Output: pairwise_scores.tsv
  columns: antigen_a, antigen_b, colocalization_score,
           n_shared_peaks, jaccard_index
```

Implementation: Python script using same algorithm as v1 (Gaussian fit → Z-scores → pairwise scoring), but output as structured data instead of HTML.

**Step 2: Load into SQLite**

```sql
CREATE TABLE colocalization (
  cell_type TEXT,
  antigen_a TEXT,
  antigen_b TEXT,
  coloc_score REAL,
  n_shared_peaks INTEGER,
  jaccard_index REAL
);

CREATE INDEX idx_coloc_cell ON colocalization(cell_type);
CREATE INDEX idx_coloc_antigen ON colocalization(antigen_a, antigen_b);
```

**Queries this enables:**

```sql
-- "What co-binds with MYC in K562 cells?"
SELECT antigen_b, coloc_score, n_shared_peaks
FROM colocalization
WHERE cell_type = 'K562'
  AND antigen_a = 'MYC'
ORDER BY coloc_score DESC;
```

## Analysis 3: Enrichment (In Silico ChIP)

### What it does

Given user-provided genomic regions (BED), test whether they are enriched for peaks from specific experiments. Answers: "Are my GWAS hits enriched for H3K27ac in liver?"

### v1 approach
- `bedtools intersect` for overlap
- Fisher's exact test with BH correction
- Pre-computed for FANTOM5 and GWAS catalog
- Output: static HTML

### v2 approach

**This is fundamentally a query-time operation** — users provide regions, the system tests against all experiments. Pre-computation is only for known region sets (FANTOM5, GWAS catalog).

**Step 1: Build a peak index**

```sql
CREATE TABLE peak_index (
  experiment_id TEXT,
  chrom TEXT,
  start INTEGER,
  end INTEGER,
  score REAL,
  q_threshold TEXT  -- '05', '10', '20'
);

CREATE INDEX idx_peak_region ON peak_index(chrom, start, end);
CREATE INDEX idx_peak_exp ON peak_index(experiment_id);
```

This enables fast region overlap queries without bedtools.

**Step 2: Enrichment API / tool**

```
Input:  user BED regions + peak_index database
Output: enrichment results
  columns: experiment_id, antigen, cell_type,
           n_overlap, n_total_peaks, n_total_regions,
           fold_enrichment, p_value, q_value
```

Implementation: SQLite range queries for overlap, scipy for Fisher's test.

**Trade-off: SQLite vs bedtools for overlap**

For pre-computed enrichment (FANTOM5, GWAS), bedtools is fine — run once, store results.
For dynamic user queries, SQLite with R-tree index could be fast enough for interactive use, but for millions of peaks × thousands of regions, bedtools is still faster. A hybrid approach:
- Store peaks in SQLite for metadata queries
- Use bedtools (or a bedtools-like Rust tool) for the actual overlap computation
- Store results back in SQLite

## Implementation Plan

### Phase 1: Target Genes (highest value, simplest)

1. Write CWL tool: `peak-tss-overlap.cwl`
2. Write reference data prep script (UCSC refFlat → genes.tsv per genome)
3. Write SQLite loader script
4. Test on ce11 + hg38 benchmark samples
5. Write example queries

### Phase 2: Colocalization

1. Port v1 algorithm from Java to Python
2. Write CWL tool: `colocalization-score.cwl`
3. Write SQLite loader
4. Test on ce11 samples (need multiple experiments per cell type)

### Phase 3: Enrichment

1. Build peak index in SQLite
2. Write enrichment calculation tool
3. Pre-compute for FANTOM5 and GWAS catalog
4. Design query API for dynamic enrichment

### Phase 4: Integration

1. SQLite database schema for all three analyses
2. Export scripts for backward-compatible TSV/HTML
3. API wrapper for web app
4. Documentation

## Database Schema (unified)

One SQLite file per genome:

```
chip_atlas_{genome}.db
├── metadata          — experiment info (accession, antigen, cell_type, ...)
├── peak_tss_overlap  — target gene results
├── colocalization    — co-binding scores
├── peak_index        — all peaks (for enrichment queries)
└── enrichment_precomputed — FANTOM5, GWAS results
```

Estimated sizes:
- hg38: ~200K experiments × ~1000 peaks avg × 3 thresholds = ~600M rows in peak_index
- With SQLite compression and indexing: ~50-100 GB per genome
- Could be split into per-threshold databases to reduce size

## Open Questions

- [ ] Should we support BED → SQLite conversion as a CWL step, or as a post-pipeline script?
- [ ] STRING database integration — download latest or pin a version?
- [ ] Peak index: store all peaks or only q05 (most permissive)?
- [ ] SQLite per genome or one big database?
- [ ] Should the enrichment tool be a CWL tool or a standalone web service?
