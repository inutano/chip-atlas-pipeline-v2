#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools fixmate - Add mate score tags for markdup"
doc: |
  Add mate score tags (-m) required by samtools markdup.
  Input must be name-sorted; output is name-sorted BAM with ms tags.

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 4096

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"

baseCommand: [samtools, fixmate]

inputs:
  bam:
    type: File
    inputBinding:
      position: 2
    doc: "Name-sorted BAM file"

  sample_id:
    type: string
    doc: "Sample identifier"

arguments:
  - -m
  - prefix: -@
    valueFrom: $(runtime.cores)
  - position: 3
    valueFrom: $(inputs.sample_id).fixmate.bam

outputs:
  fixmate_bam:
    type: File
    outputBinding:
      glob: "*.fixmate.bam"
