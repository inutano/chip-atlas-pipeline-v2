# ChIP-Atlas Pipeline v2: Scripts

Production pipelines for processing ChIP-seq, ATAC-seq, DNase-seq, and Bisulfite-seq data. Each pipeline runs entirely inside a single container with all intermediates on local NVMe scratch — only final outputs are written to shared storage.

## Pipelines

### `pipeline-v2.sh` — ChIP-seq / ATAC-seq / DNase-seq

Single-pass piped pipeline for chromatin profiling assays.

**Container:** `ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0`

| Tool | Version | Purpose |
|------|---------|---------|
| fastp | 1.3.1 | Adapter trimming, QC |
| bwa-mem2 | 2.3 | Short-read alignment |
| samtools | 1.23.1 | collate, fixmate, sort, markdup (deduplication) |
| MACS3 | 3.0.4 | Peak calling |
| bedtools | 2.31.1 | Genome coverage (BedGraph) |
| bedGraphToBigWig | 482 (UCSC) | BedGraph to BigWig conversion |
| bedToBigBed | 482 (UCSC) | BED to BigBed conversion |

**Processing steps:**

```
Step 1 (piped):  fastp → bwa-mem2 → samtools collate → fixmate → sort → markdup → dedup.bam
Step 2 (parallel):
  ├── bedtools genomecov → bedGraphToBigWig → coverage.bw
  └── MACS3 callpeak (q=1e-5) → filter q=1e-10, q=1e-20
Step 3:  narrowPeak → bedToBigBed → .bb (×3 thresholds)
```

**Arguments:**

| Flag | Required | Description |
|------|----------|-------------|
| `--sample-id` | yes | Experiment accession (e.g. SRX12345678) |
| `--fastq-fwd` | yes | Forward reads (FASTQ or FASTQ.gz) |
| `--fastq-rev` | no | Reverse reads (omit for single-end) |
| `--genome-fasta` | yes | Reference genome FASTA (with bwa-mem2 index) |
| `--chrom-sizes` | yes | Chromosome sizes file (tab: chrom, size) |
| `--genome-size` | yes | MACS3 genome size (`hs`, `mm`, `ce`, `dm`, or integer) |
| `--outdir` | yes | Output directory |
| `--threads` | no | CPU threads (default: 8) |

**Outputs:**

| File | Description |
|------|-------------|
| `{id}.bw` | Coverage BigWig (single-bp resolution) |
| `{id}.05_peaks.narrowPeak` | Peaks at q-value 1e-5 |
| `{id}.10_peaks.narrowPeak` | Peaks at q-value 1e-10 |
| `{id}.20_peaks.narrowPeak` | Peaks at q-value 1e-20 |
| `{id}.05.bb` / `.10.bb` / `.20.bb` | BigBed versions of each peak set |
| `{id}.05_peaks.xls` | MACS3 statistics |
| `{id}_fastp.json` | fastp QC report |

**Example:**

```bash
apptainer exec --bind /data1/tmp:/tmp pipeline-v2.sif \
  bash pipeline-v2.sh \
    --sample-id SRX12345678 \
    --fastq-fwd reads_1.fastq.gz \
    --fastq-rev reads_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --chrom-sizes /ref/hg38.chrom.sizes \
    --genome-size hs \
    --outdir ./output \
    --threads 16
```

---

### `pipeline-v2-bs.sh` — Bisulfite-seq (WGBS)

Whole-genome bisulfite sequencing pipeline using DNMTools.

**Container:** `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.0.0`

| Tool | Version | Purpose |
|------|---------|---------|
| abismal (DNMTools) | 1.5.1 | Bisulfite-aware alignment |
| dnmtools format | 1.5.1 | Convert abismal BAM to standard format |
| samtools sort | 1.22.1 | Coordinate sort |
| dnmtools uniq | 1.5.1 | PCR duplicate removal |
| dnmtools counts | 1.5.1 | Per-CpG methylation levels |
| dnmtools sym | 1.5.1 | Symmetric CpG merging (for HMR) |
| dnmtools hmr | 1.5.1 | Hypomethylated region calling |
| dnmtools hypermr | 1.5.1 | Hypermethylated region calling |
| dnmtools pmd | 1.5.1 | Partially methylated domain calling |
| bedGraphToBigWig | 482 (UCSC) | BedGraph to BigWig conversion |

**Processing steps:**

```
Step 1 (sequential, intermediates deleted as consumed):
  abismal → dnmtools format → samtools sort → dnmtools uniq → dedup.bam

Step 2:
  dnmtools counts → counts.tsv (CpG sites with coverage > 0)

Step 3 (parallel fan-out after dnmtools sym):
  ├── dnmtools hmr      → hmr.bed
  ├── dnmtools hypermr  → hypermr.bed
  ├── dnmtools pmd      → pmd.bed
  └── sort → awk → bedGraphToBigWig → methyl.bw + cover.bw
```

Step 1 uses file-based intermediates rather than a Unix pipe because `dnmtools format` and `dnmtools uniq` require seekable BAM input (htslib constraint). All intermediates live on local NVMe and are deleted as soon as the next step consumes them.

**Arguments:**

| Flag | Required | Description |
|------|----------|-------------|
| `--sample-id` | yes | Experiment accession (e.g. SRX12345678) |
| `--fastq-fwd` | yes | Forward reads (FASTQ or FASTQ.gz) |
| `--fastq-rev` | no | Reverse reads (omit for single-end) |
| `--genome-fasta` | yes | Reference genome FASTA |
| `--abismal-index` | yes | abismal index file (built with `dnmtools abismalidx`) |
| `--chrom-sizes` | yes | Chromosome sizes file |
| `--outdir` | yes | Output directory |
| `--threads` | no | CPU threads (default: 16) |

