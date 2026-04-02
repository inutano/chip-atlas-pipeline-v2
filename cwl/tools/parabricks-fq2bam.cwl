#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "Parabricks fq2bam - GPU-accelerated alignment, sorting, and dedup"
doc: |
  NVIDIA Parabricks fq2bam performs BWA-MEM alignment, coordinate sorting,
  and duplicate marking in a single GPU-accelerated step.
  Replaces bwa-mem2 + samtools sort + samtools markdup.

$namespaces:
  cwltool: "http://commonwl.org/cwltool#"

requirements:
  ResourceRequirement:
    coresMin: 8
    ramMin: 32768
  ShellCommandRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - entryname: run-fq2bam.sh
        entry: |
          #!/bin/bash
          set -eo pipefail
          REF="$1"
          FWD="$2"
          SID="$3"
          NGPU="$4"
          REV="$5"
          RG="@RG\tID:$SID\tSM:$SID\tPL:ILLUMINA\tPU:$SID\tLB:$SID"
          if [ -n "$REV" ] && [ -e "$REV" ]; then
            pbrun fq2bam --ref "$REF" --in-fq "$FWD" "$REV" "$RG" --out-bam "$SID".dedup.bam --out-duplicate-metrics "$SID".dup_metrics.txt --num-gpus "$NGPU"
          else
            pbrun fq2bam --ref "$REF" --in-se-fq "$FWD" "$RG" --out-bam "$SID".dedup.bam --out-duplicate-metrics "$SID".dup_metrics.txt --num-gpus "$NGPU"
          fi

hints:
  DockerRequirement:
    dockerPull: "nvcr.io/nvidia/clara/clara-parabricks:4.3.1-1"
  cwltool:CUDARequirement:
    cudaVersionMin: "11.0"
    cudaComputeCapability: "7.0"
    cudaDeviceCountMin: 1
    cudaDeviceCountMax: 4

baseCommand: [bash, run-fq2bam.sh]

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
      position: 1
    doc: "Reference genome FASTA with BWA index files"

  fastq_fwd:
    type: File
    inputBinding:
      position: 2
    doc: "Forward read FASTQ"

  sample_id:
    type: string
    inputBinding:
      position: 3
    doc: "Sample identifier for read group and output naming"

  num_gpus:
    type: int?
    default: 1
    inputBinding:
      position: 4
    doc: "Number of GPUs to use"

  fastq_rev:
    type: File?
    inputBinding:
      position: 5
    doc: "Reverse read FASTQ (omit for single-end)"

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
