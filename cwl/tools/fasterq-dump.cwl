#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "fasterq-dump - Download and convert SRA to FASTQ"
doc: "Download and convert SRA accessions to FASTQ files using sra-tools"

requirements:
  - class: ResourceRequirement
    coresMin: 4
    ramMin: 4096
  - class: NetworkAccess
    networkAccess: true

hints:
  - class: DockerRequirement
    dockerPull: "quay.io/biocontainers/sra-tools:3.0.10--h9f5acd7_0"

baseCommand: [fasterq-dump]

inputs:
  accession:
    type: string
    inputBinding:
      position: 1
    doc: "SRA run accession (e.g., SRR12345678)"

arguments:
  - prefix: --threads
    valueFrom: $(runtime.cores)
  - prefix: --outdir
    valueFrom: "."
  - "--split-files"
  - "--skip-technical"

outputs:
  fastq_files:
    type: File[]
    outputBinding:
      glob: "*.fastq"
    doc: "Downloaded FASTQ files (R1 and optionally R2)"
