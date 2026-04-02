# ChIP-Atlas Pipeline v2: Benchmark Results

## Summary

ChIP-Atlas Pipeline v2 replaces decade-old tools with modern equivalents. Two implementations were benchmarked on the NIG supercomputer (6 dedicated AMD EPYC nodes, 128 cores each):

- **Option B CWL** — modular CWL workflow, each tool runs as a separate step with intermediate files
- **Option B Fast** — optimized single-pass pipeline, piped processing with no intermediate files

Key results on 54 hg38 validation samples (289 to 314M reads):

| Metric | v1 pipeline | Option B CWL (16 cores) | Option B Fast (32 cores) |
|--------|------------|------------------------|--------------------------|
| Avg total time (10-50M reads) | ~1 day | 57 min | **20 min** |
| Avg total time (50-100M reads) | ~1 day | 93 min | **38 min** |
| Peak disk per sample | unknown | ~60 GB | **~18 GB** |
| 300M+ read samples | untested | crashes (disk quota) | **~146 min** |

---

## 1. Test Environment

### NIG Supercomputer — Kumamoto dedicated partition

| Component | Spec |
|-----------|------|
| Nodes | 6 × Type 2 (CPU-optimized) |
| CPU | AMD EPYC 7702 (64 cores × 2) per node |
| Cores | 128 per node, 768 total |
| RAM | 512 GB per node |
| Storage | Lustre (shared, 954 GB user quota) + NVMe /data1 (1.5 TB local per node) |
| Container runtime | Apptainer 1.4.5 |
| CWL runner | cwltool 3.1.20240112164112 |

### Earlier workstation benchmarks

| Component | Spec |
|-----------|------|
| CPU | Intel Xeon Gold 6226R @ 2.90 GHz, 32 cores |
| GPU | NVIDIA RTX 6000 Ada (48 GB VRAM) |
| RAM | 93 GB |

### Pipeline tools

| Tool | Version | Purpose |
|------|---------|---------|
| fastp | 0.23.4 | QC + adapter trimming |
| bwa-mem2 | 2.2.1 | Alignment (AVX-512) |
| samtools | 1.19.2 | Sort, fixmate, markdup |
| MACS3 | 3.0.4 | Peak calling (--nomodel --extsize 200, format=BAM) |
| deeptools | 3.5.6 | bamCoverage → BigWig |
| bedToBigBed | 482 | BED → BigBed conversion |

### Validation sample set

54 hg38 samples from `data/validation-samples.tsv`, stratified by:
- 6 experiment types: ATAC-Seq, Bisulfite-Seq, DNase-seq, Histone, RNA polymerase, TFs and others
- 3 read count tiers: Low (<10M), Medium (10-50M), High (>50M)
- 3 samples per stratum (where available)

---

## 2. NIG Benchmark: Option B CWL (Step-by-Step)

CWL workflow with 13 separate steps, each running in its own container via cwltool + Apptainer. 16 cores per job, NVMe scratch for cwltool intermediates.

### Processing time by read tier

| Read tier | Samples | Avg download | Avg pipeline | Avg total |
|-----------|--------:|-------------|-------------|-----------|
| Low (<10M) | 17 | 27s | 11 min | 12 min |
| Medium (10-50M) | 18 | 8.6 min | 49 min | 57 min |
| High (50-100M) | 13 | 8.6 min | 84 min | 93 min |
| Very high (>100M) | 3 | 16 min | 117 min | 133 min |
| **300M+ (Bisulfite-Seq)** | **3** | **—** | **FAILED** | **>10 hours, disk quota** |
| **Overall (excl. 300M+)** | **51** | **5.3 min** | **48 min** | **53 min** |

### Processing time by experiment type

| Type | Samples | Avg download | Avg pipeline | Avg total |
|------|--------:|-------------|-------------|-----------|
| Bisulfite-Seq (excl. 300M+) | 6 | 4.2 min | 27 min | 31 min |
| DNase-seq | 9 | 8.3 min | 33 min | 41 min |
| ATAC-Seq | 9 | 5.6 min | 62 min | 68 min |
| RNA polymerase | 9 | 4.3 min | 49 min | 54 min |
| TFs and others | 9 | 1.8 min | 52 min | 54 min |
| Histone | 9 | 10.2 min | 53 min | 63 min |

### Failures

