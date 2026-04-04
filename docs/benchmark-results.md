# ChIP-Atlas Pipeline v2: Benchmark Results

## Summary

ChIP-Atlas Pipeline v2 replaces decade-old tools (Bowtie2 2.2.2, SAMtools 0.1.19, MACS2 2.1.0) with modern equivalents. The production pipeline ("Option B Fast") uses piped processing, single-bp BigWig resolution, and natural MACS3 model building (no --nomodel).

### Pipeline configurations benchmarked

| Pipeline | Cores/job | Memory/job | Container | Implementation |
|----------|----------|-----------|-----------|----------------|
| **v1** (baseline) | **4** | **16 GB** | None (bare metal) | Shell scripts (Bowtie2, MACS2) |
| **v2 Option B CWL** | **16** | **128 GB** | Apptainer (per step) | cwltool + 13 CWL steps |
| **v2 Option B Fast** | **4 / 8 / 16 / 32** | **varies** | Apptainer (per tool in pipe) | Shell script, piped |

### Key results: Option B Fast with optimal 8-core configuration

| Read tier | v1 (4c) | Fast (8c) | Fast (16c) | Speedup (v1→8c) |
|-----------|--------:|----------:|-----------:|----------------:|
| <1M | 12 min | 13 min | 6 min | 0.9x |
| 1-10M | 25 min | 14 min | 8 min | 1.8x |
| 10-50M | 124 min | 58 min | 27 min | 2.1x |
| 50-100M+ | 166 min | 116 min | 58 min | 1.4x |
| **Overall** | **117 min** | **38 min** | **27 min** | **3.1x** |

### Production throughput per node (128 cores, 512 GB RAM)

| Pipeline | Cores/job | Max RSS | Jobs/node | **Samples/hr/node** |
|----------|----------|--------:|----------:|-------------------:|
| v1 | 4 | 16 GB | 32 | 16.4 |
| **v2 Fast (recommended)** | **8** | **36 GB** | **14** | **22.2** |
| v2 Fast | 16 | 45 GB | 8 | 18.1 |

**v2 Fast 8c delivers 35% higher throughput per node than v1**, while producing single-bp BigWig files and handling 300M+ read samples that v1 cannot.

| Metric | v1 | v2 Fast 8c |
|--------|---:|----------:|
| 6 kumamoto nodes, hg38 197K samples | 84 days | **62 days** |
| Peak disk per sample | unknown | ~18 GB |
| BigWig resolution | single-bp | single-bp |
| 300M+ read support | yes (slow) | yes |

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

CWL workflow with 13 separate steps, each running in its own container via cwltool + Apptainer.

- **Cores per job**: 16
- **Memory per job**: 128 GB (16 cores × 8 GB)
- **Jobs per node**: 8 (128 cores / 16)
- **Scratch**: NVMe /data1 for cwltool intermediates

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

## 3. NIG Benchmark: Option B Fast (Piped, Updated Pipeline)

Production pipeline with all fixes applied:
- **No --nomodel**: MACS3 builds fragment size models naturally
- **binSize=1**: Single basepair BigWig resolution (required for ChIP-Atlas)
- **format=BAM**: Consistent handling of SE/PE samples

Optimizations:
1. **Pipe-through**: `fastp | bwa-mem2 | samtools sort | fixmate | sort | markdup` — no intermediate files
2. **Parallel post-markdup**: bamCoverage (binSize=1) and MACS3 run concurrently
3. **Single MACS3**: one call at q=1e-05, then awk filter for 1e-10 and 1e-20

Apptainer containers, NVMe /data1 scratch.

### Profiling: single sample across core counts (SRX26084085, RNA pol, 20M reads)

