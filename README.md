# ChIP-Atlas Pipeline v2

Production pipelines for processing 400K+ public epigenomic samples
(ChIP-seq, ATAC-seq, DNase-seq, Bisulfite-seq) behind
[ChIP-Atlas](https://chip-atlas.dbcls.jp).

Each pipeline runs entirely inside a single container with all intermediates
on local NVMe scratch. v2 processes samples 65--90x faster than v1 (from
roughly 1 day per sample down to 15--60 minutes depending on genome size).


## Pipelines

### ChIP-seq / ATAC-seq / DNase-seq

Single-pass piped pipeline: fastp, bwa-mem2, samtools, MACS3, bedtools, UCSC tools.

```
fastp → bwa-mem2 → samtools (collate → fixmate → sort → markdup) → dedup.bam
  ├── bedtools genomecov → bedGraphToBigWig → coverage.bw
  └── MACS3 callpeak (q=1e-5) → filter q=1e-10, q=1e-20 → bedToBigBed
```

**Outputs:** `.bw` (coverage), `.narrowPeak` + `.bb` (peaks at 3 q-value thresholds), fastp QC JSON.

See [`scripts/README.md`](scripts/README.md) for full argument and output documentation.

### Bisulfite-seq (WGBS)

DNMTools-based pipeline: abismal, dnmtools (format/uniq/counts/sym/hmr/hypermr/pmd), samtools, UCSC tools.

```
abismal → dnmtools format → samtools sort → dnmtools uniq → dedup.bam
  → dnmtools counts → counts.tsv
  → dnmtools sym → parallel: hmr + hypermr + pmd + BigWig
```

**Outputs:** `.methyl.bw` + `.cover.bw` (methylation/coverage), `.hmr.bed`, `.hypermr.bed`, `.pmd.bed`, alignment stats.

See [`scripts/README.md`](scripts/README.md) for full argument and output documentation.


## Containers

| Image | Tag | Tools |
|-------|-----|-------|
| `ghcr.io/inutano/chip-atlas-pipeline-v2` | `v1.0.0` | fastp 1.3.1, bwa-mem2 2.3, samtools 1.23.1, MACS3 3.0.4, bedtools 2.31.1, UCSC 482 |
| `ghcr.io/inutano/chip-atlas-pipeline-v2-bs` | `v1.0.0` | DNMTools 1.5.1, samtools 1.22.1, UCSC 482 |

All tool versions are pinned in the Dockerfiles for reproducibility. Built via GitHub Actions and published to GHCR.

```bash
# Build locally
docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 -f containers/Dockerfile containers/
docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.0.0 -f containers/Dockerfile.bs containers/

# Verify
docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 versions.sh
docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.0.0 versions.sh
```


## Quick Start

```bash
# Run a ChIP-seq sample
apptainer exec --bind /data1/tmp:/tmp pipeline-v2.sif \
  bash scripts/pipeline-v2.sh \
    --sample-id SRX12345678 \
    --fastq-fwd reads_1.fastq.gz \
    --fastq-rev reads_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --chrom-sizes /ref/hg38.chrom.sizes \
    --genome-size hs \
    --outdir ./output

# Run a Bisulfite-seq sample
apptainer exec --bind /data1/tmp:/tmp pipeline-v2-bs.sif \
  bash scripts/pipeline-v2-bs.sh \
    --sample-id SRX12345678 \
    --fastq-fwd reads_1.fastq.gz \
    --fastq-rev reads_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --abismal-index /ref/hg38.abismal.idx \
    --chrom-sizes /ref/hg38.chrom.sizes \
    --outdir ./output
```


## Production at Scale

`scripts/production-run.sh` manages batched SLURM submission of 100K+ samples
with progress tracking, disk quota awareness, and automatic retry.

```bash
# Submit a genome batch
bash scripts/production-run.sh submit hg38 samples.tsv --threads 8

# Monitor progress
bash scripts/production-run.sh status hg38

# Retry failed jobs
bash scripts/production-run.sh retry hg38

# Performance summary
bash scripts/production-run.sh summary hg38
```

See [`scripts/README.md`](scripts/README.md) for full options and environment variables.


## Repository Structure

```
containers/           Dockerfiles for both pipelines
scripts/
  pipeline-v2.sh      ChIP-seq / ATAC-seq / DNase-seq pipeline
  pipeline-v2-bs.sh   Bisulfite-seq (WGBS) pipeline
  production-run.sh   SLURM batch job management
  fast-download.sh    FASTQ download with source-aware routing
  prepare-genomes.sh  Reference genome setup (download + index)
  secondary-analysis/ Downstream analysis (colocalization, enrichment, target genes)
docs/                 Design documents, benchmark results, setup guides
data/                 Experiment metadata (gitignored)
```


## Documentation

- [`scripts/README.md`](scripts/README.md) -- Pipeline arguments, outputs, runtime characteristics
- [`docs/v2-plan.md`](docs/v2-plan.md) -- Architecture and design rationale
- [`docs/benchmark-results.md`](docs/benchmark-results.md) -- v1 vs v2 benchmark comparison
- [`docs/bisulfite-seq-investigation.md`](docs/bisulfite-seq-investigation.md) -- BS-seq pipeline design
- [`docs/cluster-setup-guide.md`](docs/cluster-setup-guide.md) -- NIG supercomputer setup
- [`docs/production-lessons-ce11.md`](docs/production-lessons-ce11.md) -- Production lessons learned


## Requirements

- A container runtime: Apptainer/Singularity or Docker
- For production: SLURM cluster with NVMe local scratch
- For BS-seq: abismal index (built with `dnmtools abismalidx`)


## License

MIT
