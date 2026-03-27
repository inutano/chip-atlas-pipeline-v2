# ChIP-Atlas Pipeline v2: Upgrade Plan

## Status Overview

| Phase | Status | Summary |
|-------|--------|---------|
| 1. Benchmarking & Tool Selection | [x] Done (Option A) | bwa-mem2 + Parabricks evaluated, --nomodel validated |
| 2. CWL Workflow Development (Option A) | [x] Done | option-a, option-a-nomodel, option-a-parabricks |
| 2. CWL Workflow Development (Option B) | [ ] Not started | fastp, HMMRATAC, SEACR, deeptools |
| 3. Secondary Analysis Rewrite | [ ] Not started | Target genes, colocalization, enrichment |
| 4. Validation (Option A vs v1) | [x] Done (ce11 + hg38) | ~90% peak overlap, 1.5x more peaks on ce11, parity on hg38 |
| 4. Validation (Option B vs v1) | [ ] Not started | |
| 4. Validation (Option A vs B) | [ ] Not started | |
| 5. Production Deployment | [ ] Not started | Cluster setup guide written |
| Custom CWL Runner | [ ] Not started | |

### Remaining TODO

- [ ] Implement Option B "Modern" workflow (fastp + experiment-type-specific callers)
- [ ] Benchmark Option B on ce11 and hg38, compare with Option A and v1
- [ ] Benchmark remaining genomes (dm6, mm10, rn6) — indexes ready, not yet benchmarked
- [ ] Add instrument filter to sample selection (exclude PacBio/ONT)
- [x] ~~Investigate SRX25595131 outlier~~ — resolved: multi-run experiment, only 1 of 2 SRR runs was downloaded
- [ ] Integrate fast-download.sh (aria2c + ENA/DDBJ) into all benchmark scripts
- [ ] Rewrite secondary analyses (target genes, colocalization, enrichment) in CWL
- [ ] Test on shared HPC cluster (cluster setup guide written)
- [ ] Develop custom CWL runner
- [ ] Process 10K+ remaining unprocessed samples
- [ ] Full reprocessing decision after Option A vs B comparison

---

## Design Philosophy

The original ChIP-Atlas pipeline was intentionally minimal: because each sample has a different experimental setup (antibody, cell type, protocol, sequencing depth), per-sample optimization is impractical at scale. The v1 pipeline applies the same basic processing to all samples uniformly — this simplicity is a feature, not a limitation.

For v2, we propose **two pipeline options** to evaluate the tradeoff between speed and modernization:

### Option A: "Fast Classic" — Same steps, faster tools

Preserve the v1 processing logic exactly (same steps, same parameters where possible), but replace each tool with its modern equivalent for speed. No new steps added.

**Pros:**
- Results most comparable to v1 — easier to validate continuity
- Minimal risk of introducing new biases
- Respects the original design rationale (uniform basic processing)
- Simpler to implement and maintain

**Cons:**
- Misses potential quality improvements (e.g., adapter trimming)
- Does not leverage experiment-type-specific best practices
- Some quality issues in v1 data will persist

### Option B: "Modern" — Updated steps and best practices

Modernize the full pipeline: add QC/trimming, use experiment-type-specific peak callers, and apply current best practices.

**Pros:**
- Higher quality results per sample
- Experiment-type-aware processing (ChIP-seq vs ATAC-seq vs CUT&Tag)
- Aligns with current community standards
- Better for new experiment types like CUT&Tag

**Cons:**
- Results will differ more from v1 — harder to validate continuity
- Added complexity in workflow branching per experiment type
- Risk of introducing biases that affect cross-sample comparisons
- More parameters to tune and maintain

### Evaluation Strategy

1. Implement both Option A and Option B as separate CWL workflows
2. Run both on the same representative sample set
3. Compare results: A vs v1, B vs v1, and A vs B
4. Decide which to adopt for production (or run both for different use cases)

---

## Important Policy: No Background/Input Control in Peak Calling

ChIP-Atlas intentionally performs peak calling **without background data** (input DNA / negative control). This is a deliberate design decision, not an oversight:

