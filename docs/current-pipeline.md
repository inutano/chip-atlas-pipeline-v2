# ChIP-Atlas Pipeline v1: Current Architecture

## Overview

ChIP-Atlas reprocesses all publicly available ChIP-seq, DNase-seq, ATAC-seq, and Bisulfite-seq data from NCBI Sequence Read Archive (SRA). The current pipeline (v1) is orchestrated entirely via shell scripts submitted to a Sun Grid Engine (SGE/UGE) cluster, with no formal workflow manager.

- **Source code**: <https://github.com/shinyaoki/chipatlas>
- **Documentation**: <https://github.com/inutano/chip-atlas/wiki#primary_processing_doc>

## Supported Genomes

hg19, hg38, mm9, mm10, rn6, dm3, dm6, ce10, ce11, sacCer3

## Primary Processing (per experiment)

| Step | Tool (Version) | Description | Input | Output |
|------|----------------|-------------|-------|--------|
| 1. Data selection | SRA metadata dump | Filter by LIBRARY_STRATEGY, INSTRUMENT_MODEL, LIBRARY_SOURCE, LIBRARY_SELECTION, ORGANISM | NCBI SRA metadata | Eligible SRX list |
| 2. Download & FASTQ conversion | SRA Toolkit (2.3.2-4) | Download SRA files, convert to FASTQ with `--split-files` for paired-end, concatenate multi-run experiments | SRX accession | FASTQ files |
| 3. Read alignment | Bowtie2 (2.2.2) | Align reads to reference genome (`--no-unal`, multi-threaded) | FASTQ | SAM |
| 4. BAM processing | SAMtools (0.1.19) | Convert SAM→BAM, coordinate sort, remove PCR duplicates | SAM | Sorted, deduplicated BAM |
| 5. Coverage track generation | bedtools (2.17.0) + UCSC bedGraphToBigWig (v4) | Generate BedGraph with RPM normalization, convert to BigWig | BAM + chrom sizes | BigWig (.bw) |
| 6. Peak calling | MACS2 (2.1.0) via Singularity | Call peaks at three q-value thresholds: 1e-05, 1e-10, 1e-20 | BAM | BED4 (chr, start, end, -10*log10(q)) |
| 7. Visualization format | UCSC bedToBigBed | Convert BED4 → color-coded BED9 → BigBed | BED4 | BigBed (.bb) |

### Peak Color Coding (BED9)

MACS2 scores are mapped to RGB colors:

- 0–250: blue → cyan gradient
- 250–500: cyan → green gradient
- 500–750: green → red gradient
- 750–1000: red gradient
- >1000: bright red (255,0,0)

## Secondary / Post-Processing

### Metadata Tagging and Classification

- Antigen nomenclature: Brno notation for histones (e.g., H3K4me3), official gene symbols (HGNC/MGI/RGD/FlyBase/WormBase/SGD) for proteins
- Cell type classification by tissue origin using ATCC/MeSH nomenclature
- Peak files organized into directories by antigen class × cell type

### Target Gene Analysis

- `bedtools window` overlapping peaks with TSS coordinates
- Three window sizes: ±1 kb, ±5 kb, ±10 kb from each TSS
- Filtered to protein-coding genes (NM_ RefSeq identifiers)
- Integrated with STRING protein-protein interaction scores

### Colocalization Analysis

- Identifies co-binding partners for transcription factors within the same cell type
- MACS2 scores fitted to Gaussian distribution, assigned Z-score groups: H (>0.5), M (-0.5 to 0.5), L (<-0.5)
- Pairwise scoring of H/M/L combinations (H-H=9, M-M=4, L-L=1)
- Computed by custom Java tool (`coloCA.jar`)
- Integrated with STRING protein-protein interaction scores

### Enrichment / In Silico ChIP

- Accepts user-provided genomic regions (BED), gene lists, or sequence motifs
- `bedtools intersect` for overlap detection
- Two-tailed Fisher's exact test with Benjamini-Hochberg correction
- Specialized analyses for FANTOM5 enhancers/promoters and GWAS catalog data

## Orchestration Scripts

| Script | Role |
|--------|------|
| `initialize.sh` | One-time setup: directory structure, tool installation (`toolPrep.sh`), genome index download (`genomeSettings.sh`), metadata preparation (`metaPrep.sh`) |
| `Controller.sh` | Main loop: filters eligible SRX accessions, submits `sraTailor.sh` jobs via `qsub`, monitors disk space, throttles concurrency |
| `sraTailor.sh` | Core per-experiment pipeline (steps 2–7 above) |
| `upDate.sh` | Incremental updates: downloads new NCBI metadata, diffs against processed experiments, re-launches for new/changed accessions |
| `dataAnalysis.sh` | Orchestrates all secondary analyses (target genes, colocalization, in silico ChIP) |

## Data Distribution

Files hosted at:

- `https://chip-atlas.dbcls.jp/data/{Genome}/eachData/bw/{SRX_ID}.bw`
- `https://chip-atlas.dbcls.jp/data/{Genome}/eachData/bed{Threshold}/{SRX_ID}.{Threshold}.bed`

Metadata tables: `experimentList.tab`, `fileList.tab`, `analysisList.tab`, `antigenList.tab`, `celltypeList.tab`

## Known Limitations

- **Outdated tool versions**: Bowtie2 2.2.2, SAMtools 0.1.19, bedtools 2.17.0 are all from ~2013–2014
- **No workflow manager**: Pure shell + SGE with manual polling loops and disk-space monitoring
- **Minimal containerization**: Only MACS2 runs in a Singularity container; all other tools installed directly
- **No reproducibility guarantees**: No pinned environments beyond hardcoded version numbers in install scripts
- **MD5-verified genome downloads** but no checksumming of intermediate outputs
- **Hardcoded SGE dependency**: Not portable to other job schedulers (SLURM, PBS, etc.)