| Cores | Step 1 (align pipe) | Step 2 (BigWig + MACS3) | Total | Peak RSS | Core-min | Jobs/node |
|------:|--------------------:|------------------------:|------:|---------:|---------:|----------:|
| 4 | 136 min | 29 min | **165 min** | 32 GB | 660 | 16 |
| **8** | **39 min** | **16 min** | **54 min** | **33 GB** | **432** | **14** |
| 16 | 20 min | 10 min | 30 min | 38 GB | 480 | 8 |
| 32 | 14 min | 6 min | 22 min | 53 GB | 704 | 4 |

Jobs/node = min(128 cores / cores-per-job, 512 GB RAM / peak RSS).

Note: Step 2 (BigWig at binSize=1) takes 10-29 min depending on cores — this is ~30% of total pipeline time. Single-bp resolution is significantly slower than binned BigWig but is required for ChIP-Atlas (users rely on it to inspect read mappings since BAM files are not kept).

### Benchmark matrix: 8c vs 16c on 20 hg38 samples

| Read tier | N (8c) | 8c avg | 8c RSS | N (16c) | 16c avg | 16c RSS |
|-----------|-------:|-------:|-------:|--------:|--------:|--------:|
| <1M | 5 | 13 min | 5 GB | 5 | 6 min | 1 GB |
| 1-10M | 3 | 14 min | 20 GB | 3 | 8 min | 16 GB |
| 10-50M | 6 | 58 min | 31 GB | 7 | 27 min | 34 GB |
| 50-100M+ | 1 | 116 min | 36 GB | 5 | 58 min | 42 GB |
| **Overall** | **15** | **38 min** | | **20** | **27 min** | |

### Memory observations

- **<1M reads**: 1-5 GB — bwa-mem2 index barely loaded before alignment finishes
- **1-10M reads**: 16-20 GB — bwa-mem2 index partially loaded
- **10M+ reads**: 31-45 GB — bwa-mem2 index fully loaded (~20 GB) + samtools sort buffers + bamCoverage
- Memory scales with cores mainly via samtools sort (`-m` per-thread buffers) and bamCoverage parallelism
- **8c peak RSS (36 GB) allows 14 jobs per 512 GB node**; 16c peak (45 GB) allows only 8

---

## 4. Speedup, Core Efficiency, and Throughput

### Speedup vs v1 (by read tier, updated pipeline)

| Read tier | v1 (4c) avg | Fast (8c) avg | Fast (16c) avg | v1→8c | v1→16c |
|-----------|------------:|--------------:|---------------:|------:|-------:|
| <1M | 12 min | 13 min | 6 min | 0.9x | 2.0x |
| 1-10M | 25 min | 14 min | 8 min | 1.8x | 3.1x |
| 10-50M | 124 min | 58 min | 27 min | 2.1x | 4.6x |
| 50-100M+ | 166 min | 116 min | 58 min | 1.4x | 2.9x |
| **Overall** | **117 min** | **38 min** | **27 min** | **3.1x** | **4.3x** |

For very small samples (<1M), v2 8c is slightly slower than v1 4c due to higher overhead (Apptainer container startup, bwa-mem2 index loading). This is acceptable as <1M samples are only 12% of data.

### Core efficiency (minutes × cores per sample)

| Read tier | v1 (4c) | Fast (8c) | Fast (16c) | 8c vs v1 |
|-----------|--------:|----------:|-----------:|---------:|
| <1M | 47 | 100 | 101 | 2.1x more |
| 1-10M | 100 | 112 | 125 | 1.1x more |
| 10-50M | 494 | 462 | 425 | **0.9x (more efficient)** |
| 50-100M+ | 664 | 931 | 930 | 1.4x more |

- At 10-50M reads (**54% of all hg38 samples**), 8c is slightly more core-efficient than v1
- 8c and 16c have nearly identical core efficiency across all tiers

### Production throughput comparison

| Pipeline | Cores/job | Max RSS | Jobs/node (128c, 512GB) | Avg time | **Samples/hr/node** |
|----------|----------|--------:|------------------------:|---------:|-------------------:|
| v1 | 4 | 16 GB | 32 | 117 min | 16.4 |
| **v2 Fast (recommended)** | **8** | **36 GB** | **14** | **38 min** | **22.2** |
| v2 Fast | 16 | 45 GB | 8 | 27 min | 18.1 |
| v2 Fast | 32 | 53 GB | 4 (core-limited) | 22 min | 10.9 |

