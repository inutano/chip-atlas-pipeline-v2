#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "ChIP-Atlas Pipeline v2 — Production single-container pipeline"
doc: |
  Wraps scripts/pipeline-v2.sh which runs the full ChIP-Atlas pipeline
  inside a single container:
    1. fastp -> bwa-mem2 -> samtools collate/fixmate/sort/markdup (piped)
    2. BigWig (bedtools genomecov + bedGraphToBigWig) + MACS3 (parallel)
    3. Peak filtering (q05/q10/q20) + BigBed conversion

  The script is passed as a File input to avoid InitialWorkDirRequirement.
  All tools are pre-installed in the container image.

requirements:
  - class: ResourceRequirement
    coresMin: 8
    ramMin: 16384
  - class: ShellCommandRequirement
  - class: NetworkAccess
    networkAccess: false

hints:
  - class: DockerRequirement
    dockerPull: "ghcr.io/inutano/chip-atlas-pipeline-v2:latest"

baseCommand: [bash]

arguments:
  - position: 2
    prefix: "--outdir"
    valueFrom: "output"

inputs:
  script:
    type: File
    inputBinding:
      position: 0
    doc: "The pipeline-v2.sh script file"

  sample_id:
    type: string
    inputBinding:
      position: 1
      prefix: "--sample-id"
    doc: "Sample or experiment accession ID"

  fastq_fwd:
    type: File
    inputBinding:
      position: 1
      prefix: "--fastq-fwd"
    doc: "Forward read FASTQ file"

  fastq_rev:
    type: File?
    inputBinding:
      position: 1
      prefix: "--fastq-rev"
    doc: "Reverse read FASTQ file (omit for single-end)"

  genome_fasta:
    type: File
    secondaryFiles:
      - pattern: ".0123"
      - pattern: ".amb"
      - pattern: ".ann"
      - pattern: ".bwt.2bit.64"
      - pattern: ".pac"
    inputBinding:
      position: 1
      prefix: "--genome-fasta"
    doc: "Reference genome FASTA with BWA-MEM2 index files"

  chrom_sizes:
    type: File
    inputBinding:
      position: 1
      prefix: "--chrom-sizes"
    doc: "Chromosome sizes file for bigWig/bigBed conversion"

  genome_size:
    type: string
    inputBinding:
      position: 1
      prefix: "--genome-size"
    doc: "Effective genome size for MACS3 (e.g., 'hs', 'mm', '1.2e7')"

  threads:
    type: int?
    default: 8
    inputBinding:
      position: 1
      prefix: "--threads"
    doc: "Number of threads to use"

outputs:
  bw:
    type: File?
    outputBinding:
      glob: "output/*.bw"
    doc: "BigWig signal track"

  peaks_q05:
    type: File?
    outputBinding:
      glob: "output/*.05_peaks.narrowPeak"
    doc: "Peaks at q-value 1e-05"

  peaks_q10:
    type: File?
    outputBinding:
      glob: "output/*.10_peaks.narrowPeak"
    doc: "Peaks at q-value 1e-10"

  peaks_q20:
    type: File?
    outputBinding:
      glob: "output/*.20_peaks.narrowPeak"
    doc: "Peaks at q-value 1e-20"

  bb_q05:
    type: File?
    outputBinding:
      glob: "output/*.05.bb"
    doc: "BigBed for q-value 1e-05 peaks"

  bb_q10:
    type: File?
    outputBinding:
      glob: "output/*.10.bb"
    doc: "BigBed for q-value 1e-10 peaks"

  bb_q20:
    type: File?
    outputBinding:
      glob: "output/*.20.bb"
    doc: "BigBed for q-value 1e-20 peaks"

  fastp_json:
    type: File?
    outputBinding:
      glob: "output/*_fastp.json"
    doc: "fastp QC report (JSON)"

  peaks_xls:
    type: File?
    outputBinding:
      glob: "output/*.05_peaks.xls"
    doc: "MACS3 peaks XLS report"
