# ChIP-Atlas Pipeline v2: Upgrade Plan

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

## Phase 1: Benchmarking & Tool Selection

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

## Phase 2: CWL Workflow Development

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

## Phase 3: Secondary Analysis Rewrite

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

## Phase 4: Validation

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

### 2026-03-25: ce11 full benchmark complete

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

---

## Phase 5: Production Deployment & Migration

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

1. **Benchmarking** — profile v1, evaluate aligners and tool candidates
2. **CWL development** — build Option A and Option B workflows
3. **Custom runner** — develop minimal CWL runner (can parallel with #2)
4. **Secondary analyses** — rewrite in Python + CWL
5. **Validation** — three-way comparison (A vs v1, B vs v1, A vs B)
6. **Decision & Production** — choose option, process remaining samples

## Open Questions

- [ ] Which job scheduler is on the HPC cluster? (SLURM assumed)
- [ ] Parabricks licensing — is it available, or need to acquire?
- [ ] Custom CWL runner language choice
- [ ] CUT&Tag-specific parameters and peak caller (SEACR vs MACS3)
- [ ] Data storage strategy for v2 outputs (same filesystem? new structure?)
