#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "deepTools bamCoverage - Generate bigWig"
doc: "Generate normalized bigWig coverage track from BAM file"

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 8192
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/deeptools:3.5.6--pyhdfd78af_0"

baseCommand: [bamCoverage]

inputs:
  bam:
    type: File
    secondaryFiles:
      - .bai
    inputBinding:
      prefix: --bam
    doc: "Input BAM file (sorted, indexed)"

  sample_id:
    type: string
    doc: "Sample identifier"

  normalize:
    type: string?
    default: "RPKM"
    inputBinding:
      prefix: --normalizeUsing
    doc: "Normalization method (RPKM, CPM, BPM, RPGC, None)"

  bin_size:
    type: int?
    default: 50
    inputBinding:
      prefix: --binSize
    doc: "Bin size in bases"

  extend_reads:
    type: int?
    default: 200
    inputBinding:
      prefix: --extendReads
    doc: "Extend reads to fragment length"

arguments:
  - prefix: -p
    valueFrom: $(runtime.cores)
  - prefix: -o
    valueFrom: $(inputs.sample_id).bigWig
  - --skipNonCoveredRegions

outputs:
  bigwig:
    type: File
    outputBinding:
      glob: "*.bigWig"
