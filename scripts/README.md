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
Step 1 (piped) — paired-end:
  fastp → bwa-mem2 -p → collate → fixmate → sort → markdup → dedup.bam

Step 1 (piped) — single-end:
  fastp → bwa-mem2    →                      sort → markdup → dedup.bam

Step 2 (parallel):
  ├── samtools view -c (mapped count) → bedtools genomecov → RPM normalize → bedGraphToBigWig → coverage.bw
  └── MACS3 callpeak -f BAMPE (PE) / -f BAM (SE)  (q=1e-5) → filter q=1e-10, q=1e-20

Step 3:  narrowPeak → bedToBigBed → .bb (×3 thresholds)

Step 4:  collect stats → {id}.stats.tsv
```

**Tool options used in Step 1:**

```bash
# Paired-end
fastp --in1 R1.fq --in2 R2.fq --stdout --json fastp.json --thread 2
  # --stdout          Stream passing-filters reads to STDOUT as interleaved FASTQ (PE)
  # --json            Write QC report in JSON format
  # --thread          Number of worker threads (2 is enough; fastp is I/O-bound)

| bwa-mem2 mem -t $THREADS -R '@RG\tID:SRX\tSM:SRX\tPL:ILLUMINA' -p genome.fa -
  # -t INT            Number of threads
  # -R STR            Read group header line (required for downstream tools)
  # -p                Smart pairing: treat interleaved FASTQ from stdin as paired-end
  # -                 Read input from stdin

| samtools collate -O -T $WORK/collate -
  # -O                Output to stdout (for piping)
  # -T PREFIX         Write temporary files to PREFIX.nnnn.bam (on NVMe scratch)
  # Collates reads by name so fixmate can find mate pairs

| samtools fixmate -m - -
  # -m                Add mate score tag (ms:i:) used by markdup to pick best read
  # - -               Read from stdin, write to stdout

| samtools sort -@ $SORT_T -m $SORT_MEM -T $WORK/sort -
  # -@ INT            Number of additional threads for compression (2–3)
  # -m INT            Max memory per thread for sorting (default: 768M, we use 4G)
  # -T PREFIX         Write temporary files to PREFIX.nnnn.bam (on NVMe scratch)
  # Coordinate-sorts the name-collated BAM

| samtools markdup -r - dedup.bam
  # -r                Remove duplicate reads (not just flag them)
  # Reads the ms:i: mate score tag from fixmate to resolve duplicates

# Single-end (collate and fixmate are skipped — not needed without mate pairs)
fastp --in1 R1.fq --stdout --json fastp.json --thread 2

| bwa-mem2 mem -t $THREADS -R '@RG\tID:SRX\tSM:SRX\tPL:ILLUMINA' genome.fa -
  # No -p flag (not interleaved; single FASTQ on stdin)

| samtools sort -@ $SORT_T -m $SORT_MEM -T $WORK/sort -

| samtools markdup -r - dedup.bam
```

**Tool options used in Step 2:**

```bash
# Count mapped reads for RPM normalization
MAPPED=$(samtools view -c -F 4 dedup.bam)
  # -c                 Count reads (output number only)
  # -F 4               Exclude unmapped reads (flag 0x4)

bedtools genomecov -bg -ibam dedup.bam | awk '{...RPM normalize...}' > coverage.bedGraph
  # -bg               Report depth in BedGraph format (chrom, start, end, depth)
  # -ibam             Input is a coordinate-sorted BAM file
  # awk normalizes each depth value to RPM: depth * 1,000,000 / total_mapped_reads
  # Output values are floats (e.g., 0.1147 for depth=1 at 8.7M mapped reads)

bedGraphToBigWig coverage.bedGraph chrom.sizes output.bw
  # Positional args: input BedGraph, chrom sizes, output BigWig
  # BedGraph must be sorted by chrom then start position

