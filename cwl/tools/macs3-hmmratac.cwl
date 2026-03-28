#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "MACS3 HMMRATAC - ATAC-seq peak calling"
doc: |
  Call open chromatin regions from ATAC-seq data using HMMRATAC
  (reimplemented as macs3 hmmratac subcommand).
  Uses a hidden Markov model to classify genomic regions based on
  fragment size distributions.

requirements:
  ResourceRequirement:
    coresMin: 1
    ramMin: 8192

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/macs3:3.0.4--py312h71493bf_0"

baseCommand: [macs3, hmmratac]

inputs:
  bam:
    type: File
    secondaryFiles:
      - .bai
    inputBinding:
      prefix: -i
    doc: "Input BAM file (sorted, indexed, paired-end)"

  sample_id:
    type: string
    inputBinding:
      prefix: -n
    doc: "Output file name prefix"

  format:
    type: string?
    default: "BAMPE"
    inputBinding:
      prefix: -f
    doc: "Input format (BAMPE for paired-end BAM)"

  hmm_binsize:
    type: int?
    default: 10
    inputBinding:
      prefix: --hmm-binsize
    doc: "Bin size in bp for signal sampling"

  prescan_cutoff:
    type: float?
    default: 1.2
    inputBinding:
      prefix: --prescan-cutoff
    doc: "Fold change cutoff for pre-scanning candidate regions"

  openregion_minlen:
    type: int?
    default: 100
    inputBinding:
      prefix: --openregion-minlen
    doc: "Minimum length of open region to call"

  outdir:
    type: string?
    default: "."
    inputBinding:
      prefix: --outdir

outputs:
  accessible_regions:
    type: File?
    outputBinding:
      glob: "*_accessible_regions.*Peak"
    doc: "Accessible chromatin regions (narrowPeak or gappedPeak)"
