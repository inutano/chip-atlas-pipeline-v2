# ChIP-Atlas Pipeline v2

Uniform processing of public epigenomic data (ChIP-seq, ATAC-seq, DNase-seq,
Bisulfite-seq) at scale. This is the next-generation pipeline behind
[ChIP-Atlas](https://chip-atlas.dbcls.jp), rewritten as portable CWL v1.2
workflows with modern tools.

v2 processes samples 65-90x faster than v1 (from roughly 1 day per sample down
to 15-60 minutes depending on genome size and hardware) while recovering
approximately 90% of v1 peaks with improved sensitivity.


## Quick Start

```bash
# Clone the repository
git clone https://github.com/inutano/chip-atlas-pipeline-v2.git
cd chip-atlas-pipeline-v2

# Install cwltool (reference CWL runner)
pip install cwltool

# Run a single sample (Option B recommended)
cwltool cwl/workflows/option-b.cwl \
  --sample_id SRX12345678 \
  --fastq_fwd reads_1.fastq.gz \
  --fastq_rev reads_2.fastq.gz \
  --genome_index bwa-mem2-index/ \
  --chrom_sizes hg38.chrom.sizes
```

All tools run in containers (Docker, Singularity, or udocker), so you do not
need to install individual bioinformatics tools. See `docs/cluster-setup-guide.md`
for NIG supercomputer setup and `docs/v2-plan.md` for the full design document.


## Pipeline Options

### Option A -- Fast Classic

Same processing steps as the original ChIP-Atlas v1 pipeline, rebuilt with
faster tools:

    FASTQ -> BWA-MEM2 align -> sort -> fixmate -> sort -> markdup
          -> bedtools genomecov -> bedGraphToBigWig
          -> MACS3 callpeak (x3 thresholds) -> bedToBigBed

### Option B -- Modern (recommended)

Adds QC/trimming and uses deeptools for coverage tracks:

    FASTQ -> fastp trim -> BWA-MEM2 align -> sort -> fixmate -> sort -> markdup
          -> deeptools bamCoverage (BigWig)
          -> MACS3 callpeak (x3 thresholds) -> bedToBigBed

Option B is faster and more robust in practice. It is the recommended choice
for production runs.

### GPU Variants

Both options have Parabricks variants (`option-a-parabricks.cwl`,
`option-b-parabricks.cwl`) that use NVIDIA Parabricks for GPU-accelerated
alignment and sorting.

### Key Parameters

- Peak calling uses `--nomodel --extsize 200` and `--format BAM` (not BAMPE)
  for consistent handling of single-end and paired-end data.
- Three q-value thresholds per sample: 1e-05, 1e-10, 1e-20.
- No background/input control is used for peak calling (ChIP-Atlas policy --
  all samples are processed uniformly without matched controls).


## Directory Structure

```
cwl/
  tools/              CWL CommandLineTool definitions (one file per tool)
  workflows/          Workflow definitions
                        option-a.cwl, option-a-nomodel.cwl, option-a-parabricks.cwl
                        option-b.cwl, option-b-parabricks.cwl
scripts/              Benchmark, download, and batch submission scripts
data/                 Validation sample lists, benchmark timing, metadata
docs/                 Design documents, benchmark results, progress log
templates/            HTML templates for secondary analysis output
test-run/             Test run outputs (e.g., sacCer3 validation)
```


## Tools

| Tool           | Version | Purpose                              |
|----------------|---------|--------------------------------------|
| bwa-mem2       | latest  | Sequence alignment                   |
| samtools       | 1.19    | BAM sorting, fixmate, markdup        |
| MACS3          | 3.0.4   | Peak calling                         |
| fastp          | latest  | QC and adapter trimming (Option B)   |
| deeptools      | latest  | Coverage tracks / BigWig (Option B)  |
| bedtools       | latest  | Genome coverage (Option A)           |
| UCSC tools     | latest  | bedGraphToBigWig, bedToBigBed        |


## Documentation

- `docs/v2-plan.md` -- Full design and rationale
- `docs/current-pipeline.md` -- Description of the v1 pipeline
- `docs/cwl-zen-design.md` -- CWL design principles (no InlineJavascriptRequirement)
- `docs/cluster-setup-guide.md` -- NIG supercomputer setup instructions
- `docs/secondary-analysis-plan.md` -- Downstream analysis (target genes, colocalization)
- `data/benchmark-timing-*.tsv` -- Benchmark results across genomes and hardware


## Requirements

- A CWL v1.2 runner (cwltool is the reference implementation)
- A container runtime: Docker, Singularity, or udocker
- For GPU variants: NVIDIA GPU with Parabricks installed

The pipeline is designed for the NIG supercomputer but runs on any
CWL-compatible environment with container support.


## License

MIT
