#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "bedGraphToBigWig - Convert BedGraph to BigWig"
doc: "Convert sorted BedGraph to BigWig format using UCSC tools"

requirements:
  ResourceRequirement:
    coresMin: 1
    ramMin: 4096
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/ucsc-bedgraphtobigwig:447--h2a80c09_1"

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