macs3 callpeak -t dedup.bam -n $SAMPLE -g $GENOME_SIZE -q 1e-05 -f BAMPE --outdir $WORK  # PE
macs3 callpeak -t dedup.bam -n $SAMPLE -g $GENOME_SIZE -q 1e-05 -f BAM  --outdir $WORK  # SE
  # -t FILE           Treatment file (input BAM)
  # -n NAME           Experiment name (used as output filename prefix)
  # -g SIZE           Effective genome size: 'hs' (2.7e9), 'mm' (1.87e9),
  #                   'ce' (9e7), 'dm' (1.2e8), or an integer
  # -q FLOAT          Minimum FDR (q-value) cutoff for peak detection (default: 0.05)
  #                   We use 1e-05 as the most permissive threshold, then filter
  #                   narrowPeak column 9 (-log10 q-value) for 1e-10 and 1e-20
  # -f FORMAT         BAMPE for paired-end: uses actual fragment lengths from mate
  #                   pairs rather than estimating a shift model, giving more accurate
  #                   peak boundaries for PE data.
  #                   BAM for single-end: reads are extended by the estimated fragment
  #                   size using MACS3's shifting model.
  # --outdir DIR      Output directory
  # Note: MACS3 uses default --nomodel=false, so it builds a shifting model.
  #       If model building fails (low-signal samples), no peaks are produced.
```

**Tool options used in Step 3:**

```bash
# Filter peaks by -log10(q-value) in narrowPeak column 9
awk '$9 >= 10' q05_peaks.narrowPeak > q10_peaks.narrowPeak   # q-value ≤ 1e-10
awk '$9 >= 20' q05_peaks.narrowPeak > q20_peaks.narrowPeak   # q-value ≤ 1e-20

bedToBigBed peaks.bed chrom.sizes output.bb
  # Positional args: input BED (columns 1–4, sorted), chrom sizes, output BigBed
```

**Arguments:**

| Flag | Required | Description |
|------|----------|-------------|
| `--sample-id` | yes | Experiment accession (e.g. SRX12345678) |
| `--fastq-fwd` | yes | Forward reads (FASTQ or FASTQ.gz) |
| `--fastq-rev` | no | Reverse reads (omit for single-end) |
| `--genome-fasta` | yes | Reference genome FASTA (with bwa-mem2 index files in same dir) |
| `--chrom-sizes` | yes | Chromosome sizes file (tab: chrom, size) |
| `--genome-size` | yes | MACS3 genome size (`hs`, `mm`, `ce`, `dm`, or integer) |
| `--outdir` | yes | Output directory |
| `--threads` | no | CPU threads (default: 8) |

**Thread allocation** (for `--threads 8`):

| Stage | Threads | Rationale |
|-------|--------:|-----------|
| fastp | 2 | I/O-bound; more threads don't help |
| bwa-mem2 | 7 | CPU bottleneck; gets `threads - 1` |
| samtools sort | 2–3 | Compression threads for merge |
| samtools collate/fixmate/markdup | 1 | I/O-bound, single-threaded is fine |
| bedtools / MACS3 / BigWig | 1 | Single-threaded tools |

**Outputs:**

| File | Description |
|------|-------------|
| `{id}.bw` | Coverage BigWig (RPM-normalized, single-bp resolution) |
| `{id}.05_peaks.narrowPeak` | Peaks at q-value 1e-5 |
| `{id}.10_peaks.narrowPeak` | Peaks at q-value 1e-10 |
| `{id}.20_peaks.narrowPeak` | Peaks at q-value 1e-20 |
| `{id}.05.bb` / `.10.bb` / `.20.bb` | BigBed versions of each peak set |
| `{id}.05_peaks.xls` | MACS3 statistics |
| `{id}_fastp.json` | fastp QC report |
| `{id}.stats.tsv` | 15-column v1-compatible stats (sample ID, SE/PE flag, FASTQ size (PE: sum of fwd+rev), reads before/after filtering, mapping rate, duplication rate, dedup BAM size, BedGraph size, BigWig size, peak counts at q05/10/20, elapsed minutes) |

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

**Container:** `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0`

| Tool | Version | Purpose |
|------|---------|---------|
| fastp | 1.3.1 | Adapter trimming, QC (Step 0, via named pipes) |
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
Step 0 (streaming via named pipes):
  fastp → FIFO(s) → (consumed by Step 1)

Step 1 (sequential, intermediates deleted as consumed):
  abismal (reads from FIFOs) → dnmtools format → samtools sort → dnmtools uniq → dedup.bam

Step 2:
  dnmtools counts → counts.tsv (CpG sites with coverage > 0)

Step 3 (parallel fan-out after dnmtools sym):
  ├── dnmtools hmr      → hmr.bed
  ├── dnmtools hypermr  → hypermr.bed
  ├── dnmtools pmd      → pmd.bed
  └── sort → awk → bedGraphToBigWig → methyl.bw + cover.bw
```

