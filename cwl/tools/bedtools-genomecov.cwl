#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "bedtools genomecov - Generate BedGraph coverage"
doc: |
  Generate RPM-normalized BedGraph coverage track from BAM file.
  Reads mapped count from a text file and computes scale factor in shell.

requirements:
  - class: ResourceRequirement
    coresMin: 1
    ramMin: 4096
  - class: ShellCommandRequirement

hints:
  - class: DockerRequirement
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

  count_file:
    type: File
    doc: "Text file containing mapped read count (from samtools-mapped-count)"

arguments:
  - shellQuote: false
    valueFrom: |
      SCALE=\$(awk -v n=\$(cat $(inputs.count_file.path)) 'BEGIN {printf "%.10f", 1000000/n}') && bedtools genomecov -bg -ibam $(inputs.bam.path) -scale "\$SCALE" | sort -k1,1 -k2,2n > $(inputs.sample_id).bedGraph

outputs:
  bedgraph:
    type: File
    outputBinding:
      glob: "*.bedGraph"