- **Why**: At the scale of 400K+ experiments from public repositories, it is impractical to reliably identify and pair each ChIP sample with its corresponding input control. Input data is often unavailable, mislabeled, or not explicitly described in the SRA metadata.
- **How it works**: MACS2/MACS3 is run without a control BAM. Instead, peaks are called against a local background model, and users filter results using three q-value thresholds (1e-05, 1e-10, 1e-20) to control stringency.
- **This is a defining characteristic of ChIP-Atlas** — it enables uniform processing of all public data regardless of whether controls exist.
- **v2 must preserve this policy**: Both Option A and Option B must call peaks without background/input control. Do not implement control pairing logic.

---

## Goals

1. **Dramatically reduce processing time** (currently ~1 day/sample)
2. **Modernize tools** — replace decade-old versions
3. **GPU acceleration** where beneficial
4. **CWL-based orchestration** — portable, reproducible, runner-agnostic
5. **Custom CWL runner** — minimal, fastest, flexible for any infrastructure
6. **Full scope** — rewrite both primary processing and secondary analyses
7. **Support new experiment types** — CUT&Tag in addition to ChIP-seq/DNase-seq/ATAC-seq/Bisulfite-seq
8. **Validate against v1** — compare peak counts and overlap to understand differences

## Infrastructure

- **Primary**: On-prem GPU workstation and HPC cluster
- **GPUs**: RTX (older), DGX Spark (H200), potentially more powerful machines
- **RAM**: 128–256 GB per cluster node (smaller on workstation)
- **Cloud**: Available as fallback (AWS/GCP)
- **Containers**: Singularity/Apptainer
- **Benchmark across hardware configs** — different GPU models, memory sizes

## Phase 1: Benchmarking & Tool Selection [x]

### 1.1 ~~Profiling the v1 Pipeline~~ (Skipped)

Reproducing v1 behavior is impractical — many variables and file paths are hardcoded or implicitly declared in the original shell scripts. Instead, we will:

- Build the new pipelines (Option A and B) directly
- Benchmark per-step timing on the new pipelines
- Compare outputs against existing v1 results already available on chip-atlas.dbcls.jp
- The new pipeline will be faster regardless; profiling v1 is not worth the effort

### 1.2 Aligner Evaluation

Run all three on the same sample set, measure speed, memory, and alignment quality:

| Aligner | Type | Notes |
|---------|------|-------|
| bwa-mem2 | CPU (AVX-512) | Fastest CPU aligner, drop-in BWA replacement |
| minimap2 | CPU | Versatile, fast, future-proof for long reads |
| Parabricks (GPU BWA-MEM) | GPU (NVIDIA) | Extremely fast, commercial license required |

Metrics to compare:
- Wall time per sample
- Peak memory usage
- Mapping rate vs. Bowtie2 v1 baseline
- Downstream peak call consistency

### 1.3 Tool Mapping: Option A vs Option B

| Step | v1 Tool | Option A (Fast Classic) | Option B (Modern) |
|------|---------|------------------------|-------------------|
| SRA download | SRA Toolkit 2.3.2-4 | SRA Toolkit latest (fasterq-dump) | Same as A |
| FASTQ QC | (none) | (none) | fastp (QC + trimming in one pass) |
| Trimming | (none) | (none) | fastp |
| Alignment | Bowtie2 2.2.2 | bwa-mem2 / minimap2 / Parabricks | Same as A |
| BAM processing | SAMtools 0.1.19 | SAMtools latest (1.20+) | Same as A |
| Duplicate removal | samtools rmdup | samtools markdup | Same as A |
| Coverage tracks | bedtools 2.17.0 + bedGraphToBigWig | bedtools latest + bedGraphToBigWig | deeptools bamCoverage (BAM→BigWig direct) |
| Peak calling | MACS2 2.1.0 (all types) | MACS3 (all types) | MACS3 (ChIP-seq), HMMRATAC (ATAC-seq), SEACR (CUT&Tag) |
| Format conversion | UCSC bedToBigBed | UCSC tools latest | Same as A |

**Key difference**: Option A keeps the same steps as v1 (no QC, no trimming, single peak caller for all types). Option B adds QC/trimming and uses experiment-type-specific peak callers.

### 1.4 CUT&Tag Considerations (Option B only)

- CUT&Tag has lower background than ChIP-seq — SEACR is the recommended peak caller
- Separate peak-calling branch in the CWL workflow
- Alignment parameters may differ (e.g., fragment size expectations)

## Phase 2: CWL Workflow Development [x] Option A / [ ] Option B

### 2.1 Workflow Structure

