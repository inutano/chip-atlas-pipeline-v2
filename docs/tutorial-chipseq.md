# ChIP-seq Pipeline v2: Step-by-Step Tutorial

This tutorial walks you through running the ChIP-Atlas v2 ChIP-seq pipeline from raw SRA data to final output files (BigWig coverage, narrowPeak files, BigBed tracks).

The pipeline runs entirely inside a single container — no local tool installation required beyond a container runtime.

**Example experiments used throughout this tutorial:**

| Accession | Layout | Organism | Description |
|-----------|--------|----------|-------------|
| SRX26106775 | Paired-end (PE) | hg38 | H3K4me3 ChIP-seq, human |
| DRX127555 | Single-end (SE) | hg38 | CTCF ChIP-seq, human |

---

## Prerequisites

### Container runtime

You need one of the following:

- **Apptainer** (recommended on NIG supercomputer)
  - NIG path: `/opt/pkg/apptainer/1.4.5/bin/apptainer`
  - Add to your PATH: `export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH`
- **Docker** (any machine where Docker is installed)

### Reference genome files

For hg38 you need:

| File | Size | Purpose |
|------|------|---------|
| `hg38.fa` | ~3.1 GB | Reference FASTA |
| `hg38.fa.fai` | ~19 KB | FASTA index (for samtools) |
| `hg38.fa.bwt.2bit.64` + 4 other index files | ~9.8 GB total | bwa-mem2 index |
| `chrom.sizes` | ~455 lines | Chromosome sizes (for BigWig/BigBed) |

On NIG, pre-built hg38 references are available at:

```
~/chip-atlas-v2/references/hg38/
```

### A list of SRA experiment accessions

Prepare a plain text file with one accession per line (SRX/DRX/ERX format):

```
SRX26106775
DRX127555
```

---

## Step 1: Pull the container

The pipeline container includes all tools (fastp, bwa-mem2, samtools, MACS3, bedtools, UCSC tools).

**On NIG (Apptainer):**

```bash
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

apptainer pull \
  docker://ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0
# Output: pipeline-v2_v1.0.0.sif (about 1.5 GB)
```

Move the SIF to a stable location (pre-built SIF already exists on NIG):

```bash
# On NIG, use the existing SIF:
SIF=~/chip-atlas-v2/containers/pipeline-v2.sif
```

**On Docker:**

```bash
docker pull ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0
```

Verify the tools are available:

```bash
# Apptainer
apptainer exec pipeline-v2.sif bash /opt/conda/bin/versions.sh

# Docker
docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 versions.sh
```

---

## Step 2: Prepare the reference genome

Skip this step if you are on NIG and using the pre-built references at `~/chip-atlas-v2/references/hg38/`.

### Option A: Use the automated script (recommended)

```bash
bash scripts/prepare-genomes.sh ~/chip-atlas-v2/references
```

This downloads hg38 from UCSC, builds the bwa-mem2 index, and creates `chrom.sizes`. It takes 30–60 minutes; bwa-mem2 indexing requires ~60 GB RAM.

### Option B: Manual steps

```bash
REF_DIR=~/chip-atlas-v2/references/hg38
mkdir -p $REF_DIR
cd $REF_DIR

# 1. Download hg38 FASTA from UCSC
curl -L -o hg38.fa.gz \
  https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz
gunzip hg38.fa.gz
# hg38.fa is ~3.1 GB

# 2. Create FASTA index + chrom.sizes using the container
apptainer exec pipeline-v2.sif samtools faidx hg38.fa
cut -f1,2 hg38.fa.fai > chrom.sizes
# chrom.sizes has 455 lines (chromosomes + unplaced contigs)

# 3. Build bwa-mem2 index (requires ~60 GB RAM, takes ~20 min)
apptainer exec pipeline-v2.sif bwa-mem2 index hg38.fa
# Produces: hg38.fa.0123, hg38.fa.amb, hg38.fa.ann,
#           hg38.fa.bwt.2bit.64, hg38.fa.pac
```

### MACS3 genome size values

| Genome | `--genome-size` value |
|--------|----------------------|
| hg38 | `hs` |
| mm10 | `mm` |
| rn6 | `2.87e9` |
| dm6 | `dm` |
| ce11 | `ce` |
| sacCer3 | `1.2e7` |

---

## Step 3: Download FASTQ files

Use `scripts/fast-download.sh` to fetch reads for an experiment accession. The script queries the ENA API to resolve the accession to run IDs, downloads FASTQs via aria2c, and concatenates multiple runs into a single FASTQ pair per experiment.

```bash
bash scripts/fast-download.sh SRX26106775 ./fastq/
bash scripts/fast-download.sh DRX127555   ./fastq/
```

Expected output:

```
[ENA] Resolving runs for SRX26106775...
[ENA] SRX26106775: 1 run(s), layout=PAIRED
[RUN] SRR30689084 (PAIRED)
  Downloading: SRR30689084_1.fastq.gz
  Downloading: SRR30689084_2.fastq.gz
[CONCAT] Merging 1 run(s) → SRX26106775
  → SRX26106775_1.fastq.gz (358M)
  → SRX26106775_2.fastq.gz (355M)
[DONE] SRX26106775: 1 run(s) downloaded and merged
```

```
[ENA] Resolving runs for DRX127555...
[ENA] DRX127555: 1 run(s), layout=SINGLE
[RUN] DRR127555 (SINGLE)
  [DDBJ-LOCAL] Copying + decompressing bz2 from Lustre  ← NIG only
  → DRX127555.fastq.gz (174M)
[DONE] DRX127555: 1 run(s) downloaded and merged
```

**Notes:**

- PE output: `{accession}_1.fastq.gz` and `{accession}_2.fastq.gz`
- SE output: `{accession}.fastq.gz`
- DRR accessions (Japanese DRA) use the local DDBJ Lustre mirror on NIG — much faster than downloading from the internet
- The script caches downloads: re-running it for an accession that already has output files does nothing

---

## Step 4: Run the pipeline

### Paired-end example (SRX26106775)

**NIG (Apptainer):**

```bash
SIF=~/chip-atlas-v2/containers/pipeline-v2.sif
REF=~/chip-atlas-v2/references/hg38

apptainer exec --bind /data1/tmp:/tmp $SIF \
  bash scripts/pipeline-v2.sh \
    --sample-id   SRX26106775 \
    --fastq-fwd   fastq/SRX26106775_1.fastq.gz \
    --fastq-rev   fastq/SRX26106775_2.fastq.gz \
    --genome-fasta $REF/hg38.fa \
    --chrom-sizes  $REF/chrom.sizes \
    --genome-size  hs \
    --outdir       output/SRX26106775 \
    --threads      8
```

**Docker:**

```bash
docker run --rm \
  -v $(pwd):/work \
  -v ~/chip-atlas-v2/references:/ref \
  -w /work \
  ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 \
  bash scripts/pipeline-v2.sh \
    --sample-id   SRX26106775 \
    --fastq-fwd   fastq/SRX26106775_1.fastq.gz \
    --fastq-rev   fastq/SRX26106775_2.fastq.gz \
    --genome-fasta /ref/hg38/hg38.fa \
    --chrom-sizes  /ref/hg38/chrom.sizes \
    --genome-size  hs \
    --outdir       output/SRX26106775 \
    --threads      8
```

### Single-end example (DRX127555)

Omit `--fastq-rev`. Everything else is the same:

```bash
apptainer exec --bind /data1/tmp:/tmp $SIF \
  bash scripts/pipeline-v2.sh \
    --sample-id   DRX127555 \
    --fastq-fwd   fastq/DRX127555.fastq.gz \
    --genome-fasta $REF/hg38.fa \
    --chrom-sizes  $REF/chrom.sizes \
    --genome-size  hs \
    --outdir       output/DRX127555 \
    --threads      8
```

### What happens inside the pipeline

The pipeline runs four steps:

```
Step 1 (piped, PE):
  fastp → bwa-mem2 -p → samtools collate → fixmate → sort → markdup
                                                             ↓
                                                         dedup.bam (on NVMe)

Step 2 (parallel from dedup.bam):
  ├── bedtools genomecov → RPM normalize → bedGraphToBigWig → {id}.bw
  └── MACS3 callpeak -f BAMPE -q 1e-5 → {id}_peaks.narrowPeak

Step 3: filter narrowPeak by -log10(q) ≥ 10 and ≥ 20 → 3 threshold files
        bedToBigBed → {id}.05.bb / .10.bb / .20.bb

Step 4: write {id}.stats.tsv
```

For SE: collate and fixmate are skipped; MACS3 uses `-f BAM` instead of `-f BAMPE`.

All intermediate files (dedup BAM, BedGraph, temporary sort files) are written to `/tmp` (NVMe on NIG) and deleted at the end. Only final outputs are written to `--outdir`.

### Expected runtime

| Read count | Approximate time (8 threads) |
|------------|------------------------------|
| < 1M | ~1 min |
| 1–10M | ~2–3 min |
| 10–50M | ~8–15 min |
| 50M+ | ~25–40 min |

SRX26106775 (16.6M reads, PE): ~6.4 min
DRX127555 (4.1M reads, SE): ~2.2 min

---

## Step 5: Check the outputs

After a successful run you should see these files in `--outdir`:

```
output/SRX26106775/
  SRX26106775.bw                     # Coverage BigWig, RPM-normalized (~42 MB)
  SRX26106775.05_peaks.narrowPeak    # Peaks at q-value 1e-5   (10,592 peaks)
  SRX26106775.10_peaks.narrowPeak    # Peaks at q-value 1e-10  ( 7,476 peaks)
  SRX26106775.20_peaks.narrowPeak    # Peaks at q-value 1e-20  ( 1,926 peaks)
  SRX26106775.05.bb                  # BigBed for q05 peaks (~190 KB)
  SRX26106775.10.bb                  # BigBed for q10 peaks (~153 KB)
  SRX26106775.20.bb                  # BigBed for q20 peaks (~80 KB)
  SRX26106775.05_peaks.xls           # MACS3 peak statistics table
  SRX26106775_fastp.json             # fastp QC report (~117 KB)
  SRX26106775.stats.tsv              # 15-column summary statistics

output/DRX127555/
  DRX127555.bw                       # Coverage BigWig (~23 MB)
  DRX127555.05_peaks.narrowPeak      # Peaks at q05   (1,107 peaks)
  DRX127555.10_peaks.narrowPeak      # Peaks at q10   (  741 peaks)
  DRX127555.20_peaks.narrowPeak      # Peaks at q20   (   92 peaks)
  DRX127555.05.bb / .10.bb / .20.bb
  DRX127555_fastp.json
  DRX127555.stats.tsv
```

### Reading the stats.tsv

The 15-column TSV has no header. Column meanings:

| Col | Name | SRX26106775 | DRX127555 |
|-----|------|-------------|-----------|
| 1 | sample_id | SRX26106775 | DRX127555 |
| 2 | is_paired | 1 (PE) | 0 (SE) |
| 3 | fastq_bytes | 746241027 | 181511959 |
| 4 | reserved | 0 | 0 |
| 5 | reads_before_filter | 16638376 | 4122448 |
| 6 | reads_after_filter | 16447662 | 3953676 |
| 7 | mapping_rate_pct | 53.0 | 67.3 |
| 8 | dup_removed_pct | 47.0 | 32.7 |
| 9 | dedup_bam_bytes | 508044504 | 143526672 |
| 10 | bedgraph_bytes | 169530220 | 97510991 |
| 11 | bigwig_bytes | 43671658 | 23320239 |
| 12 | peaks_q05 | 10592 | 1107 |
| 13 | peaks_q10 | 7476 | 741 |
| 14 | peaks_q20 | 1926 | 92 |
| 15 | elapsed_minutes | 6.42 | 2.23 |

### Quick sanity checks

**Mapping rate:** Column 7 should typically be 40–95%. A rate below 20% suggests a reference genome mismatch or severe library quality issues. The SRX26106775 rate of 53% is typical for H3K4me3 with some PCR duplicates (column 8 = 47% removed).

**Peak count:** Column 12 (q05) should be non-zero for a successful ChIP experiment. Zero peaks means either the ChIP failed (low enrichment) or MACS3 could not build a shift model (check `macs3.stderr` in `/tmp` if you captured it). The 3 q-value thresholds let you apply different stringency:
- q05 (1e-5): most permissive, use for exploratory analysis
- q10 (1e-10): standard for publication
- q20 (1e-20): high-confidence peaks only

**BigWig:** Load `{id}.bw` in IGV or UCSC Genome Browser. You should see enrichment at expected loci (e.g., for H3K4me3: active gene promoters; for CTCF: CTCF binding sites).

---

## Step 6: Processing multiple samples

### Simple loop

```bash
SIF=~/chip-atlas-v2/containers/pipeline-v2.sif
REF=~/chip-atlas-v2/references/hg38

while read acc; do
  echo "=== $acc ==="

  # Download
  bash scripts/fast-download.sh "$acc" ./fastq/

  # Detect PE vs SE from output
  if [ -f "fastq/${acc}_1.fastq.gz" ]; then
    REV_ARG="--fastq-rev fastq/${acc}_2.fastq.gz"
    FWD="fastq/${acc}_1.fastq.gz"
  else
    REV_ARG=""
    FWD="fastq/${acc}.fastq.gz"
  fi

  # Run pipeline
  apptainer exec --bind /data1/tmp:/tmp $SIF \
    bash scripts/pipeline-v2.sh \
      --sample-id   "$acc" \
      --fastq-fwd   "$FWD" \
      $REV_ARG \
      --genome-fasta $REF/hg38.fa \
      --chrom-sizes  $REF/chrom.sizes \
      --genome-size  hs \
      --outdir       output/"$acc" \
      --threads      8

done < samples.txt
```

### SLURM batch processing on NIG

For large batches, use `scripts/production-run.sh`, which handles SLURM submission, disk quota monitoring, and automatic retry:

```bash
# Prepare sample list (TSV with header: accession, genome, experiment_type, num_reads)
cat > samples.tsv <<'EOF'
accession	genome	experiment_type	num_reads
SRX26106775	hg38	TFs and others	16638376
DRX127555	hg38	TFs and others	4122448
EOF

# Submit to SLURM
bash scripts/production-run.sh submit hg38 samples.tsv \
  --threads 8 \
  --batch-size 90 \
  --output-base /path/to/results

# Monitor progress
bash scripts/production-run.sh status hg38

# Retry failed jobs
bash scripts/production-run.sh retry hg38
```

