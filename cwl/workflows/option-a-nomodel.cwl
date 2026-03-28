#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: Workflow

label: "ChIP-Atlas Option A - Fast Classic (--nomodel)"
doc: |
  ChIP-Atlas v2 primary processing pipeline (Option A: Fast Classic).
  Same as option-a.cwl but with --nomodel --extsize 200 for MACS3.
  Skips fragment size model building to avoid failures on low-signal samples.

  Steps: SRA download → BWA-MEM2 align → name-sort → fixmate → coord-sort
         → markdup → bedtools genomecov → bedGraphToBigWig
         → MACS3 callpeak (×3 thresholds) → bedToBigBed

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
      - pattern: ".0123"
      - pattern: .amb
      - pattern: .ann
      - pattern: .bwt.2bit.64
      - pattern: .pac
    doc: "Reference genome FASTA with BWA-MEM2 index"

  chrom_sizes:
    type: File
    doc: "Chromosome sizes file for BigWig/BigBed conversion"

  genome_size:
    type: string
    doc: "Effective genome size for MACS3 (hs, mm, ce, dm, or number)"

  format:
    type: string?
    default: "BAM"
    doc: "MACS3 input format (BAM for single-end, BAMPE for paired-end)"

steps:
  # =====================
  # Step 1: Alignment
  # =====================
  align:
    run: ../tools/bwa-mem2-align.cwl
    in:
      genome_fasta: genome_fasta
      fastq_fwd: fastq_fwd
      fastq_rev: fastq_rev
      sample_id: sample_id
    out: [aligned_sam]

  # =====================
  # Step 2: Name-sort for fixmate
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
  # Step 3: Add mate score tags
  # =====================
  fixmate:
    run: ../tools/samtools-fixmate.cwl
    in:
      bam: name_sort/sorted_bam
      sample_id: sample_id
    out: [fixmate_bam]

  # =====================
  # Step 4: Coordinate-sort and index
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
  # Step 5: Remove duplicates
  # =====================
  markdup:
    run: ../tools/samtools-markdup.cwl
    in:
      sorted_bam: coord_sort/sorted_bam
      sample_id: sample_id
    out: [dedup_bam]

  # =====================
  # Step 4: Count mapped reads (for RPM normalization)
  # =====================
  count_reads:
    run: ../tools/samtools-mapped-count.cwl
    in:
      bam: markdup/dedup_bam
    out: [count_file]

  # =====================
  # Step 5: Generate BedGraph coverage (RPM-normalized)
  # =====================
  genomecov:
    run: ../tools/bedtools-genomecov.cwl
    in:
      bam: markdup/dedup_bam
      sample_id: sample_id
      count_file: count_reads/count_file
    out: [bedgraph]

  # =====================
  # Step 6: Convert BedGraph to BigWig
  # =====================
  bigwig:
    run: ../tools/bedgraphtobigwig.cwl
    in:
      bedgraph: genomecov/bedgraph
      chrom_sizes: chrom_sizes
      sample_id: sample_id
    out: [bigwig]

  # =====================
  # Step 7a: Peak calling (q-value 1e-05)
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
  # Step 7b: Peak calling (q-value 1e-10)
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
  # Step 7c: Peak calling (q-value 1e-20)
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
  # Step 8a: BED to BigBed (q05)
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
  # Step 8b: BED to BigBed (q10)
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
  # Step 8c: BED to BigBed (q20)
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