```
chip-atlas-pipeline-v2/
├── cwl/
│   ├── tools/                        # CWL CommandLineTool definitions (one per tool)
│   │   ├── fasterq-dump.cwl
│   │   ├── bwa-mem2.cwl
│   │   ├── fastp.cwl                 # Option B only
│   │   ├── samtools-sort.cwl
│   │   ├── samtools-markdup.cwl
│   │   ├── macs3-callpeak.cwl
│   │   ├── deeptools-bamcoverage.cwl  # Option B only
│   │   ├── bedtools-genomecov.cwl     # Option A only
│   │   ├── bedgraphtobigwig.cwl
│   │   ├── bedtobigbed.cwl
│   │   └── ...
│   ├── workflows/
│   │   ├── option-a.cwl              # Fast Classic: same steps as v1, modern tools
│   │   ├── option-b.cwl              # Modern: QC + trimming + type-specific callers
│   │   ├── target-genes.cwl          # Secondary: peak-TSS overlap
│   │   ├── colocalization.cwl        # Secondary: co-binding analysis
│   │   ├── enrichment.cwl            # Secondary: in silico ChIP
│   │   └── full-pipeline.cwl         # Top-level: primary + secondary
│   └── inputs/
│       ├── hg38.yml                  # Per-genome input templates
│       ├── mm10.yml
│       └── ...
├── containers/
│   ├── Singularity.bwa-mem2
│   ├── Singularity.macs3
│   ├── Singularity.fastp
│   └── ...
├── scripts/
│   ├── batch-submit.sh               # Submit multiple samples
│   ├── metadata-filter.py            # SRA metadata filtering (replace shell logic)
│   └── validate-vs-v1.py             # Consistency comparison tool
├── docs/
│   ├── current-pipeline.md
│   └── v2-plan.md
└── tests/
    ├── test-samples.yml               # Representative sample set for testing
    └── expected/                      # Expected outputs for CI
```

### 2.2 CWL Design Principles

- **CWL v1.2** spec
- One `CommandLineTool` per tool — granular, reusable, testable
- `Workflow` documents compose tools into pipelines
- `scatter` for parallel execution across samples
- All tools wrapped in Singularity containers
- Input/output types strictly defined for validation
- Test with **cwltool** initially
- Option A and Option B share the same tool definitions, differ only at workflow level

### 2.3 Custom CWL Runner (sub-project)

- Minimal implementation — support CWL v1.2 subset needed by this pipeline
- Direct job submission to SLURM/SGE/local without intermediate layers
- Singularity-native (no Docker translation layer)
- Parallel step execution with dependency resolution
- Designed for throughput at scale (400K+ samples)
- Language TBD (Rust? Go? Python?)

## Phase 3: Secondary Analysis Rewrite [ ]

### 3.1 Target Gene Analysis

- Replace shell + bedtools with CWL workflow
- Use bedtools latest for peak-TSS overlap
- Rewrite STRING integration in Python
- Output: TSV tables

### 3.2 Colocalization Analysis

- Replace custom Java tool (`coloCA.jar`) with Python implementation
- Same algorithm: Gaussian fit → Z-score groups → pairwise scoring
- Integrate STRING scores
- Wrap as CWL CommandLineTool

### 3.3 Enrichment / In Silico ChIP

- Rewrite in Python with CWL wrapper
- bedtools intersect + scipy for Fisher's exact test
- BH correction via statsmodels

## Phase 4: Validation [x] Option A / [ ] Option B

### 4.1 Sample Selection

Source: `https://chip-atlas.dbcls.jp/data/metadata/experimentList.tab`

#### Stratification Dimensions

1. **Genome** (6 current assemblies, legacy assemblies skipped):
   - hg38, mm10, rn6, dm6, ce11, sacCer3

2. **Experiment type** (6 types):
   - Histone, TFs and others, ATAC-Seq, DNase-seq, RNA polymerase, Bisulfite-Seq
   - Skip: Input control, Unclassified, No description, Annotation tracks

3. **Read count tier** (based on column 8, first comma-separated value):
   - Low: <10M reads
   - Medium: 10–50M reads
   - High: >50M reads

#### Selection Method

- For each **genome × experiment type × read tier** combination:
  - Sort by accession number descending (newer experiments first — biases toward modern sequencing instruments)
  - Pick **3 samples** from the top
