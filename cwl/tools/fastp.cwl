#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "fastp - Fast all-in-one FASTQ preprocessor"
doc: "Quality trimming, adapter removal, and QC for FASTQ files"

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 4096
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"

baseCommand: []

inputs:
  fastq_fwd:
    type: File
    doc: "Forward read FASTQ"

  fastq_rev:
    type: File?
    doc: "Reverse read FASTQ (omit for single-end)"

  sample_id:
    type: string
    doc: "Sample identifier for output naming"

arguments:
  - shellQuote: false
    valueFrom: |
      REV="$(inputs.fastq_rev.path)"
      if [ "\$REV" != "null" ] && [ "\$REV" != "" ] && [ -e "\$REV" ]; then
        fastp --in1 $(inputs.fastq_fwd.path) --in2 "\$REV" \
          --out1 $(inputs.sample_id)_trimmed_R1.fastq.gz \
          --out2 $(inputs.sample_id)_trimmed_R2.fastq.gz \
          --json $(inputs.sample_id)_fastp.json \
          --html $(inputs.sample_id)_fastp.html \
          --thread $(runtime.cores)
      else
        fastp --in1 $(inputs.fastq_fwd.path) \
          --out1 $(inputs.sample_id)_trimmed_R1.fastq.gz \
          --json $(inputs.sample_id)_fastp.json \
          --html $(inputs.sample_id)_fastp.html \
          --thread $(runtime.cores)
      fi

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