SLURM defaults (can be overridden with environment variables):

```bash
export SLURM_PARTITION=kumamoto-c768
export SLURM_ACCOUNT=kumamoto-group
```

---

## NIG supercomputer notes

### Paths

| Item | Path |
|------|------|
| Apptainer binary | `/opt/pkg/apptainer/1.4.5/bin/apptainer` |
| Pipeline SIF | `~/chip-atlas-v2/containers/pipeline-v2.sif` |
| hg38 reference | `~/chip-atlas-v2/references/hg38/` |
| NVMe scratch | `/data1/tmp` (bind as `/tmp` for intermediates) |
| SLURM partition | `kumamoto-c768` |
| SLURM account | `kumamoto-group` |

### Environment setup

Add to your `~/.bashrc` on NIG:

```bash
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
export CHIP_ATLAS_BASE=~/chip-atlas-v2
export SLURM_PARTITION=kumamoto-c768
export SLURM_ACCOUNT=kumamoto-group
```

### Why bind `/data1/tmp`

The pipeline writes all intermediates (dedup BAM up to ~500 MB for large samples, sort temp files, BedGraph) to `$TMPDIR`. On NIG, `/data1/tmp` is fast NVMe local to each compute node. Binding it as `/tmp` keeps all temporary I/O off the shared Lustre filesystem, which both speeds up the pipeline and reduces Lustre load.

The `--bind /data1/tmp:/tmp` flag is only needed on NIG. On a workstation or with Docker it can be omitted (the system `/tmp` will be used).

### DRX/DRR accessions

For DRA (Japanese DRA) experiments with DRX/DRR accessions, `fast-download.sh` automatically checks the local DDBJ Lustre mirror at:

```
/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/
```

This avoids downloading from the internet and is typically 5–10x faster.

---

## SE vs PE: key differences

| Aspect | Single-end (SE) | Paired-end (PE) |
|--------|----------------|-----------------|
| `--fastq-rev` | Omit | Required |
| `fast-download.sh` output | `{acc}.fastq.gz` | `{acc}_1.fastq.gz`, `{acc}_2.fastq.gz` |
| bwa-mem2 flag | no `-p` | `-p` (interleaved stdin) |
| samtools chain | sort → markdup | collate → fixmate → sort → markdup |
| MACS3 format | `-f BAM` | `-f BAMPE` |
| Peak accuracy | Fragment size estimated by shift model | Actual fragment sizes from read pairs |

The pipeline auto-detects SE vs PE based on whether `--fastq-rev` is provided and the file exists.

---

## Troubleshooting

**No peaks produced:**
MACS3 prints "not enough paired peaks at different fold-enrichment levels" when signal is too low to build a shift model. This is expected for some low-signal samples. Check `$TMPDIR/{sample}_$$/macs3.stderr` (or redirect stderr when running) to confirm. The stats.tsv will show `0` in columns 12–14.

**Low mapping rate (< 30%):**
- Confirm `--genome-size` matches the species of the experiment
- Check `bwamem2.stderr` in TMPDIR for alignment details
- Verify the FASTQ is not corrupted: `zcat fastq/{acc}.fastq.gz | head -8`

**`bwa-mem2: error while loading shared libraries`:**
This means bwa-mem2 is being run outside the container. Make sure you use `apptainer exec ... bash scripts/pipeline-v2.sh` and not `bash scripts/pipeline-v2.sh` directly.

**Out-of-space error:**
The dedup BAM for a 50M-read human sample is ~500 MB. Check that `$TMPDIR` (typically `/data1/tmp` on NIG) has at least 2 GB free per concurrent job.

---

*Container: `ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0` — fastp 1.3.1, bwa-mem2 2.3, samtools 1.23.1, MACS3 3.0.4, bedtools 2.31.1, UCSC tools 482*

---

# ChIP-seqパイプライン v2: ステップバイステップチュートリアル

このチュートリアルでは、ChIP-Atlas v2 ChIP-seqパイプラインをSRAの生データから最終的な出力ファイル（BigWigカバレッジ、narrowPeakファイル、BigBedトラック）まで実行する手順を説明します。

パイプラインはすべてコンテナ内で実行されるため、コンテナランタイム以外のローカルへのツールインストールは不要です。

**このチュートリアルで使用するサンプル:**

| アクセッション | レイアウト | 生物種 | 説明 |
|--------------|-----------|--------|------|
| SRX26106775 | ペアエンド (PE) | hg38 | H3K4me3 ChIP-seq、ヒト |
| DRX127555 | シングルエンド (SE) | hg38 | CTCF ChIP-seq、ヒト |

---

## 前提条件

### コンテナランタイム

以下のいずれかが必要です:

- **Apptainer**（NISスーパーコンピュータでの推奨）
  - NIGのパス: `/opt/pkg/apptainer/1.4.5/bin/apptainer`
  - PATHへの追加: `export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH`
- **Docker**（Dockerがインストールされた任意のマシン）

### リファレンスゲノムファイル

hg38に必要なファイル:

| ファイル | サイズ | 用途 |
|---------|-------|------|
| `hg38.fa` | 約3.1 GB | リファレンスFASTA |
| `hg38.fa.fai` | 約19 KB | FASTAインデックス（samtools用） |
| `hg38.fa.bwt.2bit.64` + 4ファイル | 合計約9.8 GB | bwa-mem2インデックス |
| `chrom.sizes` | 455行 | 染色体サイズ（BigWig/BigBed用） |

NIGでは、事前構築済みhg38リファレンスが以下のパスで利用可能です:

```
~/chip-atlas-v2/references/hg38/
```

### SRA実験アクセッションのリスト

1行に1アクセッション（SRX/DRX/ERX形式）のテキストファイルを準備してください:

```
SRX26106775
DRX127555
```

---

## ステップ1: コンテナの取得

パイプラインコンテナにはすべてのツール（fastp、bwa-mem2、samtools、MACS3、bedtools、UCSCツール）が含まれています。

**NIGの場合（Apptainer）:**

```bash
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH

apptainer pull \
  docker://ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0
# 出力: pipeline-v2_v1.0.0.sif（約1.5 GB）
```

SIFを安定した場所に移動します（NIGでは事前構築済みSIFが利用可能）:

```bash
# NIGでは既存のSIFを使用:
SIF=~/chip-atlas-v2/containers/pipeline-v2.sif
```

**Dockerの場合:**

```bash
docker pull ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0
```

ツールの確認:

```bash
# Apptainer
apptainer exec pipeline-v2.sif bash /opt/conda/bin/versions.sh

# Docker
docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 versions.sh
```

---

## ステップ2: リファレンスゲノムの準備

NIGを使用しており、`~/chip-atlas-v2/references/hg38/`の事前構築済みリファレンスを使用する場合、このステップはスキップできます。

### オプションA: 自動化スクリプトの使用（推奨）

```bash
bash scripts/prepare-genomes.sh ~/chip-atlas-v2/references
```

このスクリプトはUCSCからhg38をダウンロードし、bwa-mem2インデックスを構築し、`chrom.sizes`を作成します。30〜60分かかります。bwa-mem2インデックスの構築には約60 GBのRAMが必要です。

### オプションB: 手動手順

```bash
REF_DIR=~/chip-atlas-v2/references/hg38
mkdir -p $REF_DIR
cd $REF_DIR

# 1. UCSCからhg38 FASTAをダウンロード
curl -L -o hg38.fa.gz \
  https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz
gunzip hg38.fa.gz
# hg38.fa は約3.1 GB

# 2. コンテナを使ってFASTAインデックス + chrom.sizesを作成
apptainer exec pipeline-v2.sif samtools faidx hg38.fa
cut -f1,2 hg38.fa.fai > chrom.sizes
# chrom.sizesは455行（染色体 + 未配置コンティグ）

# 3. bwa-mem2インデックスを構築（約60 GB RAM、約20分かかる）
apptainer exec pipeline-v2.sif bwa-mem2 index hg38.fa
# 生成ファイル: hg38.fa.0123, hg38.fa.amb, hg38.fa.ann,
#               hg38.fa.bwt.2bit.64, hg38.fa.pac
```

### MACS3ゲノムサイズ値

| ゲノム | `--genome-size` の値 |
|-------|---------------------|
| hg38 | `hs` |
| mm10 | `mm` |
| rn6 | `2.87e9` |
| dm6 | `dm` |
| ce11 | `ce` |
| sacCer3 | `1.2e7` |

---

## ステップ3: FASTQファイルのダウンロード

`scripts/fast-download.sh`を使用して実験アクセッションのリードを取得します。このスクリプトはENA APIを照会してアクセッションをランIDに解決し、aria2cでFASTQをダウンロードし、複数のランを実験ごとに1つのFASTQペアに結合します。

```bash
bash scripts/fast-download.sh SRX26106775 ./fastq/
bash scripts/fast-download.sh DRX127555   ./fastq/
```

期待される出力:

```
[ENA] Resolving runs for SRX26106775...
[ENA] SRX26106775: 1 run(s), layout=PAIRED
[RUN] SRR30689084 (PAIRED)
  Downloading: SRR30689084_1.fastq.gz
  Downloading: SRR30689084_2.fastq.gz
[CONCAT] Merging 1 run(s) → SRX26106775
  → SRX26106775_1.fastq.gz (358M)
  → SRX26106775_2.fastq.gz (355M)
[DONE] SRX26106775: 1 run(s) downloaded and merged
```