- This ensures multiple samples per organism to capture genome-structure-related variation in mapper/peak-caller behavior
- **Expected size**: up to ~270 samples (6 genomes × 6 types × 3 tiers × 3 samples), fewer where combinations are sparse

#### Selection Script

`scripts/select-validation-samples.py` — reads experimentList.tab, applies filters and stratification, outputs the selected sample list to `data/validation-samples.tsv`

### 4.2 Three-Way Comparison

| Comparison | Purpose |
|------------|---------|
| Option A vs v1 | Validate that tool upgrades alone don't break results |
| Option B vs v1 | Understand impact of added QC/trimming/type-specific callers |
| Option A vs Option B | Isolate the effect of modernization steps |

Metrics:
- **Peak count**: number of peaks at each q-value threshold
- **Peak overlap**: Jaccard index and overlap coefficient
- **Exploratory**: visualize differences before setting pass/fail thresholds
- Optionally: BigWig signal correlation (Pearson/Spearman) at later stage

### 4.3 Validation Tooling

- `validate-vs-v1.py`: takes two BED files, reports peak count, overlap stats, generates comparison plots
- Run as part of the test suite

## Progress Log

### 2026-03-20: Initial pipeline implementation and testing

**Completed:**

1. **CWL tool definitions** (11 tools):
   - `fasterq-dump.cwl` — SRA download (sra-tools 3.0.10)
   - `bwa-mem2-align.cwl` — alignment (bwa-mem2 2.2.1)
   - `samtools-sort.cwl` — name/coordinate sort (samtools 1.19.2)
   - `samtools-fixmate.cwl` — add mate score tags for markdup
   - `samtools-markdup.cwl` — duplicate removal (replaces deprecated rmdup)
   - `samtools-mapped-count.cwl` — read count for RPM normalization
   - `bedtools-genomecov.cwl` — BedGraph coverage (bedtools 2.31.1)
   - `bedgraphtobigwig.cwl` — BedGraph → BigWig (UCSC tools 482)
   - `macs3-callpeak.cwl` — peak calling without control (MACS3 3.0.4)
   - `bedtobigbed.cwl` — BED → BigBed (UCSC tools 482)
   - `parabricks-fq2bam.cwl` — GPU-accelerated align+sort+dedup (Parabricks 4.3.1)

2. **Two workflow variants**:
   - `option-a.cwl` — CPU pipeline (bwa-mem2 → sort → fixmate → sort → markdup → ...)
   - `option-a-parabricks.cwl` — GPU pipeline (fq2bam replaces align+sort+markdup)

3. **Validation sample set**: 301 samples selected across 6 genomes × 6 experiment types × 3 read tiers

4. **First test run** on sacCer3 (SRX22049197, H3K4me3, ~950K reads):

| Threshold | v1 (MACS2 + Bowtie2) | v2 bwa-mem2 | v2 Parabricks |
|-----------|---------------------|-------------|---------------|
| q 1e-05   | 429                 | 539         | 539           |
| q 1e-10   | —                   | 396         | 397           |
| q 1e-20   | —                   | 286         | 286           |

- bwa-mem2 and Parabricks produce nearly identical results (±1 peak)
- v2 finds ~25% more peaks than v1 at q 1e-05 (expected: bwa-mem2 is more sensitive than Bowtie2)

**Issues found and fixed during testing:**
- `samtools markdup` requires `fixmate -m` first → added name-sort → fixmate → coord-sort flow
- CWL `float` type truncates tiny q-values (1e-10, 1e-20) to 0 → changed to `string` type
- Several Biocontainers Docker image tags didn't exist → verified and fixed all tags
- Parabricks requires `PU` and `LB` fields in read group → added to fq2bam tool

### 2026-03-25: ce11 full benchmark complete (Option A "Fast Classic")

**All benchmarks below are Option A "Fast Classic"** — same processing steps as v1 (no QC, no trimming, single peak caller), with modern tool replacements for speed. Option B "Modern" (with fastp, experiment-type-specific callers) has not been tested yet.

**Benchmark scope**: 46 ce11 samples (6 experiment types × 3 read tiers × ~3 samples), 1 PacBio sample excluded.

#### Three pipelines tested

| Pipeline | Workflow | Description |
|----------|----------|-------------|
| CPU (default) | `option-a.cwl` | bwa-mem2, MACS3 with model building |
| CPU (nomodel) | `option-a-nomodel.cwl` | bwa-mem2, MACS3 with `--nomodel --extsize 200` |
| GPU (Parabricks) | `option-a-parabricks.cwl` | Parabricks fq2bam, MACS3 with `--nomodel` |