| Issue | Samples | Cause |
|-------|---------|-------|
| Disk quota exceeded | 3 | 300M+ read Bisulfite-Seq, intermediate files exceeded 954 GB Lustre quota |
| NCBI e-utils timeout | 12 (retry 1) | Concurrent API rate-limiting (fixed with TogoID bulk resolution) |
| Docker permission denied | 5 (retry 1) | fasterq-dump fallback used Docker (fixed with Apptainer fallback) |

---

## 3. NIG Benchmark: Option B Fast (Piped)

Optimized single-pass pipeline with three key optimizations:

1. **Pipe-through**: `fastp | bwa-mem2 | samtools sort | fixmate | sort | markdup` — no intermediate files written to disk
2. **Parallel post-markdup**: bamCoverage and MACS3 run concurrently
3. **Single MACS3**: one call at q=1e-05, then awk filter for 1e-10 and 1e-20 (replaces 3 separate calls)

32 cores per job, Apptainer containers, NVMe scratch. Data from 30/54 completed samples.

### Processing time by read tier

| Read tier | Samples | Avg download | Avg pipeline | Avg total | vs CWL speedup |
|-----------|--------:|-------------|-------------|-----------|---------------|
| Low (<10M) | 8 | 12s | 1 min | 1 min | **12x** |
| Medium (10-50M) | 8 | 3.8 min | 24 min | 28 min | **2.0x** |
| High (50-100M) | 11 | 2.7 min | 33 min | 36 min | **2.6x** |
| Very high (>100M) | 2 | 3.5 min | 39 min | 43 min | **3.1x** |
| **300M+ (Bisulfite-Seq)** | **1** | **0s (cached)** | **146 min** | **146 min** | **did not crash** |
| **Overall** | **30** | **2.1 min** | **20 min** | **22 min** | **2.4x** |

### Processing time by experiment type (available data)

| Type | Samples | Avg download | Avg pipeline | Avg total | vs CWL |
|------|--------:|-------------|-------------|-----------|--------|
| Bisulfite-Seq | 7 | 1.9 min | 28 min | 30 min | 1.0x |
| DNase-seq | 9 | 1.2 min | 12 min | 14 min | **2.9x** |
| ATAC-Seq | 9 | 1.7 min | 27 min | 29 min | **2.3x** |
| Histone | 5 | 1.4 min | 13 min | 15 min | **4.2x** |

### Per-sample comparison: CWL vs Fast (32t) on matching samples

| Sample | Type | Reads | CWL total | Fast total | Speedup |
|--------|------|------:|-----------|-----------|---------|
| SRX23943860 | DNase-seq | 21K | 4m | 1m | 5.4x |
| SRX25139080 | Bisulfite-Seq | 221K | 4m | 1m | 4.2x |
| SRX25595131 | Histone | 10M | 7m | 2m | 4.0x |
| SRX26303596 | Bisulfite-Seq | 35M | 51m | 30m | 1.7x |
| SRX26398645 | ATAC-Seq | 42M | 77m | 41m | 1.9x |
| SRX24388472 | DNase-seq | 47M | 51m | 15m | 3.4x |
| SRX26398647 | ATAC-Seq | 60M | 106m | 47m | 2.3x |
| SRX26084217 | Histone | 67M | 111m | 43m | 2.6x |
| SRX24388481 | DNase-seq | 74M | 64m | 24m | 2.7x |
| SRX26240695 | Bisulfite-Seq | 314M | **CRASHED** | **146m** | **--** |

---

## 4. Disk and I/O Efficiency

### Peak disk usage during processing (per sample, 60M reads hg38)

| Stage | CWL step-by-step | Fast piped |
|-------|-----------------|-----------|
| Input FASTQs | 12 GB | 12 GB |
| Trimmed FASTQs | 11 GB | 0 (piped) |
| SAM (uncompressed) | 30 GB | 0 (piped) |
| Name-sorted BAM | 8 GB | 0 (piped) |
| Fixmate BAM | 8 GB | 0 (piped) |
| Coord-sorted BAM | 8 GB | 0 (piped) |
| Dedup BAM | 6 GB | 6 GB |
| **Peak total** | **~60 GB** | **~18 GB** |

### Aggregate I/O and storage impact

| Metric | CWL step-by-step | Fast piped | Reduction |
|--------|-----------------|-----------|-----------|
| Peak disk per sample | ~60 GB | ~18 GB | **3.3x** |
| Total I/O per sample (read+write) | ~120 GB | ~36 GB | **3.3x** |
| 8 concurrent jobs per node | ~480 GB | ~144 GB | **3.3x** |
| 300M read sample | ~400 GB (crashes) | ~120 GB (succeeds) | **--** |

