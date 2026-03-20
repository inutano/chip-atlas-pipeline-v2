#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools markdup - Remove PCR duplicates"
doc: |
  Mark and remove PCR duplicates using samtools markdup.
  Replaces the deprecated samtools rmdup used in v1.

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 4096
  InlineJavascriptRequirement: {}
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/samtools:1.21--h50ea8bc_1"

baseCommand: []

inputs:
  sorted_bam:
    type: File
    secondaryFiles:
      - .bai
    doc: "Coordinate-sorted BAM file with index"

  sample_id:
    type: string
    doc: "Sample identifier"

arguments:
  - shellQuote: false
    valueFrom: |
      samtools markdup -r -@ $(runtime.cores) $(inputs.sorted_bam.path) $(inputs.sample_id).dedup.bam && samtools index $(inputs.sample_id).dedup.bam

outputs:
  dedup_bam:
    type: File
    secondaryFiles:
      - .bai
    outputBinding:
      glob: "*.dedup.bam"
