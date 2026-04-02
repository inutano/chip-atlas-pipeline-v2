#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "fastp - Fast all-in-one FASTQ preprocessor"
doc: "Quality trimming, adapter removal, and QC for FASTQ files"

requirements:
  - class: ResourceRequirement
    coresMin: 4
    ramMin: 4096
  - class: ShellCommandRequirement
  - class: InitialWorkDirRequirement
    listing:
      - entryname: run-fastp.sh
        entry: |
          #!/bin/bash
          set -eo pipefail
          FWD="$1"
          SID="$2"
          THREADS="$3"
          REV="$4"
          OUT1="$SID"_trimmed_R1.fastq.gz
          OUT2="$SID"_trimmed_R2.fastq.gz
          JSON="$SID"_fastp.json
          HTML="$SID"_fastp.html
          if [ -n "$REV" ] && [ -e "$REV" ]; then
            fastp --in1 "$FWD" --in2 "$REV" --out1 "$OUT1" --out2 "$OUT2" --json "$JSON" --html "$HTML" --thread "$THREADS"
          else
            fastp --in1 "$FWD" --out1 "$OUT1" --json "$JSON" --html "$HTML" --thread "$THREADS"
          fi

hints:
  - class: DockerRequirement
    dockerPull: "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"

baseCommand: [bash, run-fastp.sh]

inputs:
  fastq_fwd:
    type: File
    inputBinding:
      position: 1
    doc: "Forward read FASTQ"

  sample_id:
    type: string
    inputBinding:
      position: 2
    doc: "Sample identifier for output naming"

  threads:
    type: int?
    default: 4
    inputBinding:
      position: 3
    doc: "Number of threads"

  fastq_rev:
    type: File?
    inputBinding:
      position: 4
    doc: "Reverse read FASTQ (omit for single-end)"

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
