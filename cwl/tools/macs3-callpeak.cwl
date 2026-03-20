#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "MACS3 callpeak - Peak calling without control"
doc: |
  Call peaks using MACS3 without control/input sample.
  ChIP-Atlas policy: peaks are called without background data;
  users filter by q-value threshold instead.

requirements:
  ResourceRequirement:
    coresMin: 1
    ramMin: 4096
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/macs3:3.0.2--py312hcba1217_1"

baseCommand: [macs3, callpeak]

inputs:
  treatment_bam:
    type: File
    inputBinding:
      prefix: -t
    doc: "Treatment BAM file"

  sample_id:
    type: string
    inputBinding:
      prefix: -n
    doc: "Sample name for output files"

  genome_size:
    type: string
    inputBinding:
      prefix: -g
    doc: "Effective genome size (hs, mm, ce, dm, or number)"

  qvalue:
    type: float
    inputBinding:
      prefix: -q
    doc: "Minimum FDR (q-value) cutoff (e.g. 0.00001, 0.0000000001, 0.00000000000000000001)"

  format:
    type: string?
    default: "BAM"
    inputBinding:
      prefix: -f
    doc: "Input format (BAM for single-end, BAMPE for paired-end)"

  outdir:
    type: string?
    default: "."
    inputBinding:
      prefix: --outdir

outputs:
  narrow_peaks:
    type: File?
    outputBinding:
      glob: "*_peaks.narrowPeak"

  summits:
    type: File?
    outputBinding:
      glob: "*_summits.bed"

  xls:
    type: File
    outputBinding:
      glob: "*_peaks.xls"
