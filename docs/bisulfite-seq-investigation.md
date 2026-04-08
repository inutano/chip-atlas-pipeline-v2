# Bisulfite-seq Sub-pipeline Investigation

ChIP-Atlas v2 Bisulfite-seq (WGBS) processing requires a dedicated sub-pipeline
because the main v2 pipeline uses bwa-mem2 which is not bisulfite-aware. This
document captures the investigation and testing of a DNMTools-based replacement
for v1's `bmap`.

## Background

v1 pipeline used `bmap` — a closed-source tool developed by an ex-colleague,
no longer maintained. Known issues:
- Very slow (300M-read samples took 13-15 hours)
- Produces large intermediate files
- Not publicly available

Collaborator suggestion: use **DNMTools** (Andrew Smith's lab, USC), which
includes `abismal` aligner and a full downstream methylation analysis toolkit.

## Tools evaluated

### DNMTools 1.5.1

Installed via Bioconda (`quay.io/biocontainers/dnmtools:1.5.1--hb66fcc3_0`).
Includes all tools needed for the pipeline:

| Tool | Purpose |
|------|---------|
| `abismal` | Bisulfite-aware aligner (replaces bmap) |
| `abismalidx` | Build abismal index from FASTA |
| `format` | Convert aligned BAM to dnmtools-standard format |
| `uniq` | Remove PCR duplicates |
| `counts` | Compute per-CpG methylation levels |
| `sym` | Merge +/- strand CpGs into symmetric single CpG |
| `hmr` | Call hypomethylated regions (CpG islands, promoters) |
| `hypermr` | Call hypermethylated regions |
| `pmd` | Call partially methylated domains |

### v1 comparison

| Tool | v1 | v2 (proposed) |
|------|----|--------|
| Aligner | bmap (closed) | abismal (DNMTools) |
| Dedup | bmap | dnmtools uniq |
| Methylation calls | bmap | dnmtools counts |
| Region calls | HyperMR only | HMR + HyperMR + PMD |
| Output tracks | ? | methyl.bw + cover.bw (single-bp BedGraph → BigWig) |

## Pipeline structure

```
FASTQ → abismal (-B for BAM output)
      → format (-f abismal, with -single-end if SE)
      → samtools sort
      → dnmtools uniq (dedup)
      → dnmtools counts -cpg-only → counts.tsv
      → dnmtools sym → counts.sym.tsv (for HMR)
      → parallel:
          hmr → hmr.bed
          hypermr → hypermr.bed
          pmd → pmd.bed
          BedGraph (col 5: methyl fraction, col 6: coverage) → BigWig
```

## Test script evolution

### v1: bs_analysis_minimal.sh (initial)

Collaborator's first draft. Issues found during review:

1. **BigWig math bug** (lines 98-105):
   ```bash
   print $1, $2-1, $2, $5/$6  # WRONG: fraction / coverage = nonsense
   print $1, $2-1, $2, $5+$6  # WRONG: fraction + coverage
   ```
   DNMTools counts format is `chrom pos strand context meth_frac n_reads`.
   Column 5 is already a fraction (0-1), column 6 is the coverage.
   Should be `$5` and `$6` as-is.

2. **Convoluted filter** (`$5 + $6 > 0`): adds a fraction to a count.
   Should be `$6 > 0` (coverage check).

3. **abismal BAM output needs format step**: the abismal BAM output has
   a non-standard format that needs `dnmtools format` conversion before
   downstream tools work correctly.

### v2: bs_analysis_minimal_v2.sh (fixed)

Collaborator's revised script with all fixes:

```bash
# Correct BigWig generation
print $1, $2, $2+1, $5   # methylation fraction
print $1, $2, $2+1, $6   # coverage

# Correct filter
awk '$6 > 0'

# Added format step
dnmtools abismal → format → samtools sort → uniq → counts
```

Also clarified:
- `abismal -B` = BAM output format (not batch mode)
- `dnmtools sym` isn't a simple merge; it aggregates counts to CpG-level
- For BigWig at 1bp resolution, strand-unmerged counts.tsv is correct
- HMR requires sym input; hypermr/pmd accept both, results similar

## Test results

### Test 1: sacCer3 yeast (SRX3236108)

- **Sample**: Yeast expressing mammalian DNMT3, single-end, 5.5M reads
- **Genome**: sacCer3 (~12 MB)
- **Threads**: 8
- **Total runtime**: ~4 min

| Metric | Value |
|--------|-------|
| Mapping rate | 96.2% (86.2% unique) |
| CpGs with coverage | 673,912 |
| Sym CpGs | 338,709 |
| Non-zero meth CpGs | 45,963 (6.8%) |
| HMR regions | 0 |
| HyperMR regions | 0 |
| PMD regions | 2 |
| methyl.bw | 3.4 MB |
| cover.bw | 4.5 MB |

**Issues encountered:**

- `dnmtools format` on SE reads requires `-single-end` flag. Without it:
  ```
  [error: 0][ERRNO: 1][Operation not permitted]
  [failed to identify read name suffix length
  verify reads are not single-end
  specify read name suffix length directly]
  ```

**Interpretation**: Yeast naturally has minimal CpG methylation, so 0 HMR/HyperMR
is expected. The sample is a functional test, not a biological test.

### Test 2: hg38 human cfDNA (SRX22130352)

- **Sample**: Plasma cell-free DNA (human), paired-end, 1M reads
- **Genome**: hg38
- **Threads**: 16
- **Total runtime**: ~3.5 min

| Stage | Time |
|-------|------|
| abismal align | 1 min |
| format | 2.6s |
| sort | 1.3s |
| uniq | 1.2s |
| **counts** | **2 min** |
| sym | 1.9s |
| hmr | 3.2s |
| hypermr | 8.8s |
| pmd | 1.9s |
| BigWig | ~5s |

| Mapping | Value |
|---------|-------|
| Pair mapping rate | 98.8% (95.3% unique) |
| Mate1 singleton | 78.6% |
| Mate2 singleton | 79.6% |

| Output | Value |
|--------|-------|
| CpGs with coverage | 987,360 |
| Sym CpGs | 976,749 |
| **HMR regions** | **2,985** |
| **HyperMR regions** | **36,765** |
| **PMD regions** | **3** |
| methyl.bw | 8.0 MB |
| cover.bw | 6.2 MB |
| hmr.bed | 109 KB |
| hypermr.bed | 1.3 MB |
| pmd.bed | 165 B |

**Methylation distribution** (confirming proper mammalian bimodal pattern):

| Range | Count | % |
|-------|------:|----:|
| 0% | 205,556 | 20.8% |
| 1-20% | 4,708 | 0.5% |
| 20-50% | 1,643 | 0.2% |
| 50-80% | 5,937 | 0.6% |
| **80-100%** | **769,516** | **77.9%** |

The bimodal distribution (77.9% highly methylated, 20.8% unmethylated) is the
classic signature of mammalian genomes — most CpGs are either fully methylated
or fully unmethylated (typically CpG islands, promoters).

## Performance characteristics

### Runtime scaling

| Sample | Genome | Reads | Layout | Time | Time/M reads |
|--------|--------|------:|--------|-----:|-------------:|
| SRX3236108 | sacCer3 (12MB) | 5.5M | SE | 4.0 min | 0.7 |
| SRX22130352 | hg38 (3GB) | 1M | PE | 3.5 min | 3.5 |

**Main bottleneck**: `dnmtools counts` (per-CpG methylation calculation).
For the human sample, counts took 2 of 3.5 minutes.

### Projection for production

For a typical 50M-read PE hg38 sample (comparable to ChIP-Atlas avg):
- Align: ~15 min (proportional to reads)
- Counts: ~20 min (proportional to reads × genome)
- Other steps: ~2 min
- **Estimated total**: ~35-40 min per sample (vs v1's 13-15h for 300M samples)

### Storage

- abismal index: 2.7 GB (hg38)
- Per-sample outputs: ~15 MB for 1M reads → ~700 MB for 50M reads expected
- Intermediate counts.tsv can be large (~300 MB for hg38 with high coverage)

## Tools needed for the container

New tools to add to the v2 container for Bisulfite-seq support:

- `dnmtools` (abismal + downstream tools)
- samtools (already present)
- bedGraphToBigWig (already present)

## Open questions (to discuss with collaborators)

1. **HyperMR count (36,765)** — seems high for a 1M-read sample.
   Is this expected, or should we tune `hypermr` parameters?

2. **Sample size tiering** — how small is too small for reliable methylation calls?
   cfDNA sample here has only 1M reads, got 2985 HMRs. With more coverage we'd
   get more HMRs. What's the minimum read count we should process?

3. **Output format compatibility** — current ChIP-Atlas v1 provides:
   - methyl.bw and cover.bw BigWigs ✓ (direct equivalent)
   - HyperMR BED ✓ (v1 only calls HyperMR, v2 also has HMR + PMD — keep all?)

4. **SE vs PE handling** — the script needs to detect layout and pass
   `-single-end` to `format` appropriately. This needs to be handled by the
   wrapper that calls the pipeline.

5. **Container**: should DNMTools be in a separate container or merged into
   the main v2 container? Separate is cleaner (only used for BS-seq) but
   adds complexity to the production-run.sh dispatch logic.

## Next steps

1. **Meeting discussion** — review test results, agree on parameters
2. **Add `-single-end` detection** to the pipeline script (like pipeline-v2.sh)
3. **Build abismal index on NIG** for all 6 genomes + TAIR10
4. **Create `pipeline-v2-bs.sh`** — production script analogous to pipeline-v2.sh
5. **Update `production-run.sh`** to dispatch Bisulfite-Seq samples to the BS pipeline
6. **Test on larger mammalian sample** (50M reads) to validate runtime projection
7. **Build BS-seq container** with dnmtools + samtools + bedGraphToBigWig

## References

- DNMTools: https://github.com/smithlabcode/dnmtools
- DNMTools docs: https://dnmtools.readthedocs.io/
- abismal paper: Andrade et al., *Bioinformatics* 2021
- Collaborator scripts: `~/bs_analysis_minimal.sh`, `~/bs_analysis_minimal_v2.sh`
- Test runs: `~/work/bs-test/`, `~/work/bs-test-human/`