Step 0 runs fastp in the background writing to named pipes (FIFOs), which
abismal consumes directly — no trimmed FASTQ is written to disk. Step 1 uses
file-based intermediates rather than a Unix pipe because `dnmtools format` and
`dnmtools uniq` require seekable BAM input (htslib constraint). All
intermediates live on local NVMe and are deleted as soon as the next step
consumes them.

**Tool options used in Step 0:**

```bash
# Paired-end: two named pipes
mkfifo trim_1.fq trim_2.fq
fastp --in1 R1.fq --in2 R2.fq --out1 trim_1.fq --out2 trim_2.fq --json fastp.json --thread 2 &
  # --out1/--out2     Write trimmed reads to named pipes (FIFOs) instead of files
  # --json            Write QC report (copied to outdir after abismal finishes)
  # --thread 2        I/O-bound; 2 threads is sufficient
  # &                 Run in background so abismal can consume the pipes simultaneously

# Single-end: one named pipe
mkfifo trim.fq
fastp --in1 R1.fq --out1 trim.fq --json fastp.json --thread 2 &
```

**Tool options used in Step 1:**

```bash
dnmtools abismal -i genome.abismal.idx -t $THREADS -B -o mapped.bam -s abismal.stats trim_1.fq trim_2.fq
  # -i FILE    abismal index file (built with `dnmtools abismalidx genome.fa genome.abismal.idx`)
  # -t INT     Number of threads
  # -B         Output BAM format (default: SAM)
  # -o FILE    Output file (aligned reads)
  # -s FILE    Mapping statistics file (YAML format)
  # Positional: trim_1.fq / trim_2.fq (FIFOs from Step 0) for PE; trim.fq for SE

dnmtools format -t $THREADS -f abismal -B [-single-end] mapped.bam formatted.bam
  # -t INT          Number of threads
  # -f FORMAT       Input format: {abismal, bsmap, bismark}
  # -B              Output in BAM format
  # -single-end     Assume single-end reads (required for SE; without it, format
  #                 fails with "failed to identify read name suffix length")
  # Converts abismal's non-standard BAM tags to dnmtools standard format

samtools sort -@ $THREADS -m 2G -T $WORK/sort -o sorted.bam formatted.bam
  # -@ INT     Additional sorting threads
  # -m INT     Max memory per thread (2G per thread)
  # -T PREFIX  Temporary files on NVMe scratch
  # -o FILE    Output file (coordinate-sorted BAM)

dnmtools uniq -t $THREADS sorted.bam dedup.bam
  # -t INT     Number of threads
  # Removes PCR duplicates from sorted, formatted BAM
  # Output format is inferred from the .bam extension
```

**Tool options used in Step 2:**

```bash
dnmtools counts -t $THREADS -cpg-only -c genome.fa dedup.bam | awk '$6 > 0' > counts.tsv
  # -t INT       Number of threads
  # -cpg-only    Print only CpG context cytosines (skip CHG/CHH — not relevant for mammals)
  # -c FILE      Reference genome FASTA (required)
  # Output format (tab-separated): chrom, pos, strand, context, meth_fraction, read_count
  # The awk filter keeps only CpG sites with at least 1 read (column 6 = coverage > 0)
```

**Tool options used in Step 3:**