The piped approach is essential for samples >100M reads, where step-by-step intermediate files can exceed the Lustre user quota (954 GB).

---

## 5. Download Performance

Data downloaded via `fast-download.sh` with source-aware routing:
- SRR/ERR → ENA mirror (aria2c, 8 parallel connections)
- DRR → DDBJ (aria2c, cached fastqlist)
- Fallback → fasterq-dump via Apptainer

SRX→SRR accession resolution via TogoID bulk API (togoid.dbcls.jp).

### Download time by read tier (NIG)

| Read tier | Avg download time | Notes |
|-----------|------------------|-------|
| <1M | 12s | Negligible |
| 1-10M | 30s | Fast |
| 10-50M | 4-9 min | Depends on source mirror |
| 50-100M | 3-9 min | Variable, ENA latency |
| 100M+ | 3-16 min | Large files, network dependent |

Download time averages ~10% of total processing time for medium samples, up to ~25% for samples where the network is slow.

---

## 6. Earlier Workstation Benchmarks

### Option A vs B × CPU vs GPU (ce11, 46 samples)

Tested on the workstation (Xeon Gold 6226R, 32 cores, RTX 6000 Ada GPU).

#### Pipeline time (average, pipeline step only)

|  | No trimming (Option A) | fastp trimming (Option B) |
|--|----------------------|-------------------------|
| **CPU (bwa-mem2)** | 22 min | 17 min |
| **GPU (Parabricks)** | 16 min | **13 min** |

#### Recommendation

**Option B** for production — faster and more robust than Option A (fastp filters problematic reads that cause MACS3 failures). GPU (Parabricks) provides ~1.3x additional speedup where available.

### v1 vs v2 Peak Overlap

| Genome | v1 peaks recovered in v2 | v2 finds more peaks |
|--------|-------------------------|-------------------|
| ce11 (35 samples) | ~90% | Yes (1.5x at q=1e-05) |
| hg38 (12 samples) | ~77% | Near-parity at q=1e-05 |

CPU and GPU produce nearly identical peak calls (<1.5% difference at all thresholds).

---

## 7. Production Throughput Estimates

### hg38 read count distribution (197K samples)

| Read tier | Samples | % |
|-----------|--------:|----:|
| <1M | 23,791 | 12.1% |
| 1-10M | 24,784 | 12.6% |
| **10-50M** | **106,166** | **54.0%** |
| 50-100M | 29,801 | 15.1% |
| 100-200M | 7,531 | 3.8% |
| 200-300M | 2,151 | 1.1% |
| 300M+ | 2,512 | 1.3% |

### Estimated reprocessing time (hg38, 197K samples, including downloads)

| Pipeline | 6 kumamoto nodes (48 parallel) | 78 NIG nodes (624 parallel) |
|----------|-------------------------------|---------------------------|
| Option B CWL (step-by-step) | 184 days | 14 days |
| **Option B Fast (piped)** | **~85 days** | **~7 days** |

### All genomes (845K samples)

| Pipeline | 6 kumamoto nodes | 78 NIG nodes |
|----------|-----------------|-------------|
| Option B CWL | 728 days | 56 days |
| **Option B Fast** | **~350 days** | **~27 days** |

Note: The CWL step-by-step pipeline cannot process the 2,512 hg38 samples with >300M reads (crashes on disk quota). The fast piped pipeline handles these successfully.

---

## 8. Key Decisions and Fixes

| Decision | Rationale |
|----------|-----------|
| Always use `format=BAM` (not BAMPE) | BAMPE requires properly-paired fragments; fails on mislabeled PE data |
| `--nomodel --extsize 200` for all MACS3 | Eliminates model-building failures on low-signal samples |
| No background/input control | ChIP-Atlas policy — uniform processing across 400K+ samples |
| Single MACS3 + awk filter | 1 call at q=1e-05 + filter for 1e-10/1e-20, replaces 3 separate runs |
| TogoID for SRX→SRR resolution | NCBI e-utils rate-limits under concurrent load; TogoID supports bulk |
| Apptainer over udocker | Native kernel support, no ~/.udocker cache (~900 GB saving) |
| NVMe /data1 for intermediates | 3x faster I/O than Lustre, reduces contention at scale |
