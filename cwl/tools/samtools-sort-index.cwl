#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools sort + index - Sort and index BAM"
doc: "Sort BAM by coordinate and create index in one step"

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 4096
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"

baseCommand: []

inputs:
  input_file:
    type: File
    doc: "Input SAM or BAM file"

  sample_id:
    type: string
    doc: "Sample identifier for output naming"

arguments:
  - shellQuote: false
    valueFrom: |
      samtools sort -@ $(runtime.cores) -m 1G -o $(inputs.sample_id).sorted.bam $(inputs.input_file.path) && samtools index $(inputs.sample_id).sorted.bam

outputs:
  sorted_bam:
    type: File
    secondaryFiles:
      - .bai
    outputBinding:
      glob: "*.sorted.bam"
