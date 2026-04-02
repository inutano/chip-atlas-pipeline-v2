#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "MACS3 callpeak - Peak calling without control"
doc: |
  Call peaks using MACS3 without control/input sample.
  ChIP-Atlas policy: peaks are called without background data;
  users filter by q-value threshold instead.

requirements:
  - class: ResourceRequirement
    coresMin: 1
    ramMin: 4096

hints:
  - class: DockerRequirement
    dockerPull: "quay.io/biocontainers/macs3:3.0.4--py312h71493bf_0"

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
    type: string
    inputBinding:
      prefix: -q
    doc: "Minimum FDR (q-value) cutoff as string (e.g. '1e-05', '1e-10', '1e-20')"

  format:
    type: string?
    default: "BAM"
    inputBinding:
      prefix: -f
    doc: "Input format (BAM for single-end, BAMPE for paired-end)"

  nomodel:
    type: boolean?
    default: false
    inputBinding:
      prefix: --nomodel
    doc: "Skip model building, use --extsize instead"

  extsize:
    type: int?
    default: 200
    inputBinding:
      prefix: --extsize
    doc: "Extension size (used when --nomodel is set)"

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
    type: File?
    outputBinding:
      glob: "*_peaks.xls"
