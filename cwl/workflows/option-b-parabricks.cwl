#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: Workflow

label: "ChIP-Atlas Option B - Modern + Parabricks GPU"
doc: |
  ChIP-Atlas v2 primary processing pipeline combining Option B (Modern)
  with Parabricks GPU acceleration.
  - fastp QC/trimming before alignment
  - Parabricks fq2bam for GPU-accelerated align+sort+dedup
  - deeptools bamCoverage for BigWig
  - MACS3 --nomodel peak calling

  Steps: FASTQ → fastp trim → Parabricks fq2bam (GPU align+sort+dedup)
         → deeptools bamCoverage (BigWig) → MACS3 callpeak (×3 thresholds)
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
    doc: "Chromosome sizes file for BigBed conversion"

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
  # Step 1: QC + Trimming (fastp)
  # =====================
  trim:
    run: ../tools/fastp.cwl
    in:
      fastq_fwd: fastq_fwd
      fastq_rev: fastq_rev
      sample_id: sample_id
    out: [trimmed_fwd, trimmed_rev, json_report, html_report]

  # =====================
  # Step 2: GPU-accelerated alignment + sort + dedup
  # =====================
  fq2bam:
    run: ../tools/parabricks-fq2bam.cwl
    in:
      genome_fasta: genome_fasta
      fastq_fwd: trim/trimmed_fwd
      fastq_rev: trim/trimmed_rev
      sample_id: sample_id
      num_gpus: num_gpus
    out: [dedup_bam, duplicate_metrics]

  # =====================
  # Step 3: Generate BigWig with deeptools
  # =====================
  bamcoverage:
    run: ../tools/deeptools-bamcoverage.cwl
    in:
      bam: fq2bam/dedup_bam
      sample_id: sample_id
    out: [bigwig]

  # =====================
  # Step 4a: Peak calling (q-value 1e-05)
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
  # Step 4b: Peak calling (q-value 1e-10)
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
  # Step 4c: Peak calling (q-value 1e-20)
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
  # Step 5a: BED to BigBed (q05)
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
  # Step 5b: BED to BigBed (q10)
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
  # Step 5c: BED to BigBed (q20)
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
    outputSource: bamcoverage/bigwig
    doc: "Normalized BigWig coverage track (deeptools)"

  peaks_q05:
    type: File?
    outputSource: macs3_q05/narrow_peaks

  peaks_q10:
    type: File?
    outputSource: macs3_q10/narrow_peaks

  peaks_q20:
    type: File?
    outputSource: macs3_q20/narrow_peaks

  bb_q05:
    type: File?
    outputSource: bigbed_q05/bigbed

  bb_q10:
    type: File?
    outputSource: bigbed_q10/bigbed

  bb_q20:
    type: File?
    outputSource: bigbed_q20/bigbed

  dedup_bam:
    type: File
    outputSource: fq2bam/dedup_bam

  duplicate_metrics:
    type: File
    outputSource: fq2bam/duplicate_metrics

  peaks_xls_q05:
    type: File?
    outputSource: macs3_q05/xls

  peaks_xls_q10:
    type: File?
    outputSource: macs3_q10/xls

  peaks_xls_q20:
    type: File?
    outputSource: macs3_q20/xls

  fastp_json:
    type: File
    outputSource: trim/json_report

  fastp_html:
    type: File
    outputSource: trim/html_report