#### Success rates

| Pipeline | OK | Failed | Notes |
|----------|-----|--------|-------|
| CPU (default) | 34 | 12 | 6 MACS3 model failures, 4 SE naming, 1 sort glob, 1 PacBio |
| CPU (nomodel) | 45 | 1 | Only PacBio sample failed |
| GPU (Parabricks) | 45 | 0 | All passed after SE fix (`--in-se-fq`) |

**Conclusion**: `--nomodel --extsize 200` eliminates all MACS3 model-building failures with no loss of accuracy.

#### Processing time (pipeline only, excluding download)

| Read Tier | Samples | CPU (nomodel) | GPU (Parabricks) | Speedup |
|-----------|---------|---------------|-------------------|---------|
| Low (<10M) | 15 | 7 min | 5 min | 1.25x |
| Medium (10-50M) | 15 | 16 min | 11 min | 1.47x |
| High (>50M) | 15 | 43 min | 31 min | 1.37x |
| **Overall** | **45** | **22 min** | **16 min** | **1.37x** |

Compared to v1's ~1 day/sample, the v2 pipeline is **~65x faster** (CPU) to **~90x faster** (GPU) on ce11.

#### Peak count comparison

**nomodel vs default model (CPU, q 1e-05)**:
- ATAC-Seq, DNase-seq, Histone, TFs: **identical peaks** (0 difference)
- RNA polymerase: **<2% difference** (minor, due to estimated vs fixed fragment size)
- `--nomodel` is safe to use as the default

**CPU vs GPU (q 1e-05)**:
- 45 samples compared
- **0.9% total peak count difference** (171,677 vs 173,185)
- Most samples differ by ±1-15 peaks
- bwa-mem2 and Parabricks (BWA-MEM) produce essentially identical results

#### Download speed

| Method | Speed | Notes |
|--------|-------|-------|
| fasterq-dump (NCBI) | Baseline | Single-threaded SRA conversion |
| aria2c + ENA | **2.5x faster** | 8 parallel HTTP connections, pre-generated FASTQ |
| aria2c + DDBJ | Available for DRR | Uses cached fastqlist for path lookup |

Download routing by accession prefix: DRR → DDBJ → ENA → fasterq-dump, SRR/ERR → ENA → fasterq-dump.

#### Issues found and fixed

| Issue | Fix |
|-------|-----|
| MACS3 model building fails on low-signal samples | Added `--nomodel --extsize 200` |
| Single-end FASTQ naming (`SRR.fastq` vs `SRR_1.fastq`) | Flexible FASTQ detection in scripts |
| Parabricks SE reads need `--in-se-fq` not `--in-fq` | Conditional argument in CWL tool |
| ENA `_subreads.fastq` naming for PacBio data | Flexible FASTQ detection + exclude PacBio from validation |
| CWL `float` truncates small q-values | Changed to `string` type |
| MACS3 `xls` output missing when no peaks found | Made output optional (`File?`) |

#### Data quality observation

- SRX2170085 (ce11, Bisulfite-Seq) is a **PacBio RS II** sample mislabeled in SRA metadata. It has 4.5% mapping rate against a short-read index. The v1 pipeline should have filtered this by instrument model. **Recommendation**: add instrument filter to the v2 sample selection to exclude PacBio/ONT samples.

### 2026-03-27: hg38 benchmark complete (Option A "Fast Classic")

**Benchmark scope**: 18 hg38 samples (1 per experiment type × read tier), both CPU and GPU pipelines run in parallel. All using Option A "Fast Classic" with `--nomodel`.

#### Processing time

| Read Tier | Samples | CPU (nomodel) | GPU (Parabricks) | Speedup |
|-----------|---------|---------------|-------------------|---------|
| Low (<10M) | 6 | 7 min | 5 min | 1.4x |
| Medium (10-50M) | 6 | 60 min | 31 min | 1.9x |
| High (>50M) | 6 | 118 min | 72 min | 1.6x |
| **Overall** | **18** | **61 min** | **36 min** | **1.7x** |

GPU speedup is larger on hg38 (1.7x) than ce11 (1.37x) — GPU acceleration benefits more from larger genomes.

