#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "samtools sort - Sort BAM"
doc: "Sort BAM by name or coordinate"

requirements:
  ResourceRequirement:
    coresMin: 4
    ramMin: 4096
  InlineJavascriptRequirement: {}
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "quay.io/biocontainers/samtools:1.19.2--h50ea8bc_1"

baseCommand: []

inputs:
  input_file:
    type: File
    doc: "Input SAM or BAM file"

  sample_id:
    type: string
    doc: "Sample identifier for output naming"

  by_name:
    type: boolean?
    default: false
    doc: "Sort by read name instead of coordinate"

arguments:
  - shellQuote: false
    valueFrom: |
      ${
        var suffix = inputs.by_name ? ".namesorted.bam" : ".sorted.bam";
        var sort_flag = inputs.by_name ? "-n " : "";
        var cmd = "samtools sort " + sort_flag + "-@ " + runtime.cores + " -m 1G -o " + inputs.sample_id + suffix + " " + inputs.input_file.path;
        if (!inputs.by_name) {
          cmd += " && samtools index " + inputs.sample_id + suffix;
        }
        return cmd;
      }

outputs:
  sorted_bam:
    type: File
    secondaryFiles:
      - pattern: .bai
        required: false
    outputBinding:
      glob: |
        ${
          return inputs.by_name ? "*.namesorted.bam" : "*.sorted.bam";
        }
