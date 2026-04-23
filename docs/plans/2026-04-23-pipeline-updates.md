# Pipeline Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update both ChIP-seq and BS-seq pipelines to handle SE/PE correctly, use proper MACS3 format flags, add fastp to BS-seq, and output v1-compatible statistics.

**Architecture:** Modify the two existing pipeline shell scripts in-place. Add fastp to the BS-seq container. No new files — all changes are to `scripts/pipeline-v2.sh`, `scripts/pipeline-v2-bs.sh`, and `containers/Dockerfile.bs`.

**Tech Stack:** Bash, fastp, bwa-mem2, samtools, MACS3, DNMTools (abismal), bedtools, UCSC tools

---

## File Structure

| File | Changes |
|------|---------|
| `scripts/pipeline-v2.sh` | SE/PE pipe branching, BAMPE for PE MACS3, stats output |
| `scripts/pipeline-v2-bs.sh` | Add fastp via named pipes, add `--genome` arg, stats output |
| `containers/Dockerfile.bs` | Add `fastp=1.3.1` to mamba install |

---

### Task 1: Add fastp to the BS-seq container

**Files:**
- Modify: `containers/Dockerfile.bs`

- [ ] **Step 1: Add fastp to Dockerfile.bs**

```dockerfile
RUN mamba install -y -c bioconda -c conda-forge \
    dnmtools=1.5.1 \
    samtools=1.22.1 \
    fastp=1.3.1 \
    ucsc-bedgraphtobigwig=482 \
    && mamba clean -afy
```

Also update the versions.sh script to include fastp:

```dockerfile
RUN printf '#!/bin/bash\n\
echo "fastp $(fastp --version 2>&1)"\n\
echo "dnmtools $(dnmtools 2>&1 | grep -i version | head -1)"\n\
echo "samtools $(samtools --version | head -1)"\n\
echo "bedGraphToBigWig $(bedGraphToBigWig 2>&1 | head -1)"\n' > /usr/local/bin/versions.sh \
    && chmod +x /usr/local/bin/versions.sh
```

- [ ] **Step 2: Build and verify**

```bash
cd /home/inutano/repos/chip-atlas-pipeline-v2
docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0 \
  -f containers/Dockerfile.bs containers/
docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0 versions.sh
```

Expected: fastp 1.3.1 listed alongside dnmtools 1.5.1, samtools 1.22.1.

- [ ] **Step 3: Commit**

```bash
git add containers/Dockerfile.bs
git commit -m "Add fastp to BS-seq container for QC/trimming step"
```

---

### Task 2: ChIP-seq — SE/PE pipe branching

**Files:**
- Modify: `scripts/pipeline-v2.sh:64-103`

The current pipeline always runs `collate → fixmate → sort → markdup`.
For SE reads, `collate` and `fixmate` are unnecessary (they handle mate
pair info). Skip them for SE.

- [ ] **Step 1: Add IS_PAIRED flag and branch the pipe**

Replace the current step 1 section (lines 75-103) with:

```bash
# ============================================================
# Step 1: Piped alignment
# ============================================================
DEDUP_BAM="$WORK/${SAMPLE_ID}.dedup.bam"
RG="@RG\\tID:${SAMPLE_ID}\\tSM:${SAMPLE_ID}\\tPL:ILLUMINA"

# Detect SE/PE and build fastp args
IS_PAIRED=false
FASTP_ARGS="--stdout --json $WORK/${SAMPLE_ID}_fastp.json --thread $FASTP_T"
if [ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ]; then
  IS_PAIRED=true
  FASTP_ARGS="--in1 $FASTQ_FWD --in2 $FASTQ_REV $FASTP_ARGS"
  BWA_INTERLEAVED="-p"
else
  FASTP_ARGS="--in1 $FASTQ_FWD $FASTP_ARGS"
  BWA_INTERLEAVED=""
fi

STEP1_START=$(date +%s)

if [ "$IS_PAIRED" = true ]; then
  log "Step 1 (PE): fastp → bwa-mem2 → collate → fixmate → sort → markdup"
  fastp $FASTP_ARGS 2>"$WORK/fastp.stderr" \
    | bwa-mem2 mem -t "$ALIGN_T" -R "$RG" -p "$GENOME_FA" - 2>"$WORK/bwamem2.stderr" \
    | samtools collate -O -T "$WORK/collate" - \
    | samtools fixmate -m - - \
    | samtools sort -@ "$SORT_T" -m "$SORT_MEM" -T "$WORK/sort" - \
    | samtools markdup -r - "$DEDUP_BAM"
else
  log "Step 1 (SE): fastp → bwa-mem2 → sort → markdup"
  fastp $FASTP_ARGS 2>"$WORK/fastp.stderr" \
    | bwa-mem2 mem -t "$ALIGN_T" -R "$RG" "$GENOME_FA" - 2>"$WORK/bwamem2.stderr" \
    | samtools sort -@ "$SORT_T" -m "$SORT_MEM" -T "$WORK/sort" - \
    | samtools markdup -r - "$DEDUP_BAM"
fi

STEP1_END=$(date +%s)
log "Step 1 done: $((STEP1_END - STEP1_START))s"
```