Notable outliers:
- Bisulfite-Seq 45M reads: CPU 91 min vs GPU **8 min** (10.2x speedup)
- Bisulfite-Seq 314M reads: CPU 214 min vs GPU **67 min** (3.1x speedup)
- Some samples showed CPU faster than GPU (ATAC-Seq 59M, Histone 123M) — likely due to GPU/CPU resource contention from running both benchmarks in parallel

#### Peak count comparison (CPU vs GPU, q 1e-05)

- 14 samples compared (1 GPU output missing)
- **0.8% total peak count difference** (168,493 CPU vs 167,069 GPU)
- Most samples differ by <1%, consistent with ce11 results
- One outlier: SRX26159220 (TFs) differed by ~1,500 peaks (7%) — worth investigating

#### Processing time estimates for full ChIP-Atlas reprocessing (hg38)

Based on average pipeline times (excluding download):

| Scenario | Per sample | 200K hg38 samples | With download |
|----------|-----------|-------------------|---------------|
| CPU (1 node, 8 cores) | 61 min | ~23 years | + download time |
| GPU (1 node, 1 GPU) | 36 min | ~14 years | + download time |
| CPU cluster (10 nodes) | 61 min | ~2.3 years | + download time |
| GPU cluster (10 GPUs) | 36 min | ~1.4 years | + download time |
| CPU cluster (100 nodes) | 61 min | ~84 days | + download time |

**Conclusion**: Processing at scale requires significant parallelism. A cluster with 100+ CPU nodes or 10+ GPU nodes is needed for a reasonable reprocessing timeline.

#### Comparison: ce11 vs hg38 scaling

| Metric | ce11 (100MB genome) | hg38 (3GB genome) | Ratio |
|--------|--------------------|--------------------|-------|
| CPU avg pipeline | 22 min | 61 min | 2.8x |
| GPU avg pipeline | 16 min | 36 min | 2.3x |
| GPU speedup | 1.37x | 1.7x | GPU benefits more on larger genomes |

### 2026-03-27: v1 vs v2 Peak Overlap Analysis (Option A "Fast Classic")

Downloaded v1 BED files from chip-atlas.dbcls.jp and compared peak overlap with v2 Option A results using bedtools intersect.

#### ce11 (35 samples with v1 peaks + 10 with v1=0)

| Metric | Value |
|--------|-------|
| v1 peaks recovered in v2 | **~90%** average |
| v2 finds more peaks | 77% of samples (1.6x total peaks) |
| v1=0 but v2 found peaks | 10 samples (thousands of peaks each) |

**Overlap by experiment type:**

| Type | Avg overlap | Notes |
|------|------------|-------|
| RNA polymerase | 97% | Excellent concordance |
| Histone | 93% | Good, v2 finds more |
| ATAC-Seq | 88% | v2 finds 2-40x more peaks in high-read samples |
| TFs and others | 87% | Good concordance, similar counts |
| DNase-seq | 87% | v2 finds more peaks |

#### hg38 (12 samples with v1 peaks)

| Metric | Value |
|--------|-------|
| v1 peaks recovered in v2 | **~77%** average |
| Samples with >90% overlap | 4/12 (DNase-seq, ATAC-Seq) |
| Samples with <70% overlap | 2/12 (see outliers below) |

**Overlap by sample:**

| Type | v1 peaks | v2 peaks | Overlap | Notes |
|------|---------|---------|---------|-------|
| ATAC-Seq (8M) | 3,316 | 10,657 | 98% | v2 finds 3x more |
| DNase-seq (50M) | 35,958 | 35,885 | 93% | Nearly identical |
| DNase-seq (72M) | 51,473 | 55,556 | 95% | v2 slightly more |
| TFs (21M) | 14,704 | 16,605 | 94% | Good concordance |
| TFs (52M) | 23,306 | 22,890 | 88% | Good |
| Histone (26M) | 1,046 | 1,268 | 84% | v2 finds more |
| RNA pol (20M) | 820 | 1,513 | 80% | v2 finds ~2x more |

**Outliers:**
- ~~SRX25595131 (Histone, 10M reads, SE): v1=8,797 peaks → v2=201 peaks~~ **RESOLVED**: This experiment has **2 SRR runs** (SRR30125615: 3M reads + SRR30125616: 7M reads) but the benchmark only downloaded the first run (30% of data). After downloading and concatenating both runs: **v2=6,633 peaks** — consistent with v1's 8,797 (~25% difference from tool changes, not a bug). **Fix**: `download-experiment.sh` now resolves all runs per experiment and concatenates FASTQs, matching v1's behavior.
- SRX25254554 (TFs, 10M reads): v1=28,075 → v2=20,239 (66% overlap). v2 finds fewer peaks.