```
[ENA] Resolving runs for DRX127555...
[ENA] DRX127555: 1 run(s), layout=SINGLE
[RUN] DRR127555 (SINGLE)
  [DDBJ-LOCAL] Copying + decompressing bz2 from Lustre  ← NIGのみ
  → DRX127555.fastq.gz (174M)
[DONE] DRX127555: 1 run(s) downloaded and merged
```

**注意事項:**

- PEの出力: `{アクセッション}_1.fastq.gz` と `{アクセッション}_2.fastq.gz`
- SEの出力: `{アクセッション}.fastq.gz`
- DRR アクセッション（日本のDRA）は、NIGではDDBJ LustreのローカルミラーからDRX/DRRの取得が可能。インターネットからのダウンロードより大幅に高速
- スクリプトはダウンロードをキャッシュします。既に出力ファイルが存在するアクセッションに対して再実行しても何も行いません

---

## ステップ4: パイプラインの実行

### ペアエンドの例（SRX26106775）

**NIGの場合（Apptainer）:**

```bash
SIF=~/chip-atlas-v2/containers/pipeline-v2.sif
REF=~/chip-atlas-v2/references/hg38

apptainer exec --bind /data1/tmp:/tmp $SIF \
  bash scripts/pipeline-v2.sh \
    --sample-id   SRX26106775 \
    --fastq-fwd   fastq/SRX26106775_1.fastq.gz \
    --fastq-rev   fastq/SRX26106775_2.fastq.gz \
    --genome-fasta $REF/hg38.fa \
    --chrom-sizes  $REF/chrom.sizes \
    --genome-size  hs \
    --outdir       output/SRX26106775 \
    --threads      8
```

**Dockerの場合:**

```bash
docker run --rm \
  -v $(pwd):/work \
  -v ~/chip-atlas-v2/references:/ref \
  -w /work \
  ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 \
  bash scripts/pipeline-v2.sh \
    --sample-id   SRX26106775 \
    --fastq-fwd   fastq/SRX26106775_1.fastq.gz \
    --fastq-rev   fastq/SRX26106775_2.fastq.gz \
    --genome-fasta /ref/hg38/hg38.fa \
    --chrom-sizes  /ref/hg38/chrom.sizes \
    --genome-size  hs \
    --outdir       output/SRX26106775 \
    --threads      8
```

### シングルエンドの例（DRX127555）

`--fastq-rev`を省略します。それ以外は同じです:

```bash
apptainer exec --bind /data1/tmp:/tmp $SIF \
  bash scripts/pipeline-v2.sh \
    --sample-id   DRX127555 \
    --fastq-fwd   fastq/DRX127555.fastq.gz \
    --genome-fasta $REF/hg38.fa \
    --chrom-sizes  $REF/chrom.sizes \
    --genome-size  hs \
    --outdir       output/DRX127555 \
    --threads      8
```

### パイプライン内部の処理

パイプラインは4つのステップで実行されます:

```
ステップ1（パイプライン処理、PE）:
  fastp → bwa-mem2 -p → samtools collate → fixmate → sort → markdup
                                                             ↓
                                                     dedup.bam（NVMe上）

ステップ2（dedup.bamから並列処理）:
  ├── bedtools genomecov → RPM正規化 → bedGraphToBigWig → {id}.bw
  └── MACS3 callpeak -f BAMPE -q 1e-5 → {id}_peaks.narrowPeak

ステップ3: -log10(q) ≥ 10 と ≥ 20 でnarrowPeakをフィルタリング → 3閾値ファイル
           bedToBigBed → {id}.05.bb / .10.bb / .20.bb

ステップ4: {id}.stats.tsv の書き込み
```

SEの場合: collateとfixmateはスキップされ、MACS3は`-f BAMPE`の代わりに`-f BAM`を使用します。

すべての中間ファイル（dedup BAM、BedGraph、一時ソートファイル）は`/tmp`（NIGではNVMe）に書き込まれ、終了時に削除されます。最終的な出力のみ`--outdir`に書き込まれます。

### 予想される実行時間

| リード数 | 目安の時間（8スレッド） |
|---------|----------------------|
| 100万未満 | 約1分 |
| 100万〜1000万 | 約2〜3分 |
| 1000万〜5000万 | 約8〜15分 |
| 5000万以上 | 約25〜40分 |

SRX26106775（1660万リード、PE）: 約6.4分
DRX127555（410万リード、SE）: 約2.2分

---

## ステップ5: 出力の確認

実行が成功すると、`--outdir`に以下のファイルが生成されます:

```
output/SRX26106775/
  SRX26106775.bw                     # カバレッジBigWig、RPM正規化済み（約42 MB）
  SRX26106775.05_peaks.narrowPeak    # q値1e-5のピーク   （10,592ピーク）
  SRX26106775.10_peaks.narrowPeak    # q値1e-10のピーク  （ 7,476ピーク）
  SRX26106775.20_peaks.narrowPeak    # q値1e-20のピーク  （ 1,926ピーク）
  SRX26106775.05.bb                  # q05ピークのBigBed（約190 KB）
  SRX26106775.10.bb                  # q10ピークのBigBed（約153 KB）
  SRX26106775.20.bb                  # q20ピークのBigBed（約80 KB）
  SRX26106775.05_peaks.xls           # MACS3ピーク統計テーブル
  SRX26106775_fastp.json             # fastp QCレポート（約117 KB）
  SRX26106775.stats.tsv              # 15列のサマリー統計

output/DRX127555/
  DRX127555.bw                       # カバレッジBigWig（約23 MB）
  DRX127555.05_peaks.narrowPeak      # q05ピーク（1,107ピーク）
  DRX127555.10_peaks.narrowPeak      # q10ピーク（  741ピーク）
  DRX127555.20_peaks.narrowPeak      # q20ピーク（   92ピーク）
  DRX127555.05.bb / .10.bb / .20.bb
  DRX127555_fastp.json
  DRX127555.stats.tsv
```

### stats.tsvの読み方

15列のTSVにはヘッダー行がありません。各列の意味:

| 列 | 名前 | SRX26106775 | DRX127555 |
|----|------|-------------|-----------|
| 1 | sample_id | SRX26106775 | DRX127555 |
| 2 | is_paired | 1（PE） | 0（SE） |
| 3 | fastq_bytes | 746241027 | 181511959 |
| 4 | 予約済み | 0 | 0 |
| 5 | reads_before_filter | 16638376 | 4122448 |
| 6 | reads_after_filter | 16447662 | 3953676 |
| 7 | mapping_rate_pct | 53.0 | 67.3 |
| 8 | dup_removed_pct | 47.0 | 32.7 |
| 9 | dedup_bam_bytes | 508044504 | 143526672 |
| 10 | bedgraph_bytes | 169530220 | 97510991 |
| 11 | bigwig_bytes | 43671658 | 23320239 |
| 12 | peaks_q05 | 10592 | 1107 |
| 13 | peaks_q10 | 7476 | 741 |
| 14 | peaks_q20 | 1926 | 92 |
| 15 | elapsed_minutes | 6.42 | 2.23 |

### 簡易サニティチェック

**マッピング率（7列目）:** 通常40〜95%であることが期待されます。20%未満の場合、リファレンスゲノムの不一致または重大なライブラリ品質の問題が考えられます。SRX26106775の53%はH3K4me3として典型的な値です（PCR重複が47%除去されています）。

**ピーク数（12列目）:** ChIPが成功している場合、q05は0より大きいはずです。ピークが0の場合、ChIPが失敗している（低エンリッチメント）か、MACS3がシフトモデルを構築できなかった可能性があります。3つのq値閾値により異なるストリンジェンシーを適用できます:
- q05 (1e-5): 最も許容度が高い、探索的解析に使用
- q10 (1e-10): 論文発表の標準
- q20 (1e-20): 高信頼性ピークのみ

**BigWig:** IGVまたはUCSCゲノムブラウザで`{id}.bw`を読み込みます。期待されるゲノム座標にエンリッチメントが見られるはずです（例: H3K4me3では活性遺伝子のプロモーター付近、CTCFではCTCF結合部位）。

---

## ステップ6: 複数サンプルの処理

### シンプルなループ

```bash
SIF=~/chip-atlas-v2/containers/pipeline-v2.sif
REF=~/chip-atlas-v2/references/hg38

while read acc; do
  echo "=== $acc ==="

  # ダウンロード
  bash scripts/fast-download.sh "$acc" ./fastq/

  # PE vs SEを出力ファイルから判定
  if [ -f "fastq/${acc}_1.fastq.gz" ]; then
    REV_ARG="--fastq-rev fastq/${acc}_2.fastq.gz"
    FWD="fastq/${acc}_1.fastq.gz"
  else
    REV_ARG=""
    FWD="fastq/${acc}.fastq.gz"
  fi

  # パイプラインの実行
  apptainer exec --bind /data1/tmp:/tmp $SIF \
    bash scripts/pipeline-v2.sh \
      --sample-id   "$acc" \
      --fastq-fwd   "$FWD" \
      $REV_ARG \
      --genome-fasta $REF/hg38.fa \
      --chrom-sizes  $REF/chrom.sizes \
      --genome-size  hs \
      --outdir       output/"$acc" \
      --threads      8

done < samples.txt
```

### NIGでのSLURMバッチ処理

大規模なバッチには、SLURMジョブ投入・ディスク使用量監視・自動リトライを管理する`scripts/production-run.sh`を使用します:

```bash
# サンプルリストを準備（ヘッダー付きTSV: accession, genome, experiment_type, num_reads）
cat > samples.tsv <<'EOF'
accession	genome	experiment_type	num_reads
SRX26106775	hg38	TFs and others	16638376
DRX127555	hg38	TFs and others	4122448
EOF

# SLURMに投入
bash scripts/production-run.sh submit hg38 samples.tsv \
  --threads 8 \
  --batch-size 90 \
  --output-base /path/to/results

# 進捗の確認
bash scripts/production-run.sh status hg38

# 失敗したジョブのリトライ
bash scripts/production-run.sh retry hg38
```

SLURMのデフォルト設定（環境変数で上書き可能）:

```bash
export SLURM_PARTITION=kumamoto-c768
export SLURM_ACCOUNT=kumamoto-group
```

---

## NIGスーパーコンピュータ固有の注意事項

### パス

| 項目 | パス |
|------|------|
| Apptainerバイナリ | `/opt/pkg/apptainer/1.4.5/bin/apptainer` |
| パイプラインSIF | `~/chip-atlas-v2/containers/pipeline-v2.sif` |
| hg38リファレンス | `~/chip-atlas-v2/references/hg38/` |
| NVMeスクラッチ | `/data1/tmp`（中間ファイル用に`/tmp`としてバインド） |
| SLURMパーティション | `kumamoto-c768` |
| SLURMアカウント | `kumamoto-group` |

### 環境設定

NIGの`~/.bashrc`に以下を追加します:

```bash
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
export CHIP_ATLAS_BASE=~/chip-atlas-v2
export SLURM_PARTITION=kumamoto-c768
export SLURM_ACCOUNT=kumamoto-group
```

### `/data1/tmp`をバインドする理由

パイプラインはすべての中間ファイル（大きなサンプルでは最大約500 MBのdedup BAM、ソート一時ファイル、BedGraph）を`$TMPDIR`に書き込みます。NIGでは、`/data1/tmp`は各コンピュートノードにローカルの高速NVMeです。これを`/tmp`としてバインドすることで、すべての一時I/Oを共有Lustreファイルシステムから切り離し、パイプラインの高速化とLustre負荷の低減を実現します。

`--bind /data1/tmp:/tmp`フラグはNIGでのみ必要です。ワークステーションやDockerではシステムの`/tmp`が使用されるため省略できます。

### DRX/DRRアクセッション

DRA（日本のDRA）実験のDRX/DRRアクセッションの場合、`fast-download.sh`は以下のローカルDDBJ Lustreミラーを自動的に確認します:

```
/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/
```

これによりインターネットからのダウンロードを回避でき、通常5〜10倍高速です。

---

## SEとPEの主な違い

| 項目 | シングルエンド（SE） | ペアエンド（PE） |
|------|-------------------|--------------| 
| `--fastq-rev` | 省略 | 必須 |
| `fast-download.sh`の出力 | `{acc}.fastq.gz` | `{acc}_1.fastq.gz`、`{acc}_2.fastq.gz` |
| bwa-mem2フラグ | `-p`なし | `-p`（インターリーブstdin） |
| samtoolsチェーン | sort → markdup | collate → fixmate → sort → markdup |
| MACS3フォーマット | `-f BAM` | `-f BAMPE` |
| ピーク精度 | シフトモデルでフラグメントサイズを推定 | リードペアから実際のフラグメントサイズを使用 |

パイプラインは`--fastq-rev`が指定されているかどうか（かつそのファイルが存在するか）に基づいてSEとPEを自動検出します。

---

## トラブルシューティング

**ピークが生成されない場合:**
MACS3は信号が低すぎてシフトモデルを構築できない場合に「異なるフォールドエンリッチメントレベルでのペアードピークが不十分」というメッセージを出力します。これは一部の低シグナルサンプルでは想定内の挙動です。`$TMPDIR/{sample}_$$/macs3.stderr`（または実行時にstderrをリダイレクトしている場合はそのファイル）を確認してください。stats.tsvの12〜14列目は`0`となります。

**マッピング率が低い（30%未満）場合:**
- `--genome-size`が実験の生物種と一致していることを確認
- TMP内の`bwamem2.stderr`でアライメントの詳細を確認
- FASTQが破損していないか確認: `zcat fastq/{acc}.fastq.gz | head -8`

**`bwa-mem2: error while loading shared libraries`:**
コンテナ外でbwa-mem2が実行されていることを意味します。`bash scripts/pipeline-v2.sh`を直接実行するのではなく、`apptainer exec ... bash scripts/pipeline-v2.sh`を使用していることを確認してください。

**ディスク容量不足エラー:**
50Mリードのヒトサンプルのdedup BAMは約500 MBです。`$TMPDIR`（NIGでは通常`/data1/tmp`）に同時実行ジョブ1件あたり少なくとも2 GBの空き容量があることを確認してください。

---

*コンテナ: `ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0` — fastp 1.3.1、bwa-mem2 2.3、samtools 1.23.1、MACS3 3.0.4、bedtools 2.31.1、UCSCツール 482*
