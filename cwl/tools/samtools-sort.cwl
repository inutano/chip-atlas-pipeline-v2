#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools sort - Sort BAM"
doc: "Sort BAM by name or coordinate"

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

  by_name:
    type: boolean?
    default: false
    doc: "Sort by read name instead of coordinate"

arguments:
  - shellQuote: false
    valueFrom: |
      if [ "$(inputs.by_name)" = "true" ]; then
        samtools sort -n -@ $(runtime.cores) -m 1G -o $(inputs.sample_id).namesorted.bam $(inputs.input_file.path)
      else
        samtools sort -@ $(runtime.cores) -m 1G -o $(inputs.sample_id).sorted.bam $(inputs.input_file.path) && samtools index $(inputs.sample_id).sorted.bam
      fi

outputs:
  sorted_bam:
    type: File
    secondaryFiles:
      - pattern: .bai
        required: false
    outputBinding:
      glob:
        - "$(inputs.sample_id).sorted.bam"
        - "$(inputs.sample_id).namesorted.bam"
