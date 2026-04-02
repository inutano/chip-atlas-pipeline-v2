#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: Workflow

label: "ChIP-Atlas Option B - Modern"
doc: |
  ChIP-Atlas v2 primary processing pipeline (Option B: Modern).
  Adds QC/trimming (fastp) and uses deeptools for coverage tracks.
  Peak calling with MACS3 --nomodel for all types (same as Option A-nomodel
  for now; experiment-type-specific callers like HMMRATAC can be added later).

  Steps: FASTQ → fastp trim → BWA-MEM2 align → name-sort → fixmate
         → coord-sort → markdup → deeptools bamCoverage (BigWig)
         → MACS3 callpeak (×3 thresholds) → bedToBigBed

  Key differences from Option A:
    - fastp QC/trimming before alignment
    - deeptools bamCoverage for BigWig (replaces bedtools genomecov + bedGraphToBigWig)

requirements:
  - class: SubworkflowFeatureRequirement
  - class: MultipleInputFeatureRequirement
  - class: StepInputExpressionRequirement

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
      - pattern: ".0123"
      - pattern: .amb
      - pattern: .ann
      - pattern: .bwt.2bit.64
      - pattern: .pac
    doc: "Reference genome FASTA with BWA-MEM2 index"

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

steps:
  # =====================
  # Step 1: QC + Trimming (NEW in Option B)
  # =====================
  trim:
    run: ../tools/fastp.cwl
    in:
      fastq_fwd: fastq_fwd
      fastq_rev: fastq_rev
      sample_id: sample_id
    out: [trimmed_fwd, trimmed_rev, json_report, html_report]

  # =====================
  # Step 2: Alignment
  # =====================
  align:
    run: ../tools/bwa-mem2-align.cwl
    in:
      genome_fasta: genome_fasta
      fastq_fwd: trim/trimmed_fwd
      fastq_rev: trim/trimmed_rev
      sample_id: sample_id
    out: [aligned_sam]

  # =====================
  # Step 3: Name-sort for fixmate
  # =====================
  name_sort:
    run: ../tools/samtools-sort.cwl
    in:
      input_file: align/aligned_sam
      sample_id: sample_id
      by_name:
        default: true
    out: [sorted_bam]

  # =====================
  # Step 4: Add mate score tags
  # =====================
  fixmate:
    run: ../tools/samtools-fixmate.cwl
    in:
      bam: name_sort/sorted_bam
      sample_id: sample_id
    out: [fixmate_bam]

  # =====================
  # Step 5: Coordinate-sort and index
  # =====================
  coord_sort:
    run: ../tools/samtools-sort.cwl
    in:
      input_file: fixmate/fixmate_bam
      sample_id: sample_id
      by_name:
        default: false
    out: [sorted_bam]

  # =====================
  # Step 6: Remove duplicates
  # =====================
  markdup:
    run: ../tools/samtools-markdup.cwl
    in:
      sorted_bam: coord_sort/sorted_bam
      sample_id: sample_id
    out: [dedup_bam]

  # =====================
  # Step 7: Generate BigWig with deeptools (NEW in Option B)
  # =====================
  bamcoverage:
    run: ../tools/deeptools-bamcoverage.cwl
    in:
      bam: markdup/dedup_bam
      sample_id: sample_id
    out: [bigwig]

  # =====================
  # Step 8a: Peak calling (q-value 1e-05)
  # =====================
  macs3_q05:
    run: ../tools/macs3-callpeak.cwl
    in:
      treatment_bam: markdup/dedup_bam
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
  # Step 8b: Peak calling (q-value 1e-10)
  # =====================
  macs3_q10:
    run: ../tools/macs3-callpeak.cwl
    in:
      treatment_bam: markdup/dedup_bam
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
  # Step 8c: Peak calling (q-value 1e-20)
  # =====================
  macs3_q20:
    run: ../tools/macs3-callpeak.cwl
    in:
      treatment_bam: markdup/dedup_bam
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
  # Step 9a: BED to BigBed (q05)
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
  # Step 9b: BED to BigBed (q10)
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
  # Step 9c: BED to BigBed (q20)
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
    outputSource: markdup/dedup_bam
    doc: "Deduplicated BAM file"

  peaks_xls_q05:
    type: File?
    outputSource: macs3_q05/xls
    doc: "MACS3 statistics at q-value 1e-05"

  peaks_xls_q10:
    type: File?
    outputSource: macs3_q10/xls
    doc: "MACS3 statistics at q-value 1e-10"

  peaks_xls_q20:
    type: File?
    outputSource: macs3_q20/xls
    doc: "MACS3 statistics at q-value 1e-20"

  fastp_json:
    type: File
    outputSource: trim/json_report
    doc: "fastp QC report (JSON)"

  fastp_html:
    type: File
    outputSource: trim/html_report
    doc: "fastp QC report (HTML)"