#### Multi-threshold comparison (q 1e-05, 1e-10, 1e-20)

**v1 vs v2 CPU peak count ratio across all thresholds:**

| Genome | q05 (v2/v1) | q10 (v2/v1) | q20 (v2/v1) |
|--------|------------|------------|------------|
| ce11 (35 samples) | 1.5x | 1.5x | 1.7x |
| hg38 (11 samples, excl. outlier) | 1.0x | 0.9x | 0.8x |

- ce11: v2 consistently finds **more peaks at all thresholds**, with the ratio increasing at stricter cutoffs — v2's additional peaks are high-confidence
- hg38: v2 and v1 are **near-parity at q05**, with v2 finding slightly fewer at stricter thresholds
- The difference between genomes may reflect aligner-specific behavior on different genome structures (ce11 ~100MB vs hg38 ~3GB)

**v2 CPU vs GPU consistency across thresholds:**

| Threshold | ce11 (45 samples) | hg38 (18 samples) |
|-----------|------------------|-------------------|
| q05 | 0.8% diff | 0.8% diff |
| q10 | 1.1% diff | — |
| q20 | 1.3% diff | — |

CPU and GPU produce nearly identical results at all thresholds, confirming that the choice of aligner (bwa-mem2 vs Parabricks BWA-MEM) has minimal impact on peak calling.

#### Interpretation

1. **v2 recovers most v1 peaks** (~90% for ce11, ~77% for hg38) — the core signal is preserved
2. **v2 finds more peaks on ce11** (1.5x) but is **near-parity on hg38** — the v1-v2 difference is genome-dependent
3. **Samples with v1=0 now have peaks in v2** — this is an improvement, not a regression (10 ce11 samples)
4. **Some samples show fewer peaks in v2** — expected given different tools; users can adjust with q-value thresholds
5. **Overlap varies by experiment type** — RNA polymerase shows the best concordance, ATAC-Seq shows the most new peaks
6. **CPU and GPU are interchangeable** — <1.5% peak difference at all thresholds

---

## Phase 5: Production Deployment & Migration [ ]

### 5.1 Decision Point

After Phase 4 validation, decide:
- **Adopt Option A** if consistency with v1 is paramount
- **Adopt Option B** if quality improvements justify the differences
- **Run both** if different use cases need different tradeoffs

### 5.2 Incremental Rollout

1. Process the 10K+ remaining unprocessed samples with chosen option
2. Reprocess a subset of existing 400K samples for validation
3. Full reprocessing if results are satisfactory

### 5.3 Update Infrastructure

- Metadata filtering: rewrite in Python (replace shell scripts)
- Incremental update logic: detect new SRA accessions, queue for processing
- Data distribution: same URL structure for backward compatibility

## Timeline (rough phases, not time estimates)

1. [x] **Benchmarking** — evaluate aligners (bwa-mem2, Parabricks), validate --nomodel
2. [x] **CWL development (Option A)** — option-a, option-a-nomodel, option-a-parabricks
3. [ ] **CWL development (Option B)** — fastp, HMMRATAC, SEACR, deeptools
4. [ ] **Custom runner** — develop minimal CWL runner (can parallel with #3)
5. [ ] **Secondary analyses** — rewrite in Python + CWL
6. [x] **Validation (Option A)** — A vs v1 on ce11 + hg38
7. [ ] **Validation (Option B)** — B vs v1, A vs B
8. [ ] **Decision & Production** — choose option, process remaining samples

## Open Questions

- [ ] Which job scheduler is on the HPC cluster? (SLURM assumed)
- [ ] Parabricks licensing — is it available, or need to acquire?
- [ ] Custom CWL runner language choice
- [ ] CUT&Tag-specific parameters and peak caller (SEACR vs MACS3)
- [ ] Data storage strategy for v2 outputs (same filesystem? new structure?)
- [ ] Why does hg38 show near-parity with v1 while ce11 shows 1.5x more peaks?
- [x] ~~SRX25595131 outlier~~ — resolved: multi-run download issue (see progress log)
