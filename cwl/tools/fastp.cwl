#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "fastp - Fast all-in-one FASTQ preprocessor"
doc: "Quality trimming, adapter removal, and QC for FASTQ files"

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 4096

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"

baseCommand: [fastp]

inputs:
  fastq_fwd:
    type: File
    inputBinding:
      prefix: --in1
    doc: "Forward read FASTQ"

  fastq_rev:
    type: File?
    inputBinding:
      prefix: --in2
    doc: "Reverse read FASTQ (omit for single-end)"

  sample_id:
    type: string
    doc: "Sample identifier for output naming"

arguments:
  - prefix: --out1
    valueFrom: $(inputs.sample_id)_trimmed_R1.fastq.gz
  - prefix: --out2
    valueFrom: $(inputs.sample_id)_trimmed_R2.fastq.gz
  - prefix: --json
    valueFrom: $(inputs.sample_id)_fastp.json
  - prefix: --html
    valueFrom: $(inputs.sample_id)_fastp.html
  - prefix: --thread
    valueFrom: $(runtime.cores)

outputs:
  trimmed_fwd:
    type: File
    outputBinding:
      glob: "*_trimmed_R1.fastq.gz"

  trimmed_rev:
    type: File?
    outputBinding:
      glob: "*_trimmed_R2.fastq.gz"

  json_report:
    type: File
    outputBinding:
      glob: "*_fastp.json"

  html_report:
    type: File
    outputBinding:
      glob: "*_fastp.html"
