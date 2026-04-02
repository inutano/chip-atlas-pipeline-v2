#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "bedGraphToBigWig - Convert BedGraph to BigWig"
doc: "Convert sorted BedGraph to BigWig format using UCSC tools"

requirements:
  - class: ResourceRequirement
    coresMin: 1
    ramMin: 4096

hints:
  - class: DockerRequirement
    dockerPull: "quay.io/biocontainers/ucsc-bedgraphtobigwig:482--hdc0a859_0"

baseCommand: [bedGraphToBigWig]

inputs:
  bedgraph:
    type: File
    inputBinding:
      position: 1
    doc: "Sorted BedGraph file"

  chrom_sizes:
    type: File
    inputBinding:
      position: 2
    doc: "Chromosome sizes file"

  sample_id:
    type: string
    doc: "Sample identifier"

arguments:
  - position: 3
    valueFrom: $(inputs.sample_id).bw

outputs:
  bigwig:
    type: File
    outputBinding:
      glob: "*.bw"
