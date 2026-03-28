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

hints:
  DockerRequirement:
    dockerPull: "nvcr.io/nvidia/clara/clara-parabricks:4.3.1-1"
  cwltool:CUDARequirement:
    cudaVersionMin: "11.0"
    cudaComputeCapability: "7.0"
    cudaDeviceCountMin: 1
    cudaDeviceCountMax: 4

baseCommand: []

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
    doc: "Number of GPUs to use"

arguments:
  - shellQuote: false
    valueFrom: |
      RG="@RG\tID:$(inputs.sample_id)\tSM:$(inputs.sample_id)\tPL:ILLUMINA\tPU:$(inputs.sample_id)\tLB:$(inputs.sample_id)"
      REV="$(inputs.fastq_rev.path)"
      if [ "\$REV" != "null" ] && [ "\$REV" != "" ] && [ -e "\$REV" ]; then
        pbrun fq2bam --ref $(inputs.genome_fasta.path) --in-fq $(inputs.fastq_fwd.path) "\$REV" "\$RG" --out-bam $(inputs.sample_id).dedup.bam --out-duplicate-metrics $(inputs.sample_id).dup_metrics.txt --num-gpus $(inputs.num_gpus)
      else
        pbrun fq2bam --ref $(inputs.genome_fasta.path) --in-se-fq $(inputs.fastq_fwd.path) "\$RG" --out-bam $(inputs.sample_id).dedup.bam --out-duplicate-metrics $(inputs.sample_id).dup_metrics.txt --num-gpus $(inputs.num_gpus)
      fi

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
