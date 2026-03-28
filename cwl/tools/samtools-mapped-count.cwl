#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools view -c - Count mapped reads"
doc: "Count mapped reads in a BAM file. Outputs count as a text file."

requirements:
  ResourceRequirement:
    coresMin: 2
    ramMin: 2048
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"

baseCommand: []

inputs:
  bam:
    type: File
    secondaryFiles:
      - .bai
    doc: "BAM file to count"

arguments:
  - shellQuote: false
    valueFrom: |
      samtools view -c -F 4 $(inputs.bam.path) | tr -d '[:space:]' > mapped_count.txt

outputs:
  count_file:
    type: File
    outputBinding:
      glob: mapped_count.txt
    doc: "Text file containing the mapped read count"
