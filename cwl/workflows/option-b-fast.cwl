#!/usr/bin/env cwl-runner
cwlVersion: v1.2
class: CommandLineTool

label: "ChIP-Atlas Option B Fast — Optimized single-pass pipeline"
doc: |
  Optimized version of Option B that uses pipe-through processing,
  parallel post-markdup steps, and single MACS3 call with threshold
  filtering. Expects all bioinformatics tools installed in the container
  or available on the host.

  Optimizations:
    1. Piped: fastp → bwa-mem2 → samtools chain (no intermediate files)
    2. Parallel: bamCoverage + MACS3 run concurrently after markdup
    3. Single MACS3 at q=1e-05, then awk filter for 1e-10 and 1e-20
    4. Parallel BigBed conversion

requirements:
  - class: ResourceRequirement
    coresMin: 16
    ramMin: 32768
  - class: ShellCommandRequirement
  - class: NetworkAccess
    networkAccess: false
  - class: InitialWorkDirRequirement
    listing:
      - entryname: run-pipeline.sh
        entry: |
          #!/bin/bash
          set -eo pipefail
          SID="$1"; FWD="$2"; REV="$3"; FA="$4"; CHROM="$5"; GSIZE="$6"
          THREADS=$7; OUTDIR="$8"
          mkdir -p "$OUTDIR"
          DEDUP="$OUTDIR/$SID.dedup.bam"
          RG="@RG\tID:$SID\tSM:$SID\tPL:ILLUMINA"
          AT=$((THREADS - 4)); ST=4; SM="2G"

          # --- Step 1: Piped alignment ---
          FASTP_ARGS="--in1 $FWD --stdout --json $OUTDIR/${SID}_fastp.json --html $OUTDIR/${SID}_fastp.html --thread 4"
          if [ -n "$REV" ] && [ -e "$REV" ]; then FASTP_ARGS="--in1 $FWD --in2 $REV $FASTP_ARGS"; fi
          fastp $FASTP_ARGS 2>/dev/null \
            | bwa-mem2 mem -t $AT -R "$RG" -p "$FA" - 2>/dev/null \
            | samtools sort -n -@ $ST -m $SM - \
            | samtools fixmate -m - - \
            | samtools sort -@ $ST -m $SM - \
            | samtools markdup -r - "$DEDUP"
          samtools index "$DEDUP"

          # --- Step 2: Parallel bamCoverage + MACS3 ---
          bamCoverage -b "$DEDUP" -o "$OUTDIR/$SID.bw" --binSize 1 --normalizeUsing RPKM -p $((THREADS/2)) 2>/dev/null &
          PID_BC=$!
          macs3 callpeak -t "$DEDUP" -n "$SID" -g "$GSIZE" -q 1e-05 -f BAM --outdir "$OUTDIR" 2>/dev/null || true
          wait $PID_BC || true

          # --- Step 3: Filter + BigBed ---
          PEAKS="$OUTDIR/${SID}_peaks.narrowPeak"
          if [ -f "$PEAKS" ]; then
            mv "$PEAKS" "$OUTDIR/$SID.05_peaks.narrowPeak"
            mv "$OUTDIR/${SID}_peaks.xls" "$OUTDIR/$SID.05_peaks.xls" 2>/dev/null || true
            awk '$$9 >= 10' "$OUTDIR/$SID.05_peaks.narrowPeak" > "$OUTDIR/$SID.10_peaks.narrowPeak"
            awk '$$9 >= 20' "$OUTDIR/$SID.05_peaks.narrowPeak" > "$OUTDIR/$SID.20_peaks.narrowPeak"
            for q in 05 10 20; do
              BED="$OUTDIR/$SID.${q}_peaks.narrowPeak"
              if [ -s "$BED" ]; then
                (cut -f1-4 "$BED" | sort -k1,1 -k2,2n > "$OUTDIR/t$q.bed" \
                  && bedToBigBed "$OUTDIR/t$q.bed" "$CHROM" "$OUTDIR/$SID.$q.bb" \
                  && rm "$OUTDIR/t$q.bed") &
              fi
            done
            wait
          fi
          rm -f "$DEDUP" "$DEDUP.bai" "$OUTDIR/${SID}_summits.bed"

hints:
  - class: DockerRequirement
    dockerPull: "ghcr.io/inutano/chip-atlas-pipeline-v2:latest"

baseCommand: [bash, run-pipeline.sh]

inputs:
  sample_id:
    type: string
    inputBinding:
      position: 1
    doc: "Experiment accession"

  fastq_fwd:
    type: File
    inputBinding:
      position: 2
    doc: "Forward read FASTQ"

  fastq_rev:
    type: File?
    inputBinding:
      position: 3
    doc: "Reverse read FASTQ (omit for single-end)"

  genome_fasta:
    type: File
    secondaryFiles:
      - pattern: ".0123"
      - pattern: .amb
      - pattern: .ann
      - pattern: .bwt.2bit.64
      - pattern: .pac
    inputBinding:
      position: 4
    doc: "Reference genome FASTA with BWA-MEM2 index"

  chrom_sizes:
    type: File
    inputBinding:
      position: 5
    doc: "Chromosome sizes file"

  genome_size:
    type: string
    inputBinding:
      position: 6
    doc: "Effective genome size for MACS3"

  threads:
    type: int?
    default: 16
    inputBinding:
      position: 7
    doc: "Number of threads"

  outdir:
    type: string?
    default: "output"
    inputBinding:
      position: 8
    doc: "Output directory name"

outputs:
  bw:
    type: File?
    outputBinding:
      glob: "output/*.bw"

  peaks_q05:
    type: File?
    outputBinding:
      glob: "output/*.05_peaks.narrowPeak"

  peaks_q10:
    type: File?
    outputBinding:
      glob: "output/*.10_peaks.narrowPeak"

  peaks_q20:
    type: File?
    outputBinding:
      glob: "output/*.20_peaks.narrowPeak"

  bb_q05:
    type: File?
    outputBinding:
      glob: "output/*.05.bb"

  bb_q10:
    type: File?
    outputBinding:
      glob: "output/*.10.bb"

  bb_q20:
    type: File?
    outputBinding:
      glob: "output/*.20.bb"

  fastp_json:
    type: File?
    outputBinding:
      glob: "output/*_fastp.json"

  fastp_html:
    type: File?
    outputBinding:
      glob: "output/*_fastp.html"

  peaks_xls_q05:
    type: File?
    outputBinding:
      glob: "output/*.05_peaks.xls"
