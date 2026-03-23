# ChIP-Atlas Pipeline v2: Cluster Setup & Benchmark Guide

This guide describes how to replicate the v2 pipeline benchmarking on a shared HPC cluster.

## Prerequisites

### Software

| Software | Purpose | Install |
|----------|---------|---------|
| Singularity/Apptainer | Container runtime (clusters typically don't allow Docker) | Module or admin install |
| cwltool | CWL workflow runner | `pip install cwltool` |
| aria2c | Fast multi-connection downloader | `apt install aria2` or `conda install -c conda-forge aria2` |
| Python 3.8+ | For cwltool and scripts | Usually available on clusters |
| git | Clone repository | Usually available |

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU nodes | 1 | 10 (for parallel sample processing) |
| RAM per node | 32 GB | 64+ GB (BWA-MEM2 indexing needs ~60GB for mammalian genomes) |
| GPU node | 1 × NVIDIA V100/A100/H100 | For Parabricks variant |
| Storage | 500 GB | 2+ TB (genome indexes ~50GB total, FASTQs are downloaded and cleaned per sample) |

## Step 1: Clone Repository

```bash
git clone https://github.com/inutano/chip-atlas-pipeline-v2.git
cd chip-atlas-pipeline-v2
```

## Step 2: Install cwltool

```bash
pip install cwltool
cwltool --version
```

For Singularity-based execution, cwltool uses `--singularity` flag instead of Docker:
```bash
cwltool --singularity workflow.cwl input.yml
```

## Step 3: Install aria2c

```bash
# Via package manager
apt install aria2  # or module load aria2, or conda install -c conda-forge aria2

# Verify
aria2c --version
```

## Step 4: Prepare Genome References

Set a base directory for test data (use a large shared filesystem):
```bash
export TEST_DIR=/path/to/large/storage/chip-atlas-v2/test-run
```

Edit `scripts/prepare-genomes.sh` — change `BASE_DIR` to your `$TEST_DIR`.

Run genome preparation (downloads references and builds BWA-MEM2 indexes):
```bash
bash scripts/prepare-genomes.sh
```

**Important**: BWA-MEM2 indexing for mammalian genomes (hg38, mm10, rn6) requires ~60GB RAM. Run only one mammalian index at a time. The script processes genomes sequentially: ce11 → dm6 → rn6 → hg38.

This creates for each genome:
- `{genome}.fa` — reference FASTA
- `{genome}.fa.{0123,amb,ann,bwt.2bit.64,pac}` — BWA-MEM2 index files
- `{genome}.fa.fai` — FASTA index
- `chrom.sizes` — chromosome sizes for BigWig/BigBed conversion

### Genome Sizes for MACS3

| Genome | MACS3 `-g` value |
|--------|-----------------|
| hg38 | `hs` |
| mm10 | `mm` |
| rn6 | `2.87e9` |
| dm6 | `dm` |
| ce11 | `ce` |
| sacCer3 | `1.2e7` |

## Step 5: Download DDBJ fastqlist Cache (for DRR accessions)

```bash
mkdir -p $TEST_DIR/../cache
curl -o $TEST_DIR/../cache/ddbj-fastqlist.tsv \
  https://ddbj.nig.ac.jp/public/ddbj_database/dra/meta/list/fastqlist
```

Edit `scripts/fast-download.sh` — update the `FASTQLIST` path to match your cache location.

## Step 6: Adjust Paths in Benchmark Scripts

The following scripts need path updates:

### `scripts/benchmark-pipeline.sh`
```bash
TEST_DIR="/path/to/your/storage/chip-atlas-v2/test-run"  # line ~11
```

### `scripts/benchmark-nomodel.sh`
```bash
TEST_DIR="/path/to/your/storage/chip-atlas-v2/test-run"  # line ~10
```

### `scripts/benchmark-parabricks.sh`
```bash
TEST_DIR="/path/to/your/storage/chip-atlas-v2/test-run"  # line ~10
```

## Step 7: Singularity vs Docker

On HPC clusters, replace Docker with Singularity. cwltool supports this natively:

```bash
# Instead of:
cwltool --outdir ./output workflow.cwl input.yml

# Use:
cwltool --singularity --outdir ./output workflow.cwl input.yml
```

To update the benchmark scripts, add `--singularity` to all `cwltool` invocations. Search for `cwltool --outdir` and change to `cwltool --singularity --outdir`.

Singularity will automatically pull and convert Docker images from the `dockerPull` hints in the CWL files on first run. Images are cached in `~/.singularity/cache/` by default.

### Pre-pull Images (Optional)

To avoid pull delays during benchmarking:
```bash
singularity pull docker://quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8
singularity pull docker://quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1
singularity pull docker://quay.io/biocontainers/bedtools:2.31.1--hf5e1c6e_2
singularity pull docker://quay.io/biocontainers/macs3:3.0.4--py312h71493bf_0
singularity pull docker://quay.io/biocontainers/ucsc-bedgraphtobigwig:482--hdc0a859_0
singularity pull docker://quay.io/biocontainers/ucsc-bedtobigbed:482--hdc0a859_0
singularity pull docker://quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0
# For Parabricks (GPU node only):
singularity pull docker://nvcr.io/nvidia/clara/clara-parabricks:4.3.1-1
```

## Step 8: Run Benchmarks

### Validation Sample Set

The 301 validation samples are in `data/validation-samples.tsv`. The selection script can regenerate them:
```bash
# Download latest metadata
curl -o data/experimentList.tab https://chip-atlas.dbcls.jp/data/metadata/experimentList.tab
# Re-select samples
python3 scripts/select-validation-samples.py data/experimentList.tab -o data/validation-samples.tsv
```

### Available Workflows

| Workflow | Description | File |
|----------|-------------|------|
| Option A (default) | CPU pipeline, MACS3 with model building | `cwl/workflows/option-a.cwl` |
| Option A (nomodel) | CPU pipeline, MACS3 with `--nomodel --extsize 200` | `cwl/workflows/option-a-nomodel.cwl` |
| Option A (Parabricks) | GPU pipeline, fq2bam replaces align+sort+markdup | `cwl/workflows/option-a-parabricks.cwl` |

### Run CPU Benchmark (all samples, sequential)

```bash
bash scripts/benchmark-pipeline.sh
# Results: data/benchmark-timing.tsv
```

### Run nomodel Benchmark (ce11 only)

```bash
bash scripts/benchmark-nomodel.sh
# Results: data/benchmark-timing-nomodel.tsv
```

### Run Parabricks Benchmark (GPU node, ce11)

Requires BWA (not BWA-MEM2) index for Parabricks:
```bash
# Build BWA index in a subdirectory
mkdir -p $TEST_DIR/ce11/bwa-index
cp $TEST_DIR/ce11/ce11.fa $TEST_DIR/ce11/bwa-index/
bwa index $TEST_DIR/ce11/bwa-index/ce11.fa
samtools faidx $TEST_DIR/ce11/bwa-index/ce11.fa
```

Then run:
```bash
bash scripts/benchmark-parabricks.sh ce11
# Results: data/benchmark-timing-parabricks.tsv
```

### Parallel Processing on Multiple Nodes

The benchmark scripts process samples sequentially. For parallel execution on a cluster, you can submit each sample as a separate SLURM job:

```bash
#!/bin/bash
# submit-benchmark-jobs.sh — Submit one SLURM job per sample
# Usage: bash submit-benchmark-jobs.sh <genome> <workflow.cwl>

GENOME="$1"
WORKFLOW="$2"
SAMPLES_TSV="data/validation-samples.tsv"
TEST_DIR="/path/to/storage/chip-atlas-v2/test-run"

tail -n +2 "$SAMPLES_TSV" | awk -F'\t' -v g="$GENOME" '$2==g {print $1}' | while read acc; do
  sbatch --job-name="ca-${acc}" \
         --cpus-per-task=8 \
         --mem=32G \
         --time=4:00:00 \
         --output="logs/${acc}.log" \
         --wrap="cwltool --singularity --outdir ${TEST_DIR}/${GENOME}/results/${acc} ${WORKFLOW} ${TEST_DIR}/${GENOME}/work/${acc}/input.yml"
done
```

You'll need to generate input YAML files for each sample first — see the benchmark scripts for the YAML template.

## Step 9: Compare Results

### Timing Data

All timing logs are TSV with columns:
```
accession  genome  experiment_type  num_reads  download_sec  pipeline_sec  total_sec  timestamp
```

### Peak Comparison (nomodel vs default)

For samples processed by both default and nomodel workflows:
```bash
# Compare peak counts
for acc in $(comm -12 <(tail -n+2 data/benchmark-timing.tsv | grep -v FAILED | cut -f1 | sort) \
                      <(tail -n+2 data/benchmark-timing-nomodel.tsv | grep -v FAILED | cut -f1 | sort)); do
  default=$(wc -l < $TEST_DIR/ce11/results/$acc/${acc}.05_peaks.narrowPeak 2>/dev/null || echo 0)
  nomodel=$(wc -l < $TEST_DIR/ce11/results-nomodel/$acc/${acc}.05_peaks.narrowPeak 2>/dev/null || echo 0)
  echo "$acc  default=$default  nomodel=$nomodel"
done
```

## Current Status (as of 2026-03-23)

### Completed
- All 6 genome indexes built (sacCer3, ce11, dm6, mm10, rn6, hg38)
- ce11 CPU benchmark: 46 samples (34 OK, 12 failed)
- ce11 GPU (Parabricks) benchmark: 21 samples (21 OK)
- ce11 nomodel benchmark: in progress
- dm6 CPU benchmark: partially done (5 samples)
- sacCer3 tested end-to-end (both CPU and GPU)

### Key Findings
- v2 pipeline averages ~56 min/sample vs v1's ~1 day (ce11 data)
- Parabricks GPU gives ~1.4x speedup on pipeline step
- aria2c + ENA download is 2.5x faster than fasterq-dump
- `--nomodel` eliminates MACS3 model-building failures (0 failures vs 6 with default)
- bwa-mem2 and Parabricks produce nearly identical peak calls (±1 peak)

### Known Issues
- Single-end FASTQ naming: `fasterq-dump --split-files` produces `SRR.fastq` (no `_1`), fixed in benchmark scripts
- MACS3 model building fails on low-signal samples without `--nomodel`
- BWA-MEM2 indexing for mammalian genomes needs ~60GB RAM — run one at a time

## Important Policy

**No background/input control for peak calling.** ChIP-Atlas calls peaks without control data. MACS3 is always run without `-c` flag. Users filter by q-value thresholds (1e-05, 1e-10, 1e-20).