- [ ] **Step 2: Test with a PE sample**

```bash
# Use the existing SRX26106775 debug data (PE)
docker run --rm --user "$(id -u):$(id -g)" \
  -v /data3/chip-atlas-v2/debug-SRX26106775:/work \
  -v /data3/chip-atlas-v2/test-run/hg38:/ref:ro \
  -v /tmp:/tmp \
  ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 \
  bash /work/../../repos/chip-atlas-pipeline-v2/scripts/pipeline-v2.sh \
    --sample-id SRX26106775 \
    --fastq-fwd /work/fastq/SRR30689084_1.fastq.gz \
    --fastq-rev /work/fastq/SRR30689084_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --chrom-sizes /ref/chrom.sizes \
    --genome-size hs --outdir /tmp/test-pe --threads 8
```

Expected: logs show "Step 1 (PE)" with the full collate→fixmate pipe.

- [ ] **Step 3: Test with an SE sample**

Download a small SE sample, run, verify logs show "Step 1 (SE)" without
collate/fixmate.

- [ ] **Step 4: Commit**

```bash
git add scripts/pipeline-v2.sh
git commit -m "Skip collate/fixmate for single-end reads in ChIP-seq pipeline"
```

---

### Task 3: ChIP-seq — BAMPE for paired-end MACS3

**Files:**
- Modify: `scripts/pipeline-v2.sh:125-129`

Current MACS3 call uses `-f BAM` for all samples. For PE, use `-f BAMPE`
which uses actual insert size from proper pairs instead of model estimation.

- [ ] **Step 1: Set MACS3 format based on IS_PAIRED**

Replace the MACS3 callpeak block:

```bash
# MACS3 peak calling
if [ "$IS_PAIRED" = true ]; then
  MACS3_FMT="BAMPE"
else
  MACS3_FMT="BAM"
fi

macs3 callpeak \
  -t "$DEDUP_BAM" -n "${SAMPLE_ID}" -g "$GENOME_SIZE" \
  -q 1e-05 -f "$MACS3_FMT" --outdir "$WORK" \
  2>"$WORK/macs3.stderr" || true
```

- [ ] **Step 2: Test PE sample**

Re-run the PE test from Task 2. Verify `macs3.stderr` shows `format is BAMPE`.

- [ ] **Step 3: Commit**

```bash
git add scripts/pipeline-v2.sh
git commit -m "Use BAMPE format for paired-end MACS3 peak calling"
```

---

### Task 4: ChIP-seq — output statistics TSV

**Files:**
- Modify: `scripts/pipeline-v2.sh` (add section before final cleanup)

Add a stats output step that writes `{id}.stats.tsv` matching the v1 format.

- [ ] **Step 1: Add stats generation before cleanup**

Insert before the `rm -rf "$WORK"` line:

```bash
# ============================================================
# Output statistics (v1-compatible format)
# ============================================================
FASTP_JSON="$OUTDIR/${SAMPLE_ID}_fastp.json"
TOTAL_SEC=$(($(date +%s) - STEP1_START))

# Parse fastp JSON for read counts
if [ -f "$FASTP_JSON" ]; then
  READS_BEFORE=$(python3 -c "import json; d=json.load(open('$FASTP_JSON')); print(d['summary']['before_filtering']['total_reads'])" 2>/dev/null || echo 0)
  READS_AFTER=$(python3 -c "import json; d=json.load(open('$FASTP_JSON')); print(d['summary']['after_filtering']['total_reads'])" 2>/dev/null || echo 0)
else
  READS_BEFORE=0
  READS_AFTER=0
fi

# Mapping rate and dedup rate from the dedup BAM counts
# $MAPPED was set earlier by samtools view -c -F 4
if [ "$READS_AFTER" -gt 0 ]; then
  MAP_RATE=$(awk "BEGIN {printf \"%.1f\", $MAPPED / $READS_AFTER * 100}")
  DUP_RATE=$(awk "BEGIN {printf \"%.1f\", (1 - $MAPPED / $READS_AFTER) * 100}")
else
  MAP_RATE="0.0"
  DUP_RATE="0.0"
fi

# File sizes
FASTQ_SIZE=$(du -b "$FASTQ_FWD" 2>/dev/null | cut -f1 || echo 0)
[ -n "$FASTQ_REV" ] && [ -e "$FASTQ_REV" ] && FASTQ_SIZE=$((FASTQ_SIZE + $(du -b "$FASTQ_REV" | cut -f1)))
BW_SIZE=$(du -b "$OUTDIR/${SAMPLE_ID}.bw" 2>/dev/null | cut -f1 || echo 0)

# Peak counts
PEAKS_05_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.05_peaks.narrowPeak" 2>/dev/null || echo 0)
PEAKS_10_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.10_peaks.narrowPeak" 2>/dev/null || echo 0)
PEAKS_20_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.20_peaks.narrowPeak" 2>/dev/null || echo 0)

# SE=0, PE=1
LAYOUT_FLAG=0
[ "$IS_PAIRED" = true ] && LAYOUT_FLAG=1

# Write stats TSV (v1-compatible columns)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$SAMPLE_ID" \
  "$LAYOUT_FLAG" \
  "$FASTQ_SIZE" \
  "0" \
  "$READS_BEFORE" \
  "$READS_AFTER" \
  "$MAP_RATE" \
  "$DUP_RATE" \
  "0" \
  "0" \
  "$BW_SIZE" \
  "$PEAKS_05_N" \
  "$PEAKS_10_N" \
  "$PEAKS_20_N" \
  "$((TOTAL_SEC / 60))" \
  > "$OUTDIR/${SAMPLE_ID}.stats.tsv"

log "Stats: reads=$READS_BEFORE mapped=$MAPPED($MAP_RATE%) peaks=$PEAKS_05_N/$PEAKS_10_N/$PEAKS_20_N"
```

- [ ] **Step 2: Test and verify stats output**

Re-run the PE test. Verify `SRX26106775.stats.tsv` exists with 15 tab-separated columns.

```bash
cat /tmp/test-pe/SRX26106775.stats.tsv
```

- [ ] **Step 3: Commit**

```bash
git add scripts/pipeline-v2.sh
git commit -m "Add v1-compatible statistics output to ChIP-seq pipeline"
```

---

### Task 5: BS-seq — add fastp via named pipes

**Files:**
- Modify: `scripts/pipeline-v2-bs.sh:83-110`

Insert a fastp QC/trimming step before abismal. Use named pipes (FIFOs)
so fastp streams trimmed reads to abismal without writing to disk.

- [ ] **Step 1: Add fastp step with named pipes**

Replace the step 1 section (lines 83-110) with:

```bash
# ============================================================
# Step 0: fastp QC/trimming → named pipes for abismal
# ============================================================
log "Step 0: fastp QC/trimming"
T0=$(date +%s)

FASTP_JSON="$WORK/${SAMPLE_ID}_fastp.json"

if [ "$IS_PAIRED" = true ]; then
  # PE: fastp writes to two named pipes, abismal reads from them
  mkfifo "$WORK/trim_1.fq" "$WORK/trim_2.fq"
  fastp --in1 "$FASTQ_FWD" --in2 "$FASTQ_REV" \
    --out1 "$WORK/trim_1.fq" --out2 "$WORK/trim_2.fq" \
    --json "$FASTP_JSON" --thread 2 2>"$WORK/fastp.stderr" &
  PID_FASTP=$!
  ABISMAL_ARGS=("$WORK/trim_1.fq" "$WORK/trim_2.fq")
else
  # SE: abismal reads from process substitution
  ABISMAL_ARGS=()  # set below after fastp starts
  mkfifo "$WORK/trim.fq"
  fastp --in1 "$FASTQ_FWD" --out1 "$WORK/trim.fq" \
    --json "$FASTP_JSON" --thread 2 2>"$WORK/fastp.stderr" &
  PID_FASTP=$!
  ABISMAL_ARGS=("$WORK/trim.fq")
fi

log "  fastp: started (pid $PID_FASTP)"

# ============================================================
# Step 1: Sequential alignment + format + sort + dedup
# ============================================================
log "Step 1: abismal → format → sort → uniq → dedup BAM"
DEDUP_BAM="$WORK/${SAMPLE_ID}.dedup.bam"

STEP1_START=$(date +%s)

# 1a. abismal alignment (reads from fastp's named pipes)
T0=$(date +%s)
dnmtools abismal \
    -i "$ABISMAL_IDX" \
    -t "$THREADS" \
    -B \
    -o "$WORK/mapped.bam" \
    -s "$WORK/abismal.stats" \
    "${ABISMAL_ARGS[@]}" 2>"$WORK/abismal.stderr"

# Wait for fastp to finish and clean up pipes
wait $PID_FASTP || log "WARNING: fastp exited with error"
rm -f "$WORK/trim_1.fq" "$WORK/trim_2.fq" "$WORK/trim.fq"
log "  abismal: $(($(date +%s) - T0))s"
```

