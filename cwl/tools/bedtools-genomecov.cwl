#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "bedtools genomecov - Generate BedGraph coverage"
doc: |
  Generate RPM-normalized BedGraph coverage track from BAM file.
  Matches v1 pipeline approach: bedtools genomecov with -scale for RPM.

requirements:
  ResourceRequirement:
    coresMin: 1
    ramMin: 4096
  InlineJavascriptRequirement: {}
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/bedtools:2.31.1--hf5e1c6e_2"

baseCommand: []

inputs:
  bam:
    type: File
    secondaryFiles:
      - .bai
    doc: "Sorted, deduplicated BAM file"

  sample_id:
    type: string
    doc: "Sample identifier"

  mapped_read_count:
    type: long
    doc: "Number of mapped reads (for RPM normalization scale factor = 1000000/N)"

arguments:
  - shellQuote: false
    valueFrom: |
      bedtools genomecov -bg -ibam $(inputs.bam.path) -scale $(1000000 / inputs.mapped_read_count) | sort -k1,1 -k2,2n > $(inputs.sample_id).bedGraph

outputs:
  bedgraph:
    type: File
    outputBinding:
      glob: "*.bedGraph"
