#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools view -c - Count mapped reads"
doc: "Count mapped reads in a BAM file for RPM normalization"

requirements:
  ResourceRequirement:
    coresMin: 2
    ramMin: 2048
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/samtools:1.21--h50ea8bc_1"

baseCommand: [samtools, view]

stdout: mapped_count.txt

inputs:
  bam:
    type: File
    secondaryFiles:
      - .bai
    inputBinding:
      position: 1
    doc: "BAM file to count"

arguments:
  - -c
  - -F
  - "4"

outputs:
  count:
    type: long
    outputBinding:
      glob: mapped_count.txt
      loadContents: true
      outputEval: $(parseInt(self[0].contents.trim()))