**v2 Fast 8c: 35% higher throughput than v1 per node.**

### Recommendation

| Goal | Best configuration | Rationale |
|------|-------------------|-----------|
| Fastest per sample | Fast 32t | 26 min avg, handles 300M+ |
| Best throughput (samples/hour) | Fast 16t | More parallel jobs, near-v1 core efficiency |
| Maximum compatibility | CWL 16t | Portable CWL, debuggable per-step |

---

## 5. Disk and I/O Efficiency

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

## 6. Download Performance

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

## 7. Earlier Workstation Benchmarks

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

## 8. Production Throughput Estimates

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

Based on measured throughput: v1 = 16.4 samples/hr/node, v2 Fast 8c = 22.2 samples/hr/node.

| Pipeline | 6 kumamoto nodes | 78 NIG nodes |
|----------|-----------------|-------------|
| v1 (4c, baseline) | 84 days | 6.5 days |
| v2 CWL step-by-step (16c) | 184 days | 14 days |
| **v2 Fast 8c (recommended)** | **62 days** | **4.8 days** |

### All genomes (845K samples, estimated)

| Pipeline | 6 kumamoto nodes | 78 NIG nodes |
|----------|-----------------|-------------|
| v1 | ~360 days | ~28 days |
| **v2 Fast 8c** | **~265 days** | **~20 days** |

### All genomes (845K samples)

| Pipeline | 6 kumamoto nodes | 78 NIG nodes |
|----------|-----------------|-------------|
| Option B CWL | 728 days | 56 days |
| **Option B Fast** | **~350 days** | **~27 days** |

Note: The CWL step-by-step pipeline cannot process the 2,512 hg38 samples with >300M reads (crashes on disk quota). The fast piped pipeline handles these successfully.

---

## 9. v1 vs v2 Per-Sample Comparison (hg38)

Full per-sample comparison using v1 processing logs provided by co-maintainers. Data: `data/benchmark-v1-v2-comparison-hg38.tsv`

### Summary

| Metric | Value |
|--------|-------|
| Samples compared | 54 (hg38 validation set) |
| v1 avg processing time | 123 min |
| v2 CWL avg (excl. 300M+) | 53 min (2.3x faster than v1) |
| **v2 Fast 32t avg** | **22 min (5.6x faster than v1)** |
| Speedup range (v1/Fast) | 1.5x - 35x |

### Per-sample table (sorted by read count)

