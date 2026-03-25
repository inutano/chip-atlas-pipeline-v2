#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "Parabricks fq2bam - GPU-accelerated alignment, sorting, and dedup"
doc: |
  NVIDIA Parabricks fq2bam performs BWA-MEM alignment, coordinate sorting,
  and duplicate marking in a single GPU-accelerated step.
  Replaces bwa-mem2 + samtools sort + samtools markdup.

  Usage: pbrun fq2bam --ref <ref> --in-fq <fwd> [<rev>] <RG> --out-bam <bam>

$namespaces:
  cwltool: "http://commonwl.org/cwltool#"

requirements:
  ResourceRequirement:
    coresMin: 8
    ramMin: 32768
  InlineJavascriptRequirement: {}
  ShellCommandRequirement: {}

hints:
  DockerRequirement:
    dockerPull: "nvcr.io/nvidia/clara/clara-parabricks:4.3.1-1"
  cwltool:CUDARequirement:
    cudaVersionMin: "11.0"
    cudaComputeCapability: "7.0"
    cudaDeviceCountMin: 1
    cudaDeviceCountMax: 4

baseCommand: [pbrun, fq2bam]

inputs:
  genome_fasta:
    type: File
    secondaryFiles:
      - .fai
      - .amb
      - .ann
      - .bwt
      - .pac
      - .sa
    inputBinding:
      prefix: --ref
      position: 1
    doc: "Reference genome FASTA with BWA index files"

  fastq_fwd:
    type: File
    doc: "Forward read FASTQ"

  fastq_rev:
    type: File?
    doc: "Reverse read FASTQ (omit for single-end)"

  sample_id:
    type: string
    doc: "Sample identifier for read group and output naming"

  num_gpus:
    type: int?
    default: 1
    inputBinding:
      prefix: --num-gpus
      position: 4
    doc: "Number of GPUs to use"

arguments:
  - position: 2
    valueFrom: |
      ${
        var rg = "\"@RG\\tID:" + inputs.sample_id + "\\tSM:" + inputs.sample_id + "\\tPL:ILLUMINA\\tPU:" + inputs.sample_id + "\\tLB:" + inputs.sample_id + "\"";
        if (inputs.fastq_rev) {
          return "--in-fq " + inputs.fastq_fwd.path + " " + inputs.fastq_rev.path + " " + rg;
        } else {
          return "--in-se-fq " + inputs.fastq_fwd.path + " " + rg;
        }
      }
    shellQuote: false
  - prefix: --out-bam
    position: 3
    valueFrom: $(inputs.sample_id).dedup.bam
  - prefix: --out-duplicate-metrics
    position: 5
    valueFrom: $(inputs.sample_id).dup_metrics.txt

outputs:
  dedup_bam:
    type: File
    secondaryFiles:
      - .bai
    outputBinding:
      glob: "*.dedup.bam"
    doc: "Sorted, deduplicated BAM file with index"

  duplicate_metrics:
    type: File
    outputBinding:
      glob: "*.dup_metrics.txt"
    doc: "Duplicate marking statistics"