```bash
dnmtools sym -t 2 -o counts.sym.tsv counts.tsv
  # -t INT     Number of threads (2 is sufficient)
  # -o FILE    Output file
  # Merges +/- strand CpG data into single symmetric CpG entries.
  # Required input for HMR (hmr expects strand-collapsed CpG data)

dnmtools hmr -o output.hmr.bed counts.sym.tsv
  # -o FILE    Output BED file
  # Identifies hypomethylated regions (HMRs) using a hidden Markov model.
  # HMRs correspond to CpG islands, active promoters, and enhancers.
  # Requires symmetric (strand-collapsed) input from `dnmtools sym`
  # Default parameters: -d 1000 (max desert between CpGs), -i 10 (max iterations)

dnmtools hypermr -o output.hypermr.bed counts.tsv
  # -o FILE    Output BED file
  # Identifies hypermethylated regions using an HMM.
  # Designed for organisms with low background methylation (e.g., plants).
  # For mammalian genomes: identifies regions of elevated methylation above
  # the already-high background (~80% CpG methylation).
  # Accepts either symmetric or per-strand counts; results are similar
  # Default: -d 1000 (desert size), -i 10 (iterations), -M 4.0 (min cumulative meth)

dnmtools pmd -o output.pmd.bed counts.tsv
  # -o FILE    Output BED file
  # Identifies partially methylated domains (PMDs) — large genomic regions
  # with reduced methylation, often seen in cancer cells, placenta, and
  # some differentiated cell types.
  # Uses a bin-based HMM approach

# BigWig generation from counts.tsv:
sort -k1,1 -k2,2n counts.tsv \
  | awk '{print $1, $2, $2+1, $5 > "methyl.bg"; print $1, $2, $2+1, $6 > "cover.bg"}'
  # Column 5 = methylation fraction (0–1), column 6 = read coverage
  # sort ensures lexical chrom order for bedGraphToBigWig
  # Each CpG is a 1-bp interval (start, start+1)

bedGraphToBigWig methyl.bg chrom.sizes output.methyl.bw
bedGraphToBigWig cover.bg  chrom.sizes output.cover.bw
```

**Arguments:**

| Flag | Required | Description |
|------|----------|-------------|
| `--sample-id` | yes | Experiment accession (e.g. SRX12345678) |
| `--fastq-fwd` | yes | Forward reads (FASTQ or FASTQ.gz) |
| `--fastq-rev` | no | Reverse reads (omit for single-end; auto-detects and passes `-single-end` to format) |
| `--genome` | yes | Genome name (`hg38`, `mm10`, `rn6`, `ce11`, `dm6`, `sacCer3`) — used to look up CpG count for coverage calculation |
| `--genome-fasta` | yes | Reference genome FASTA |
| `--abismal-index` | yes | abismal index file (built with `dnmtools abismalidx`) |
| `--chrom-sizes` | yes | Chromosome sizes file |
| `--outdir` | yes | Output directory |
| `--threads` | no | CPU threads (default: 16) |

**Thread allocation:** All thread-aware tools (abismal, format, sort, uniq,
counts) receive the full `--threads` value. Step 3 parallel jobs (hmr,
hypermr, pmd, BigWig) are single-threaded but run simultaneously.

**Outputs:**

| File | Description |
|------|-------------|
| `{id}.methyl.bw` | Per-CpG methylation fraction BigWig (0–1) |
| `{id}.cover.bw` | Per-CpG read coverage BigWig |
| `{id}.hmr.bed` | Hypomethylated regions (CpG islands, promoters) |
| `{id}.hypermr.bed` | Hypermethylated regions |
| `{id}.pmd.bed` | Partially methylated domains |
| `{id}.abismal.stats` | Alignment statistics (YAML) |
| `{id}_fastp.json` | fastp QC report |
| `{id}.stats.tsv` | 11-column v1-compatible stats (sample ID, SE/PE flag, FASTQ size, dedup BAM size, read count, mapping rate, methylation rate, CpG coverage, HMR/PMD/hyperMR counts, elapsed minutes) |

**Example:**

```bash
apptainer exec --bind /data1/tmp:/tmp pipeline-v2-bs.sif \
  bash pipeline-v2-bs.sh \
    --sample-id SRX12345678 \
    --fastq-fwd reads_1.fastq.gz \
    --fastq-rev reads_2.fastq.gz \
    --genome hg38 \
    --genome-fasta /ref/hg38.fa \
    --abismal-index /ref/hg38.abismal.idx \
    --chrom-sizes /ref/hg38.chrom.sizes \
    --outdir ./output \
    --threads 16
```

---

## Production Management

The single-script `production-run.sh` was superseded by two complementary
models. Pick one per genome based on sample size / pipeline cost:

| Model | When to use | Entry script |
|---|---|---|
| **Array** | Small genomes (sacCer3, ce11) where per-sample wall is short and download dominates | `nig/submit-sacCer3.sh` — SLURM array, one task per sample, each task downloads + runs inline |
| **Separated dl/proc** | Larger genomes (dm6, rn6, mm10, hg38) where pipeline cost dominates and a dedicated downloader keeps the processor fed | `nig/submit-separated.sh` → runs `production-download.sh` (general) + `nig/production-process.sh` (NIG-bound) |