| Accession | Type | Reads | PE | v1 map% | v1 peaks | v1 min | CWL min | Fast min | v1/Fast |
|-----------|------|------:|---:|--------:|---------:|-------:|--------:|---------:|--------:|
| SRX22536539 | Histone | 289 | 0 | 93.4 | 0 | 2 | . | 1 | 3.4x |
| SRX23943860 | DNase-seq | 21K | 1 | 11.6 | 0 | 2 | 4 | 1 | 2.7x |
| SRX25139082 | Bisulfite-Seq | 123K | 1 | 87.2 | 925 | 26 | . | 1 | 35.0x |
| SRX25139081 | Bisulfite-Seq | 136K | 1 | 86.5 | 1,413 | 25 | 4 | 1 | 27.4x |
| SRX23943859 | DNase-seq | 165K | 1 | 98.5 | 0 | 3 | 4 | 1 | 3.3x |
| SRX23943861 | DNase-seq | 171K | 1 | 96.5 | 0 | 2 | 7 | 1 | 2.8x |
| SRX25139080 | Bisulfite-Seq | 221K | 1 | 91.5 | 1,548 | 23 | 4 | 1 | 23.6x |
| SRX18646733 | RNA pol | 2.1M | 1 | 7.0 | 7 | 3 | 6 | 2 | 1.5x |
| SRX18298170 | RNA pol | 5.0M | 0 | 91.8 | 681 | 8 | 8 | 2 | 3.6x |
| SRX25793268 | ATAC-Seq | 8.0M | 1 | 99.2 | 8,389 | 21 | 13 | 5 | 4.2x |
| SRX26106775 | ATAC-Seq | 8.3M | 1 | 38.0 | 3,316 | 21 | 17 | 4 | 4.8x |
| SRX25595128 | Histone | 8.3M | 0 | 96.1 | 8,023 | 16 | 7 | 1 | 12.9x |
| SRX25793269 | ATAC-Seq | 8.5M | 1 | 99.2 | 12,948 | 19 | 12 | 5 | 3.8x |
| SRX25050178 | TFs | 8.6M | 1 | 90.1 | 2,229 | 58 | 27 | 12 | 4.7x |
| SRX25050179 | TFs | 9.3M | 1 | 88.6 | 1,671 | 61 | 31 | 14 | 4.3x |
| SRX25254554 | TFs | 9.8M | 1 | 98.7 | 28,075 | 40 | 20 | 8 | 4.9x |
| SRX24105763 | RNA pol | 9.9M | 0 | 80.9 | 247 | 11 | 10 | 3 | 3.1x |
| SRX25595131 | Histone | 10.0M | 0 | 96.0 | 8,797 | 17 | 7 | 2 | 9.8x |
| SRX26208417 | TFs | 15.1M | 1 | 98.0 | 533 | 115 | 36 | . | |
| SRX26084085 | RNA pol | 20.2M | 1 | 97.2 | 820 | 71 | 35 | 17 | 4.2x |
| SRX26323825 | TFs | 21.7M | 1 | 97.4 | 14,704 | 111 | 43 | . | |
| SRX26208418 | TFs | 21.9M | 1 | 98.6 | 1,067 | 150 | 57 | . | |
| SRX26084084 | RNA pol | 22.4M | 1 | 97.3 | 514 | 76 | 38 | 18 | 4.2x |
| SRX26208419 | Histone | 23.2M | 1 | 97.4 | 2,006 | 163 | 65 | 24 | 6.8x |
| SRX26268297 | Histone | 25.4M | 1 | 95.2 | 166 | 120 | 66 | 26 | 4.6x |
| SRX26268299 | Histone | 26.4M | 1 | 96.7 | 1,046 | 148 | 47 | 27 | 5.5x |
| SRX24152104 | DNase-seq | 26.9M | 1 | 96.2 | 884 | 100 | 74 | 27 | 3.7x |
| SRX26084083 | RNA pol | 28.9M | 1 | 97.5 | 13,174 | 97 | 46 | 22 | 4.4x |
| SRX26303596 | Bisulfite-Seq | 35.4M | 1 | 97.4 | 135,005 | 101 | 51 | 30 | 3.3x |
| SRX26303597 | Bisulfite-Seq | 40.5M | 1 | 86.2 | 204,551 | 108 | 65 | 32 | 3.3x |
| SRX26398646 | ATAC-Seq | 40.8M | 1 | 50.3 | 570 | 204 | 79 | 43 | 4.8x |
| SRX26398645 | ATAC-Seq | 42.0M | 1 | 53.0 | 605 | 206 | 77 | 41 | 5.1x |
| SRX26303598 | Bisulfite-Seq | 45.7M | 1 | 84.4 | 207,751 | 119 | 63 | 34 | 3.4x |
| SRX26398642 | ATAC-Seq | 46.7M | 1 | 30.1 | 386 | 219 | 80 | 41 | 5.3x |
| SRX24388472 | DNase-seq | 46.7M | 0 | 98.8 | 25,342 | 56 | 51 | 15 | 3.7x |
| SRX24388475 | DNase-seq | 49.7M | 0 | 98.9 | 35,958 | 60 | 54 | 16 | 3.7x |
| SRX26084170 | RNA pol | 51.6M | 1 | 79.3 | 6,896 | 142 | 79 | 38 | 3.7x |
| SRX26159220 | TFs | 52.9M | 1 | 80.3 | 23,306 | 146 | 70 | 29 | 5.0x |
| SRX26159217 | TFs | 53.2M | 1 | 74.3 | 26,443 | 191 | 66 | 28 | 6.9x |
| SRX26398644 | ATAC-Seq | 58.2M | 1 | 34.4 | 608 | 177 | 110 | 46 | 3.8x |
| SRX26398647 | ATAC-Seq | 59.7M | 1 | 38.1 | 627 | 202 | 106 | 46 | 4.3x |
| SRX26084172 | RNA pol | 65.4M | 1 | 79.7 | 595 | 185 | 127 | 49 | 3.8x |
| SRX26084217 | Histone | 67.1M | 1 | 85.1 | 6,921 | 196 | 111 | 43 | 4.5x |
| SRX26159219 | TFs | 67.4M | 1 | 86.6 | 24,982 | 230 | 91 | 39 | 5.9x |
| SRX24388480 | DNase-seq | 68.2M | 0 | 98.1 | 48,096 | 72 | 52 | 22 | 3.3x |
| SRX26084171 | RNA pol | 69.0M | 1 | 82.0 | 11,387 | 194 | 107 | 52 | 3.7x |
| SRX24388482 | DNase-seq | 72.6M | 0 | 98.0 | 51,473 | 86 | 77 | 23 | 3.7x |
| SRX26398643 | ATAC-Seq | 73.2M | 1 | 47.3 | 845 | 253 | 130 | 59 | 4.3x |
| SRX24388481 | DNase-seq | 73.8M | 0 | 98.3 | 60,167 | 84 | 64 | 24 | 3.5x |
| SRX26084218 | Histone | 114.6M | 1 | 85.1 | 35,711 | 258 | 158 | 66 | 3.9x |
| SRX26084219 | Histone | 123.5M | 1 | 85.1 | 36,988 | 272 | 128 | 69 | 3.9x |
| SRX26240693 | Bisulfite-Seq | 306.8M | 1 | 92.0 | 0 | 790 | . | . | |
| SRX26240694 | Bisulfite-Seq | 309.6M | 1 | 91.8 | 0 | 894 | . | . | |
| SRX26240695 | Bisulfite-Seq | 314.1M | 1 | 90.2 | 0 | 822 | . | 146 | 5.6x |

