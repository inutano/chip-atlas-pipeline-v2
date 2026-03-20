#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "BWA-MEM2 - Fast genome aligner"
doc: "Align reads to reference genome using BWA-MEM2"

requirements:
  ResourceRequirement:
    coresMin: 8
    ramMin: 16384
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8"

baseCommand: [bwa-mem2, mem]

stdout: $(inputs.sample_id).sam

inputs:
  genome_fasta:
    type: File
    secondaryFiles:
      - pattern: ".0123"
      - pattern: .amb
      - pattern: .ann
      - pattern: .bwt.2bit.64
      - pattern: .pac
    inputBinding:
      position: 1
    doc: "Reference genome FASTA with BWA-MEM2 index"

  fastq_fwd:
    type: File
    inputBinding:
      position: 2
    doc: "Forward read FASTQ"

  fastq_rev:
    type: File?
    inputBinding:
      position: 3
    doc: "Reverse read FASTQ (omit for single-end)"

  sample_id:
    type: string
    doc: "Sample identifier"

arguments:
  - prefix: -t
    valueFrom: $(runtime.cores)
  - prefix: -R
    valueFrom: $("@RG\\tID:" + inputs.sample_id + "\\tSM:" + inputs.sample_id + "\\tPL:ILLUMINA")

outputs:
  aligned_sam:
    type: File
    outputBinding:
      glob: "$(inputs.sample_id).sam"