**Outputs:**

| File | Description |
|------|-------------|
| `{id}.methyl.bw` | Per-CpG methylation fraction BigWig (0–1) |
| `{id}.cover.bw` | Per-CpG read coverage BigWig |
| `{id}.hmr.bed` | Hypomethylated regions (CpG islands, promoters) |
| `{id}.hypermr.bed` | Hypermethylated regions |
| `{id}.pmd.bed` | Partially methylated domains |
| `{id}.abismal.stats` | Alignment statistics (YAML) |

**Example:**

```bash
apptainer exec --bind /data1/tmp:/tmp pipeline-v2-bs.sif \
  bash pipeline-v2-bs.sh \
    --sample-id SRX12345678 \
    --fastq-fwd reads_1.fastq.gz \
    --fastq-rev reads_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --abismal-index /ref/hg38.abismal.idx \
    --chrom-sizes /ref/hg38.chrom.sizes \
    --outdir ./output \
    --threads 16
```

---

## Production Management

### `production-run.sh` — Batch job submission on NIG/SLURM

Manages batched SLURM submission of 100K+ samples with progress tracking, disk quota awareness, and automatic retry.

**Subcommands:**

| Command | Description |
|---------|-------------|
| `submit <genome> <samples.tsv>` | Submit a batch of samples to SLURM |
| `status <genome>` | Show progress (done/failed/running counts) |
| `retry <genome>` | Re-submit failed jobs |
| `summary <genome>` | Print per-tier timing summary |

**Key options for `submit`:**

| Flag | Default | Description |
|------|---------|-------------|
| `--batch-size` | 90 | Jobs per submission wave |
| `--max-concurrent` | 90 | Max SLURM jobs queued+running |
| `--threads` | 8 | CPUs per job |
| `--disk-limit-gb` | 800 | Pause when Lustre usage exceeds this |
| `--output-base` | `production-{genome}/results` | Override output directory |
| `--time-limit` | 3h | SLURM time limit per job |
| `--dry-run` | — | Print plan without submitting |

**Sample TSV format** (tab-separated, with header):

```
accession	genome	experiment_type	num_reads
SRX12345678	hg38	TFs and others	25000000
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CHIP_ATLAS_BASE` | `~/chip-atlas-v2` | Base directory for references, containers, production data |
| `SLURM_PARTITION` | `kumamoto-c768` | SLURM partition |
| `SLURM_ACCOUNT` | `kumamoto-group` | SLURM account |

---

## Helpers

### `fast-download.sh` — FASTQ download with source-aware routing

Downloads FASTQs for a given run accession, routing to the fastest mirror based on accession prefix:

- `DRR*` (DDBJ/Japan) → DDBJ first, then ENA fallback
- `ERR*` (ENA/Europe) → ENA first, then fasterq-dump fallback
- `SRR*` (NCBI/US) → ENA first, then fasterq-dump fallback

Uses `aria2c` with parallel connections for HTTP/FTP downloads.

```bash
bash fast-download.sh SRR26425632 ./fastq/
```

### `prepare-genomes.sh` — Reference genome setup

Downloads reference genomes from UCSC/Ensembl, builds FASTA index, chromosome sizes, and bwa-mem2 indexes. Supported genomes: hg38, rn6, dm6, ce11, TAIR10.

```bash
bash prepare-genomes.sh
```

For Bisulfite-seq, abismal indexes must be built separately:

```bash
dnmtools abismalidx <genome.fa> <genome.abismal.idx>
```

---

## Secondary Analysis

Scripts in `secondary-analysis/` implement ChIP-Atlas downstream features that run after the primary pipeline has processed all samples for a genome.

| Script | Description |
|--------|-------------|
| `compute-colocalization.py` | Pairwise colocalization scoring between experiments in the same cell type class |
| `enrichment-analysis.py` | In Silico ChIP: test if user regions are enriched for peaks from specific experiments |
| `generate-antigen-target-json.py` | Aggregate target genes per antigen across experiments |

---

## Containers

Built via GitHub Actions (`.github/workflows/container.yml`) and published to GHCR.

| Container | Dockerfile | Tools |
|-----------|------------|-------|
| `ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0` | `containers/Dockerfile` | fastp 1.3.1, bwa-mem2 2.3, samtools 1.23.1, MACS3 3.0.4, bedtools 2.31.1, UCSC 482 |
| `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.0.0` | `containers/Dockerfile.bs` | DNMTools 1.5.1, samtools 1.22.1, UCSC 482 |

Both containers use `condaforge/mambaforge` as the base image with tools installed from bioconda and conda-forge.

---

## Runtime Characteristics

### ChIP-seq (pipeline-v2.sh)

Tested on NIG kumamoto partition (128-core nodes), ce11 production run (2,693 samples):

| Read tier | Samples | Avg time/sample |
|-----------|--------:|----------------:|
| < 1M | 5 | 0.9 min |
| 1–10M | 504 | 2.0 min |
| 10–50M | 531 | 7.8 min |
| 50M+ | 39 | 24.9 min |

Throughput: ~216 samples/hour across 6 nodes.

### Bisulfite-seq (pipeline-v2-bs.sh)

Tested on local workstation (16 threads), hg38 human cfDNA (SRX22130352, 1M PE reads):

| Step | Time |
|------|-----:|
| abismal alignment | 60s |
| format + sort + uniq | 3s |
| counts (bottleneck) | 107s |
| sym + hmr/hypermr/pmd + BigWig (parallel) | 10s |
| **Total** | **3:00** |

Projected: ~35–40 min per 50M-read hg38 sample.