### Notable v1 data quality observations

- **Low mapping rates in ATAC-Seq**: SRX26398642 (30%), SRX26398644 (34%), SRX26106775 (38%) — likely paired-end data aligned as single-end in v1 (Bowtie2)
- **SRX18646733** (RNA pol, 2.1M reads): only 7% mapped — problematic sample in both v1 and v2
- **SRX23943860** (DNase-seq, 21K reads): 11.6% mapped — likely mislabeled or low-quality
- **300M+ Bisulfite-Seq**: v1 found 0 peaks (HyperMR_num=0) despite 90%+ mapping, took 13-15 hours each

---

## 10. Key Decisions and Fixes

| Decision | Rationale |
|----------|-----------|
| Always use `format=BAM` (not BAMPE) | BAMPE requires properly-paired fragments; fails on mislabeled PE data |
| `--nomodel --extsize 200` for all MACS3 | Eliminates model-building failures on low-signal samples |
| No background/input control | ChIP-Atlas policy — uniform processing across 400K+ samples |
| Single MACS3 + awk filter | 1 call at q=1e-05 + filter for 1e-10/1e-20, replaces 3 separate runs |
| TogoID for SRX→SRR resolution | NCBI e-utils rate-limits under concurrent load; TogoID supports bulk |
| Apptainer over udocker | Native kernel support, no ~/.udocker cache (~900 GB saving) |
| NVMe /data1 for intermediates | 3x faster I/O than Lustre, reduces contention at scale |