The rest of step 1 (format → sort → uniq) remains unchanged.

- [ ] **Step 2: Test with PE BS-seq sample**

Use the existing SRX22130352 test data:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v /home/inutano/work/bs-test-human:/work \
  -v /home/inutano/repos/chip-atlas-pipeline-v2/scripts/pipeline-v2-bs.sh:/pipeline.sh:ro \
  -v /tmp:/tmp -e TMPDIR=/tmp \
  ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0 \
  bash /pipeline.sh \
    --sample-id SRX22130352 \
    --fastq-fwd /work/fastq/SRR26425632_1.fastq.gz \
    --fastq-rev /work/fastq/SRR26425632_2.fastq.gz \
    --genome-fasta /work/hg38/hg38.fa \
    --abismal-index /work/hg38/hg38.abismal.idx \
    --chrom-sizes /work/hg38/chrom.sizes \
    --genome hg38 \
    --outdir /tmp/test-bs --threads 16
```

Expected: logs show "Step 0: fastp QC/trimming" before abismal. fastp.json
produced. Pipeline outputs match previous results (HMR/HyperMR/PMD counts
may differ slightly due to trimming).

- [ ] **Step 3: Commit**

```bash
git add scripts/pipeline-v2-bs.sh
git commit -m "Add fastp QC/trimming to BS-seq pipeline via named pipes"
```

---

### Task 6: BS-seq — add `--genome` argument and output statistics TSV

**Files:**
- Modify: `scripts/pipeline-v2-bs.sh` (argument parsing + new section before cleanup)

The stats calculation needs a genome-specific CpG count constant. Add a
`--genome` argument and a stats output step.

- [ ] **Step 1: Add --genome argument to parser**

Add to the argument parsing block:

```bash
    --genome)        GENOME="$2"; shift 2 ;;
```

Add to the required vars check:

```bash
for var in SAMPLE_ID FASTQ_FWD GENOME_FA ABISMAL_IDX CHROM_SIZES GENOME OUTDIR; do
```

Add the CpG count lookup after argument parsing:

```bash
# CpG counts per genome (fixed values for coverage calculation)
declare -A CPG_COUNTS=(
  [hg38]=61959486
  [mm10]=43816016
  [rn6]=53698106
  [ce11]=6263050
  [dm6]=11787346
  [sacCer3]=710598
)

CPG_COUNT="${CPG_COUNTS[$GENOME]:-0}"
if [ "$CPG_COUNT" -eq 0 ]; then
  log "WARNING: Unknown genome '$GENOME', CpG coverage will be 0"
fi
```

- [ ] **Step 2: Add stats generation before cleanup**

Insert before the `rm -rf "$WORK"` line:

```bash
# ============================================================
# Output statistics (v1-compatible format)
# ============================================================
TOTAL_SEC=$(($(date +%s) - STEP1_START))

