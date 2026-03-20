# ChIP-Atlas Pipeline v2: Upgrade Plan

## Goals

1. **Dramatically reduce processing time** (currently ~1 day/sample)
2. **Modernize all tools** — replace decade-old versions with current best-in-class
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

### 1.1 Profiling the v1 Pipeline

- Run v1 on a representative set of samples with per-step timing
- Confirm bottlenecks (suspected: SRA download, alignment)
- Measure CPU, memory, disk I/O, and wall time per step
- Profile on both workstation and cluster node

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

### 1.3 Tool Upgrades (all steps)

| Step | v1 Tool | v2 Candidates | Notes |
|------|---------|---------------|-------|
| SRA download | SRA Toolkit 2.3.2-4 | SRA Toolkit latest (fasterq-dump), aria2 for parallel download | fasterq-dump is multithreaded; aria2 for HTTP/FTP fallback |
| FASTQ QC | (none) | FastQC + MultiQC, fastp | Add QC step that v1 lacks |
| Trimming | (none) | fastp | Fast, handles adapter trimming + QC in one pass |
| Alignment | Bowtie2 2.2.2 | bwa-mem2 / minimap2 / Parabricks | Benchmark all three |
| BAM processing | SAMtools 0.1.19 | SAMtools latest (1.20+) | Massive performance improvements over 0.1.x |
| Duplicate removal | samtools rmdup | samtools markdup / Picard MarkDuplicates / Parabricks | samtools rmdup is deprecated |
| Coverage tracks | bedtools 2.17.0 + bedGraphToBigWig | deeptools bamCoverage / bedtools latest | deeptools does BAM→BigWig directly with normalization options |
| Peak calling | MACS2 2.1.0 | MACS3 / HMMRATAC (for ATAC-seq) | MACS3 is actively maintained, Python 3 native |
| Format conversion | UCSC bedToBigBed | UCSC tools latest | Minimal change needed |

### 1.4 CUT&Tag Considerations

- CUT&Tag has lower background than ChIP-seq — SEACR is the recommended peak caller
- May need separate peak-calling branch in the CWL workflow
- Alignment parameters may differ (e.g., fragment size expectations)

## Phase 2: CWL Workflow Development

### 2.1 Workflow Structure

```
chip-atlas-pipeline-v2/
├── cwl/
│   ├── tools/               # CWL CommandLineTool definitions (one per tool)
│   │   ├── fasterq-dump.cwl
│   │   ├── fastp.cwl
│   │   ├── bwa-mem2.cwl
│   │   ├── samtools-sort.cwl
│   │   ├── samtools-markdup.cwl
│   │   ├── deeptools-bamcoverage.cwl
│   │   ├── macs3-callpeak.cwl
│   │   ├── bedtobigbed.cwl
│   │   └── ...
│   ├── workflows/
│   │   ├── primary-processing.cwl    # Steps 1-7: SRA → BigWig + BigBed
│   │   ├── target-genes.cwl          # Secondary: peak-TSS overlap
│   │   ├── colocalization.cwl        # Secondary: co-binding analysis
│   │   ├── enrichment.cwl            # Secondary: in silico ChIP
│   │   └── full-pipeline.cwl         # Top-level: primary + secondary
│   └── inputs/
│       ├── hg38.yml                  # Per-genome input templates
│       ├── mm10.yml
│       └── ...
├── containers/
│   ├── Singularity.fastp
│   ├── Singularity.bwa-mem2
│   ├── Singularity.macs3
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

- Pick representative subset: ~10–20 samples per genome
- Cover different experiment types (ChIP-seq, DNase-seq, ATAC-seq)
- Include both high-quality and borderline samples
- Include various antigen classes (histone marks, TFs, chromatin regulators)

### 4.2 Comparison Metrics

- **Peak count**: number of peaks called at each q-value threshold
- **Peak overlap**: Jaccard index and overlap coefficient between v1 and v2 peak sets
- **Exploratory**: visualize differences before setting pass/fail thresholds
- Optionally: BigWig signal correlation (Pearson/Spearman) at later stage

### 4.3 Validation Tooling

- `validate-vs-v1.py`: takes v1 BED + v2 BED, reports peak count, overlap stats, generates comparison plots
- Run as part of the test suite

## Phase 5: Production Deployment & Migration

### 5.1 Incremental Rollout

1. Process the 10K+ remaining unprocessed samples with v2
2. Reprocess a subset of existing 400K samples for validation
3. Full reprocessing if results are satisfactory

### 5.2 Update Infrastructure

- Metadata filtering: rewrite in Python (replace shell scripts)
- Incremental update logic: detect new SRA accessions, queue for processing
- Data distribution: same URL structure for backward compatibility

## Timeline (rough phases, not time estimates)

1. **Benchmarking** — profile v1, evaluate aligners and tool candidates
2. **CWL development** — build tool definitions and workflows
3. **Custom runner** — develop minimal CWL runner (can parallel with #2)
4. **Secondary analyses** — rewrite in Python + CWL
5. **Validation** — compare v2 vs v1 results
6. **Production** — process remaining samples, begin reprocessing

## Open Questions

- [ ] Which job scheduler is on the HPC cluster? (SLURM assumed)
- [ ] Parabricks licensing — is it available, or need to acquire?
- [ ] Custom CWL runner language choice
- [ ] CUT&Tag-specific parameters and peak caller (SEACR vs MACS3)
- [ ] Data storage strategy for v2 outputs (same filesystem? new structure?)
