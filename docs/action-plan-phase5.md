# Phase 5 Action Plan: Production Pipeline

Based on discussion with co-maintainers (2026-04-03).

## Decision

**Option B CPU (Fast piped)** for production on NIG kumamoto dedicated nodes (6 × 128-core AMD EPYC). Goal: reprocess all 845K samples within a few months.

## Pipeline Fixes (before benchmarking)

### 1. Remove --nomodel from MACS3

Let MACS3 build the fragment size model naturally. If model building fails (low signal), no peaks is the correct result — the BigWig is still produced for users to check coverage.

**Files to change:**
- `scripts/pipeline-option-b-fast.sh` — remove `--nomodel --extsize 200`
- `cwl/tools/macs3-callpeak.cwl` — remove nomodel default
- `cwl/workflows/option-b.cwl` and all Option B variants — remove nomodel input

### 2. BigWig at single basepair resolution

ChIP-Atlas requires `--binSize 1` for BigWig files. Current pipeline uses binned resolution (10bp or 50bp). This will be slower and produce larger files — need to investigate optimization.

**Options to evaluate:**
- deeptools bamCoverage `--binSize 1` — simple but potentially very slow
- bedtools genomecov + bedGraphToBigWig — v1 approach, naturally single-bp
- Split BAM by chromosome → parallel bamCoverage → merge BigWigs
- Pipe from dedup BAM directly to bedtools genomecov (avoid second BAM read)

**Priority: HIGH** — this could become the pipeline bottleneck.

### 3. Add TAIR10 (Arabidopsis thaliana)

7th genome assembly for ChIP-Atlas.

- Download TAIR10 FASTA from TAIR/Ensembl
- Build bwa-mem2 index
- MACS3 genome size: ~1.2e8
- Add to validation sample selection
- Update genome lists in all scripts

## Benchmarking (after fixes)

### Test matrix

Test with multiple CPU core / memory configurations on typical samples (exclude 300M+ extreme cases):

- Core counts: 4, 8, 16, 32
- Memory: proportional to cores (4GB/core baseline)
- Sample sizes: representative from <1M, 1-10M, 10-50M, 50-100M tiers
- Measure: wall time, peak memory (RSS), core efficiency (min × cores)

### Memory profiling

Confirm the piped approach's peak memory to determine max jobs per node:
- Use `sacct --format=MaxRSS` or `/usr/bin/time -v`
- Critical for deciding 4/8/16/32 jobs per node

## Future Investigations

### Bisulfite-Seq sub-pipeline

v1 used `bmap` (closed source, unmaintained, slow). Evaluate modern alternatives:
- Bismark, bwa-meth, BSBolt
- Compare speed, accuracy, intermediate file sizes
- May need a separate pipeline branch for WGBS

### CUT&Run / CUT&Tag peak callers

Evaluate dedicated tools vs MACS3:
- SEACR — designed for CUT&Run/CUT&Tag, supports no-control mode
- GoPeaks — newer, fast
- Benchmark on existing SRA samples

### Nanopore methylation

Future exploration (not blocking v2):
- Survey ONT methylation samples in SRA
- Investigate minimap2 + methylation callers
- Processing time characteristics

### Instrument filtering

v1 filtered by Illumina platform. Current v2 filter is title-field regex (unreliable). Investigate:
- How v1 detected platform (SRA metadata XML?)
- Match v1 approach in v2 for production

## Download Strategy for Production

### ENA rate-limiting risk

624 concurrent downloads could trigger rate-limits/bans.

**Approach: Pre-fetch phase**
1. Separate download jobs with controlled parallelism (e.g., 16 concurrent aria2c)
2. Download all FASTQs to shared cache before processing
3. Processing jobs read from local cache only
4. Stagger downloads to avoid thundering herd

### DDBJ local advantage

NIG is at DDBJ — DRR accessions can use local filesystem or DDBJ network. Prioritize DDBJ routing.

## Decisions Made

| Decision | Status |
|----------|--------|
| Option B CPU for production | Confirmed |
| No GPU pipeline | Confirmed (not enough GPU nodes) |
| Remove --nomodel | Confirmed (let MACS3 model naturally) |
| Single MACS3 + awk filter for q-values | Confirmed (acceptable tradeoff) |
| ENA + aria2c download strategy | Confirmed (not using local .sra + fastq-dump) |
| Add TAIR10 (Arabidopsis) | Confirmed |
| BigWig single-bp resolution | Confirmed (required feature) |