# Parse abismal.stats (YAML) for read count and mapping rate
if [ "$IS_PAIRED" = true ]; then
  READ_COUNT=$(grep "total_pairs:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')
  MAP_RATE=$(grep "percent_mapped:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')
else
  READ_COUNT=$(grep "total_reads:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')
  MAP_RATE=$(grep "percent_mapped:" "$WORK/abismal.stats" | head -1 | awk '{print $2}')
fi

# Methylation rate and CpG coverage from counts.tsv
# counts.tsv columns: chrom, pos, strand, context, meth_fraction, read_count
METH_STATS=$(awk -F'\t' -v cpg="$CPG_COUNT" '{
  met += $6 * $5
  total += $6
} END {
  if (total > 0) printf "%.1f\t%.1f", met / total * 100, total / cpg
  else printf "0.0\t0.0"
}' "$WORK/counts.tsv")
METH_RATE=$(echo "$METH_STATS" | cut -f1)
CPG_COVERAGE=$(echo "$METH_STATS" | cut -f2)

# Region counts
HMR_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.hmr.bed" 2>/dev/null || echo 0)
PMD_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.pmd.bed" 2>/dev/null || echo 0)
HYPERMR_N=$(wc -l < "$OUTDIR/${SAMPLE_ID}.hypermr.bed" 2>/dev/null || echo 0)

# File sizes
FASTQ_SIZE=$(du -b "$FASTQ_FWD" 2>/dev/null | cut -f1 || echo 0)
[ "$IS_PAIRED" = true ] && [ -e "$FASTQ_REV" ] && FASTQ_SIZE=$((FASTQ_SIZE + $(du -b "$FASTQ_REV" | cut -f1)))

# SE=0, PE=1
LAYOUT_FLAG=0
[ "$IS_PAIRED" = true ] && LAYOUT_FLAG=1

# Write stats TSV (v1-compatible columns)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t\t%s\n' \
  "$SAMPLE_ID" \
  "$LAYOUT_FLAG" \
  "$FASTQ_SIZE" \
  "0" \
  "$READ_COUNT" \
  "$MAP_RATE" \
  "$METH_RATE" \
  "$CPG_COVERAGE" \
  "$HMR_N" \
  "$PMD_N" \
  "$HYPERMR_N" \
  "$((TOTAL_SEC / 60))" \
  > "$OUTDIR/${SAMPLE_ID}.stats.tsv"

log "Stats: reads=$READ_COUNT mapped=$MAP_RATE% meth=$METH_RATE% coverage=$CPG_COVERAGE hmr=$HMR_N pmd=$PMD_N hypermr=$HYPERMR_N"
```

- [ ] **Step 3: Also copy fastp.json to output dir**

Add after the fastp stats line, alongside the existing abismal.stats copy:

```bash
cp "$WORK/abismal.stats" "$OUTDIR/${SAMPLE_ID}.abismal.stats" 2>/dev/null || true
cp "$FASTP_JSON" "$OUTDIR/${SAMPLE_ID}_fastp.json" 2>/dev/null || true
```

- [ ] **Step 4: Test and verify stats output**

Re-run the BS-seq test with `--genome hg38`. Verify `SRX22130352.stats.tsv`
exists with the expected columns.

```bash
cat /tmp/test-bs/SRX22130352.stats.tsv
```

Expected: tab-separated line with SRX, layout, sizes, read count, mapping
rate, methylation rate, CpG coverage, region counts, time.

- [ ] **Step 5: Commit**

```bash
git add scripts/pipeline-v2-bs.sh
git commit -m "Add --genome arg and v1-compatible statistics to BS-seq pipeline"
```

---

### Task 7: Update scripts/README.md

**Files:**
- Modify: `scripts/README.md`

Update documentation to reflect all changes:

- [ ] **Step 1: Update ChIP-seq section**

- Processing steps diagram: show SE vs PE branching
- Step 1 tool options: document the SE pipe (no collate/fixmate)
- Step 2 tool options: document BAMPE vs BAM for MACS3
- Outputs table: add `{id}.stats.tsv`
- Add `IS_PAIRED` detection note

- [ ] **Step 2: Update BS-seq section**

- Processing steps diagram: add fastp step 0 with named pipes
- Tool table: add fastp 1.3.1
- Arguments table: add `--genome`
- Outputs table: add `{id}.stats.tsv`, `{id}_fastp.json`
- Container table: update BS-seq to v1.1.0, add fastp

- [ ] **Step 3: Commit**

```bash
git add scripts/README.md
git commit -m "Update README with SE/PE branching, BAMPE, fastp, stats output docs"
```

---

## Self-Review

**Spec coverage check against `chip-atlas-v2-20260423.md`:**

| Requirement | Task |
|-------------|------|
| BS-seq: include fastp step | Task 5 (named pipes) |
| BS-seq: check PE handling | Task 5 (verified, existing IS_PAIRED logic correct) |
| BS-seq: output statistics | Task 6 (stats TSV with meth rate, coverage, region counts) |
| ChIP-seq: skip collate/fixmate for SE | Task 2 (pipe branching) |
| ChIP-seq: BAMPE for PE | Task 3 (MACS3 format flag) |
| ChIP-seq: output statistics | Task 4 (stats TSV with read counts, mapping, peaks) |
| fastp in BS-seq container | Task 1 (Dockerfile.bs) |
| README updates | Task 7 |

**Not in scope** (discussion questions, not code changes):
- 4 cores/job for smaller genomes → answered in the plan discussion (yes, it works)
- samtools sort memory behavior → answered in the plan discussion
- ENA/SRA currency survey → separate investigation
- fasterq-dump sralite quality → separate investigation
