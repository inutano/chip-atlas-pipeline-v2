#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "bedToBigBed - Convert BED to BigBed"
doc: "Convert BED file to BigBed format using UCSC tools. Handles null input gracefully."

requirements:
  - class: ResourceRequirement
    coresMin: 1
    ramMin: 2048
  - class: ShellCommandRequirement
  - class: InitialWorkDirRequirement
    listing:
      - entryname: run-bedtobigbed.sh
        entry: |
          #!/bin/bash
          set -eo pipefail
          BED="$1"
          CHROM="$2"
          SID="$3"
          if [ -n "$BED" ] && [ -e "$BED" ]; then
            cut -f1-4 "$BED" | sort -k1,1 -k2,2n > sorted.bed && bedToBigBed sorted.bed "$CHROM" "$SID".bb
          fi

hints:
  - class: DockerRequirement
    dockerPull: "quay.io/biocontainers/ucsc-bedtobigbed:482--hdc0a859_0"

baseCommand: [bash, run-bedtobigbed.sh]

inputs:
  bed:
    type: File?
    inputBinding:
      position: 1
    doc: "Input BED file (will be sorted and truncated to BED4)"

  chrom_sizes:
    type: File
    inputBinding:
      position: 2
    doc: "Chromosome sizes file"

  sample_id:
    type: string
    inputBinding:
      position: 3
    doc: "Sample identifier"

outputs:
  bigbed:
    type: File?
    outputBinding:
      glob: "*.bb"