Both models share:

- `nig/run-sample.sh` — per-sample wrapper (array model) that downloads + dispatches to pipeline
- `production-download.sh` — long-running download daemon (general)
- `nig/production-process.sh` — staging-dir-polling processor (NIG-bound paths)

See [`docs/production-download-design.md`](../docs/production-download-design.md)
for the separated-model design. See [`nig/README.md`](nig/README.md) for
NIG-specific deployment notes.

---

## Helpers

### `fast-download.sh` — FASTQ download with source-aware routing

Downloads FASTQs for a given run accession, routing to the fastest mirror
based on accession prefix.

**Usage:**

```bash
bash fast-download.sh <experiment_accession> <output_dir>
```

Takes an experiment accession (SRX/DRX/ERX), resolves its run accessions
via the ENA API, downloads each run with source-isolated retry (per-run
scratch is wiped between source attempts so a partial ENA download can't
collide with the SRA fallback's fasterq-dump output), and concatenates
the result into one SE or PE pair. ENA-metadata `layout=PAIRED` is not
trusted blindly — the concat step detects actual layout from files on
disk.

**Routing logic:**

| Prefix | Primary source | Fallback |
|--------|---------------|----------|
| `DRR*` | DDBJ local Lustre bz2 (NIG only) → DDBJ HTTPS | ENA HTTPS → fasterq-dump |
| `ERR*` | ENA HTTPS | fasterq-dump |
| `SRR*` | ENA HTTPS | fasterq-dump |

**DDBJ local path** (available on NIG compute nodes):
```
/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/DRA*/DRA*/{DRX}/{DRR}*.fastq.bz2
```
Only DRA-submitted (DRR) experiments have local FASTQs. SRX/ERX directories
exist as empty stubs. The mirror is current for DRA (updated through April
2026) but stopped updating for ERA/SRA around Dec 2024 / Jan 2025.

**ENA download details:**

1. Queries ENA filereport API for FASTQ URLs + md5 checksums
2. Downloads via `aria2c -x 8 -s 8` over HTTPS (`ftp.sra.ebi.ac.uk`)
3. Verifies md5 checksum (`--checksum=md5=...`)
4. Decompresses `.fastq.gz` → `.fastq`

**fasterq-dump fallback:** Uses sra-tools container
(`quay.io/biocontainers/sra-tools:3.0.10`) via apptainer/singularity/docker
when pre-built FASTQs are not available from mirrors.

### `prepare-genomes.sh` — Reference genome setup

Downloads reference genomes from UCSC/Ensembl, builds all indexes using the
pipeline containers (same tool versions as production).

**Usage:**

```bash
bash prepare-genomes.sh [BASE_DIR]
# Default: ~/chip-atlas-v2/references (or $CHIP_ATLAS_BASE/references)
```

**Supported genomes:** hg38, mm10, rn6, dm6, ce11, sacCer3, TAIR10

**Per-genome outputs:**

| File | Built by | Used by |
|------|----------|---------|
| `{genome}.fa` | Downloaded from UCSC/Ensembl | All pipelines |
| `{genome}.fa.fai` | `samtools faidx` (ChIP-seq container) | samtools |
| `chrom.sizes` | `cut -f1,2` from `.fai` | bedGraphToBigWig, bedToBigBed |
| `{genome}.fa.bwt.2bit.64` + index files | `bwa-mem2 index` (ChIP-seq container) | bwa-mem2 alignment |
| `{genome}.abismal.idx` | `dnmtools abismalidx` (BS-seq container) | abismal alignment |

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
| `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0` | `containers/Dockerfile.bs` | fastp 1.3.1, DNMTools 1.5.1, samtools 1.22.1, UCSC 482 |

Both containers use `condaforge/mambaforge` as the base image with tools installed from bioconda and conda-forge. All tool versions are pinned in the Dockerfiles for reproducibility.

Note: samtools is 1.22.1 in the BS-seq container (not 1.23.1) because
dnmtools 1.5.1 requires htslib <1.23. The CVE-2026-31973 fix in 1.23.1 is
CRAM-specific; this pipeline uses BAM only.

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
