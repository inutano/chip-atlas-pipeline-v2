#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "bedToBigBed - Convert BED to BigBed"
doc: "Convert BED file to BigBed format using UCSC tools. Handles null input gracefully."

requirements:
  ResourceRequirement:
    coresMin: 1
    ramMin: 2048
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/ucsc-bedtobigbed:482--hdc0a859_0"

baseCommand: []

inputs:
  bed:
    type: File?
    doc: "Input BED file (will be sorted and truncated to BED4)"

  chrom_sizes:
    type: File
    doc: "Chromosome sizes file"

  sample_id:
    type: string
    doc: "Sample identifier"

arguments:
  - shellQuote: false
    valueFrom: |
      BED="$(inputs.bed.path)"
      if [ "\$BED" != "null" ] && [ "\$BED" != "" ] && [ -e "\$BED" ]; then
        cut -f1-4 "\$BED" | sort -k1,1 -k2,2n > sorted.bed && bedToBigBed sorted.bed $(inputs.chrom_sizes.path) $(inputs.sample_id).bb
      fi

outputs:
  bigbed:
    type: File?
    outputBinding:
      glob: "*.bb"
