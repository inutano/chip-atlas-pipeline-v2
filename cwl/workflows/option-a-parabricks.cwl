#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: Workflow

label: "ChIP-Atlas Option A - Parabricks GPU-Accelerated"
doc: |
  ChIP-Atlas v2 primary processing pipeline (Option A: Parabricks GPU variant).
  Uses NVIDIA Parabricks fq2bam for GPU-accelerated alignment, sorting, and
  duplicate marking in a single step, replacing bwa-mem2 + samtools sort + markdup.
  Peaks called WITHOUT background/input control (ChIP-Atlas policy).

  Steps: SRA download → Parabricks fq2bam (align+sort+dedup)
         → bedtools genomecov → bedGraphToBigWig → MACS3 callpeak (×3 thresholds)
         → bedToBigBed

$namespaces:
  cwltool: "http://commonwl.org/cwltool#"

requirements:
  SubworkflowFeatureRequirement: {}
  MultipleInputFeatureRequirement: {}
  StepInputExpressionRequirement: {}

inputs:
  sample_id:
    type: string
    doc: "Experiment accession (e.g., SRX12345678)"

  fastq_fwd:
    type: File
    doc: "Forward read FASTQ"

  fastq_rev:
    type: File?
    doc: "Reverse read FASTQ (omit for single-end)"

  genome_fasta:
    type: File
    secondaryFiles:
      - .fai
      - .amb
      - .ann
      - .bwt
      - .pac
      - .sa
    doc: "Reference genome FASTA with BWA index (standard BWA, not BWA-MEM2)"

  chrom_sizes:
    type: File
    doc: "Chromosome sizes file for BigWig/BigBed conversion"

  genome_size:
    type: string
    doc: "Effective genome size for MACS3 (hs, mm, ce, dm, or number)"

  format:
    type: string?
    default: "BAM"
    doc: "MACS3 input format. Always use BAM (single-read mode) — BAMPE requires properly-paired fragments which fails on mixed/mislabeled data. With --nomodel --extsize 200, BAM mode is consistent across SE and PE samples."

  num_gpus:
    type: int?
    default: 1
    doc: "Number of GPUs to use for Parabricks fq2bam"

steps:
  # =====================
  # Step 1: GPU-accelerated alignment + sort + dedup (Parabricks fq2bam)
  # =====================
  fq2bam:
    run: ../tools/parabricks-fq2bam.cwl
    in:
      genome_fasta: genome_fasta
      fastq_fwd: fastq_fwd
      fastq_rev: fastq_rev
      sample_id: sample_id
      num_gpus: num_gpus
    out: [dedup_bam, duplicate_metrics]

  # =====================
  # Step 2: Count mapped reads (for RPM normalization)
  # =====================
  count_reads:
    run: ../tools/samtools-mapped-count.cwl
    in:
      bam: fq2bam/dedup_bam
    out: [count_file]

  # =====================
  # Step 3: Generate BedGraph coverage (RPM-normalized)
  # =====================
  genomecov:
    run: ../tools/bedtools-genomecov.cwl
    in:
      bam: fq2bam/dedup_bam
      sample_id: sample_id
      count_file: count_reads/count_file
    out: [bedgraph]

  # =====================
  # Step 4: Convert BedGraph to BigWig
  # =====================
  bigwig:
    run: ../tools/bedgraphtobigwig.cwl
    in:
      bedgraph: genomecov/bedgraph
      chrom_sizes: chrom_sizes
      sample_id: sample_id
    out: [bigwig]

  # =====================
  # Step 5a: Peak calling (q-value 1e-05)
  # =====================
  macs3_q05:
    run: ../tools/macs3-callpeak.cwl
    in:
      treatment_bam: fq2bam/dedup_bam
      sample_id:
        source: sample_id
        valueFrom: $(self).05
      genome_size: genome_size
      qvalue:
        default: "1e-05"
      format: format
      nomodel:
        default: true
    out: [narrow_peaks, summits, xls]

  # =====================
  # Step 5b: Peak calling (q-value 1e-10)
  # =====================
  macs3_q10:
    run: ../tools/macs3-callpeak.cwl
    in:
      treatment_bam: fq2bam/dedup_bam
      sample_id:
        source: sample_id
        valueFrom: $(self).10
      genome_size: genome_size
      qvalue:
        default: "1e-10"
      format: format
      nomodel:
        default: true
    out: [narrow_peaks, summits, xls]

  # =====================
  # Step 5c: Peak calling (q-value 1e-20)
  # =====================
  macs3_q20:
    run: ../tools/macs3-callpeak.cwl
    in:
      treatment_bam: fq2bam/dedup_bam
      sample_id:
        source: sample_id
        valueFrom: $(self).20
      genome_size: genome_size
      qvalue:
        default: "1e-20"
      format: format
      nomodel:
        default: true
    out: [narrow_peaks, summits, xls]

  # =====================
  # Step 6a: BED to BigBed (q05)
  # =====================
  bigbed_q05:
    run: ../tools/bedtobigbed.cwl
    in:
      bed: macs3_q05/narrow_peaks
      chrom_sizes: chrom_sizes
      sample_id:
        source: sample_id
        valueFrom: $(self).05
    out: [bigbed]

  # =====================
  # Step 6b: BED to BigBed (q10)
  # =====================
  bigbed_q10:
    run: ../tools/bedtobigbed.cwl
    in:
      bed: macs3_q10/narrow_peaks
      chrom_sizes: chrom_sizes
      sample_id:
        source: sample_id
        valueFrom: $(self).10
    out: [bigbed]

  # =====================
  # Step 6c: BED to BigBed (q20)
  # =====================
  bigbed_q20:
    run: ../tools/bedtobigbed.cwl
    in:
      bed: macs3_q20/narrow_peaks
      chrom_sizes: chrom_sizes
      sample_id:
        source: sample_id
        valueFrom: $(self).20
    out: [bigbed]

outputs:
  bw:
    type: File
    outputSource: bigwig/bigwig
    doc: "RPM-normalized BigWig coverage track"

  peaks_q05:
    type: File?
    outputSource: macs3_q05/narrow_peaks
    doc: "Peak calls at q-value 1e-05"

  peaks_q10:
    type: File?
    outputSource: macs3_q10/narrow_peaks
    doc: "Peak calls at q-value 1e-10"

  peaks_q20:
    type: File?
    outputSource: macs3_q20/narrow_peaks
    doc: "Peak calls at q-value 1e-20"

  bb_q05:
    type: File?
    outputSource: bigbed_q05/bigbed
    doc: "BigBed at q-value 1e-05"

  bb_q10:
    type: File?
    outputSource: bigbed_q10/bigbed
    doc: "BigBed at q-value 1e-10"

  bb_q20:
    type: File?
    outputSource: bigbed_q20/bigbed
    doc: "BigBed at q-value 1e-20"

  dedup_bam:
    type: File
    outputSource: fq2bam/dedup_bam
    doc: "Deduplicated BAM file"

  duplicate_metrics:
    type: File
    outputSource: fq2bam/duplicate_metrics
    doc: "Parabricks duplicate marking statistics"

  peaks_xls_q05:
    type: File
    outputSource: macs3_q05/xls
    doc: "MACS3 statistics at q-value 1e-05"

  peaks_xls_q10:
    type: File
    outputSource: macs3_q10/xls
    doc: "MACS3 statistics at q-value 1e-10"

  peaks_xls_q20:
    type: File
    outputSource: macs3_q20/xls
    doc: "MACS3 statistics at q-value 1e-20"
