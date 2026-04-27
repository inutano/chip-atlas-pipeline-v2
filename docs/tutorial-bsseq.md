# ChIP-Atlas Pipeline v2: Bisulfite-seq (WGBS) Tutorial

This tutorial walks through running the ChIP-Atlas v2 Bisulfite-seq pipeline
end-to-end, from pulling the container to interpreting outputs. The pipeline
uses [DNMTools](https://github.com/smithlabcode/dnmtools) (abismal aligner +
downstream methylation tools) and is packaged in a single container that runs
on Apptainer (NIG supercomputer) or Docker (any machine).

> **NIG users:** Pre-built references (including abismal index), container images, and output data are available in the shared directory at `/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/`. This directory is accessible only to members of the `so-ddmku` group.
>
> **NIG ユーザー:** ビルド済みリファレンス（abismal インデックス含む）、コンテナイメージ、出力データは共有ディレクトリ `/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/` にあります。`so-ddmku` グループのメンバーのみアクセス可能です。

**Example sample throughout this tutorial:** SRX22130352 — human plasma
cell-free DNA (cfDNA), paired-end, ~1M read pairs, hg38.

---

## Prerequisites

### Container runtime

- **NIG supercomputer (kumamoto partition):** Apptainer is available at
  `/opt/pkg/apptainer/1.4.5/bin/apptainer`. Add it to your PATH or use the
  full path in commands below.
- **Other machines:** Docker is supported. Commands are given for both.

### Reference genome files (one-time setup per genome)

Three files are required per genome:

| File | Description |
|------|-------------|
| `hg38.fa` | Genome FASTA |
| `hg38.fa.fai` | FASTA index (samtools faidx) |
| `chrom.sizes` | Chromosome sizes for BigWig |
| `hg38.abismal.idx` | abismal bisulfite index (~2.7 GB for hg38) |

On NIG, pre-built hg38 files are available at:
```
/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/references/
```

For other genomes or a fresh setup, see **Step 2** below.

### A list of SRA experiment accessions

Prepare a plain-text list of SRX/DRX/ERX accessions (one per line) to process
in batch, or use a single accession for a test run.

---

## NIG environment setup

On NIG (kumamoto partition), set these variables once before running any commands in this tutorial:

```bash
# NIG environment setup
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
SIF=$SHARED/containers/pipeline-v2-bs.sif
REF=$SHARED/references
SCRIPTS=$SHARED/scripts
```

The scripts are available in the shared directory at `$SHARED/scripts/`:
- `pipeline-v2-bs.sh` — main BS-seq pipeline
- `fast-download.sh` — FASTQ downloader (ENA API + DDBJ local mirror)

For the full repository (docs, sample lists, etc.):
```bash
git clone https://github.com/inutano/chip-atlas-pipeline-v2.git
```

---

## Step 1: Pull the container

The pipeline uses a dedicated container with DNMTools 1.5.1, samtools 1.22.1,
fastp 1.3.1, and bedGraphToBigWig.

**Apptainer (NIG and other HPC):**
```bash
apptainer pull docker://ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0
```

This creates `pipeline-v2-bs_v1.1.0.sif` in the current directory (~1.3 GB).
You can rename it for convenience:
```bash
mv pipeline-v2-bs_v1.1.0.sif pipeline-v2-bs.sif
```

**Docker:**
```bash
docker pull ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0
```

---

## Step 2: Prepare the reference genome

Skip this step if you are using NIG and the pre-built references at
`/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/references/`.

### 2a. Download hg38

```bash
mkdir -p ref
cd ref
wget https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz
gunzip hg38.fa.gz
```

Expected size: ~3.1 GB uncompressed.

### 2b. Build FASTA index and chrom.sizes

```bash
apptainer exec pipeline-v2-bs.sif samtools faidx hg38.fa
cut -f1,2 hg38.fa.fai > chrom.sizes
```

### 2c. Build abismal index

```bash
apptainer exec pipeline-v2-bs.sif dnmtools abismalidx hg38.fa hg38.abismal.idx
```

Expected index size: ~2.7 GB. Build time: ~30 minutes for hg38 on a
modern server. This only needs to be done once per genome.

**Supported genomes:** hg38, mm10, rn6, ce11, dm6, sacCer3

---

## Step 3: Download FASTQ files

Use the bundled download script to fetch a sample by its experiment accession.
The script resolves all run accessions automatically via the ENA API and
concatenates multiple runs into a single FASTQ pair.

```bash
bash $SCRIPTS/fast-download.sh SRX22130352 ./fastq/
```

Expected output:
```
[ENA] Resolving runs for SRX22130352...
[ENA] SRX22130352: 1 run(s), layout=PAIRED
[RUN] SRR...
[CONCAT] Merging 1 run(s) → SRX22130352
  → SRX22130352_1.fastq.gz (~500 MB)
  → SRX22130352_2.fastq.gz (~500 MB)
[DONE] SRX22130352: 1 run(s) downloaded and merged
```

Notes:
- WGBS data for mammalian genomes is almost exclusively paired-end. SE data
  does occur (older experiments) — the pipeline handles both automatically.
- On NIG, DRX-prefix samples are sourced from the local DDBJ bz2 mirror on
  Lustre (`/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/`) which is
  much faster than downloading from ENA.
- The script is idempotent: if the output files already exist, it exits
  immediately with `[CACHE] already downloaded`.

---

## Step 4: Run the pipeline

### On NIG (Apptainer, kumamoto partition)

Submit a SLURM job on the `kumamoto-c768` partition. The `--bind` flag maps
node-local NVMe scratch (`/data1/tmp`) as the pipeline's `TMPDIR`, which keeps
all intermediates off Lustre during the run.

```bash
sbatch \
  --partition=kumamoto-c768 \
  --account=kumamoto-group \
  --cpus-per-task=16 \
  --mem=64g \
  --time=0-02:00:00 \
  --job-name=bs-SRX22130352 \
  --output=logs/SRX22130352.log \
  --wrap="apptainer exec \
    --bind /data1/tmp:/tmp \
    $SIF \
    bash $SCRIPTS/pipeline-v2-bs.sh \
      --sample-id SRX22130352 \
      --fastq-fwd fastq/SRX22130352_1.fastq.gz \
      --fastq-rev fastq/SRX22130352_2.fastq.gz \
      --genome-fasta $REF/hg38.fa \
      --abismal-index $REF/hg38.abismal.idx \
      --chrom-sizes $REF/chrom.sizes \
      --genome hg38 \
      --outdir output/SRX22130352 \
      --threads 16"
```

### On any machine with Docker

```bash
docker run --rm \
  -v "$(pwd)":/work \
  -v /path/to/ref:/ref:ro \
  -e TMPDIR=/tmp \
  -w /work \
  ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0 \
  bash pipeline-v2-bs.sh \
    --sample-id SRX22130352 \
    --fastq-fwd fastq/SRX22130352_1.fastq.gz \
    --fastq-rev fastq/SRX22130352_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --abismal-index /ref/hg38.abismal.idx \
    --chrom-sizes /ref/chrom.sizes \
    --genome hg38 \
    --outdir output/SRX22130352 \
    --threads 16
```

### Required arguments

| Argument | Description |
|----------|-------------|
| `--sample-id` | Output file prefix (use the experiment accession) |
| `--fastq-fwd` | Forward (R1) FASTQ file |
| `--fastq-rev` | Reverse (R2) FASTQ file (omit for single-end) |
| `--genome-fasta` | Reference FASTA |
| `--abismal-index` | abismal bisulfite index |
| `--chrom-sizes` | Chromosome sizes file |
| `--genome` | Genome ID for CpG count lookup (see table below) |
| `--outdir` | Output directory (created if it does not exist) |
| `--threads` | CPU threads (default: 16) |

**Supported `--genome` values and CpG counts:**

| Genome | CpGs |
|--------|-----:|
| hg38 | 61,959,486 |
| mm10 | 43,816,016 |
| rn6 | 53,698,106 |
| ce11 | 6,263,050 |
| dm6 | 11,787,346 |
| sacCer3 | 710,598 |

The `--genome` argument is required for the CpG coverage calculation in
`stats.tsv`. If omitted or unrecognized, coverage will be reported as 0.

---

## Step 5: Monitor progress

The pipeline logs timestamps at each step to stdout/the SLURM log file:

```
[06:17:01] Step 0: fastp QC/trimming
[06:17:04]   fastp: 3s (PE, trimmed to NVMe)
[06:17:04] Step 1: abismal → format → sort → uniq → dedup BAM
[06:18:05]   abismal: 60s
[06:18:08]   format:  3s
[06:18:09]   sort:    1s
[06:18:11]   uniq:    1s
[06:18:11] Step 1 done: 67s
[06:18:11] Step 2: dnmtools counts
[06:20:00] Step 2 done: 109s
[06:20:00] Step 3: sym + hmr, hypermr, pmd, BigWig (parallel)
[06:20:10] Step 3 done: 10s
[06:20:10] Pipeline complete: 189s (3m)
```

**Expected runtimes** (16 threads):

| Sample size | hg38 PE | Notes |
|-------------|---------|-------|
| ~1M read pairs | ~3 min | cfDNA / test run |
| ~50M read pairs | ~35–40 min | Typical production sample |

The main bottleneck is `dnmtools counts` (per-CpG methylation calculation),
which scales with reads × genome size.

---

## Step 6: Check outputs

A successful run produces the following files in `--outdir`:

| File | Description | Typical size (1M PE) |
|------|-------------|----------------------|
| `SRX22130352.methyl.bw` | Per-CpG methylation fraction BigWig (0–1) | 8 MB |
| `SRX22130352.cover.bw` | Per-CpG read coverage BigWig | 6 MB |
| `SRX22130352.hmr.bed` | Hypomethylated regions (CpG islands, promoters) | 109 KB |
| `SRX22130352.hypermr.bed` | Hypermethylated regions | 1.3 MB |
| `SRX22130352.pmd.bed` | Partially methylated domains | ~165 B |
| `SRX22130352.abismal.stats` | Alignment statistics (YAML) | 1.3 KB |
| `SRX22130352_fastp.json` | QC report from fastp | varies |
| `SRX22130352.stats.tsv` | Summary statistics (15-column TSV) | <1 KB |

### Reading stats.tsv

The `stats.tsv` file is a single-row 15-column TSV with no header:

| Column | Content | Example |
|--------|---------|---------|
| 1 | Sample ID | SRX22130352 |
| 2 | Layout flag (0=SE, 1=PE) | 1 |
| 3 | FASTQ total size (bytes) | 1073741824 |
| 4 | Dedup BAM size (bytes) | 524288000 |
| 5 | Read count (pairs for PE) | 1003060 |
| 6 | Mapping rate (%) | 98.76 |
| 7 | Methylation rate (%) | 77.9 |
| 8 | CpG coverage (fraction of genome CpGs covered) | 0.016 |
| 9 | HMR region count | 2985 |
| 10 | PMD region count | 3 |
| 11 | HyperMR region count | 36765 |
| 12–14 | (empty — reserved for ChIP-seq peak columns) | |
| 15 | Wall-clock time (minutes) | 3 |

### What healthy output looks like

**Mapping rate:** Expect >90% unique mapping for quality mammalian WGBS.
The SRX22130352 cfDNA example: 98.76% total, 95.3% unique.

**Methylation distribution:** Mammalian genomes show a characteristic bimodal
distribution. From SRX22130352:

| Methylation range | CpGs | Fraction |
|-------------------|-----:|----------|
| 0% | 205,556 | 20.8% |
| 1–20% | 4,708 | 0.5% |
| 20–50% | 1,643 | 0.2% |
| 50–80% | 5,937 | 0.6% |
| **80–100%** | **769,516** | **77.9%** |

~78% highly methylated + ~21% unmethylated is the expected signature.
The unmethylated fraction consists mainly of CpG islands and active promoters,
which appear as HMR regions. If you see a flat distribution (all ~50%), the
bisulfite conversion likely failed.

**HMR regions:** For a human sample with reasonable coverage, expect thousands
of HMR regions. The 1M-read cfDNA example gives 2,985 — a real 50M-read
sample would yield proportionally more.

**HyperMR regions:** The 36,765 HyperMR regions for the cfDNA example is
elevated due to low coverage (only ~1.6% of CpGs covered). With full coverage
(50× depth), this number decreases substantially as the caller has more
evidence.

---

## Step 7: Processing multiple samples

For production runs on NIG, use `production-run.sh`, which manages batched
SLURM submission, disk quota monitoring, and error recovery:

```bash
bash $SCRIPTS/production-run.sh submit hg38 samples.tsv \
  --batch-size 90 \
  --threads 8 \
  --time-limit 0-02:00:00
```

The `samples.tsv` format is a tab-separated file with a header row and columns:
`accession`, `genome`, `experiment_type`, `num_reads`.

For the download architecture (how large-scale FASTQ acquisition is managed
to avoid ENA throttling), see `docs/production-download-design.md`.

---

## NIG-specific notes

| Topic | Detail |
|-------|--------|
| Apptainer binary | `/opt/pkg/apptainer/1.4.5/bin/apptainer` |
| NVMe scratch | `/data1/tmp` per node — bind as TMPDIR to keep intermediates off Lustre |
| Pre-built hg38 references | `/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/references/` (hg38.fa, hg38.abismal.idx, chrom.sizes) |
| SLURM partition | `kumamoto-c768` |
| SLURM account | `kumamoto-group` |
| Lustre quota | 954 GB — FASTQ files are large; clean up after each job completes |
| Node-local scratch | `/data1` and `/data2` (1.5 TB NVMe each) — not shared across nodes |

Example SLURM header for a BS-seq job:
```bash
#SBATCH --partition=kumamoto-c768
#SBATCH --account=kumamoto-group
#SBATCH --cpus-per-task=16
#SBATCH --mem=64g
#SBATCH --time=0-02:00:00
```

---

## Pipeline internals (brief)

```
Step 0: fastp QC/trimming
  PE: writes trimmed FASTQs to NVMe scratch (/tmp)
  SE: streams directly into abismal via process substitution (no disk write)

Step 1: abismal alignment → dnmtools format → samtools sort → dnmtools uniq
  All intermediates (mapped.bam, formatted.bam, sorted.bam) live on NVMe
  and are deleted as the next step consumes them.
  Output: dedup.bam

Step 2: dnmtools counts -cpg-only → counts.tsv
  Per-CpG methylation table. Filtered to coverage > 0.
  Main runtime bottleneck (~60% of total wall clock).

Step 3: parallel fan-out (after dnmtools sym)
  ├── dnmtools hmr  → .hmr.bed
  ├── dnmtools hypermr → .hypermr.bed
  ├── dnmtools pmd → .pmd.bed
  └── bedGraphToBigWig (methyl + cover) → .methyl.bw, .cover.bw
```

All intermediate files are written to `$TMPDIR/<sample_id>_<PID>/` and deleted
on pipeline completion. Only the final output files land in `--outdir`.

---

## Troubleshooting

**"Operation not permitted" from dnmtools format**
Single-end reads require special handling. The pipeline detects SE/PE from
the presence of `--fastq-rev`. If you see this error, verify you are not
passing `--fastq-rev` for a SE sample.

**Zero HMR regions**
This is expected for non-mammalian organisms with minimal CpG methylation
(e.g., yeast, *C. elegans*). For mammalian samples, it may indicate very low
coverage or failed bisulfite conversion.

**CpG coverage = 0.0 in stats.tsv**
The `--genome` argument was not provided or the genome ID was not recognized.
Check the supported genome list and re-run, or manually compute coverage from
the CpG count in the summary output.

**abismal.stats not found**
The alignment step failed. Check the SLURM log for abismal error messages.
Common causes: corrupted FASTQ, wrong index path, or out-of-memory.

---

*Container:* `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0`  
*Pipeline script:* `pipeline-v2-bs.sh` (in shared `scripts/` dir on NIG)  
*Investigation notes:* `docs/bisulfite-seq-investigation.md`

---
---

# ChIP-Atlas Pipeline v2: Bisulfite-seq (WGBS) チュートリアル

このチュートリアルでは、ChIP-Atlas v2 Bisulfite-seq パイプラインをコンテナの
取得から結果の確認まで一通り説明します。パイプラインは
[DNMTools](https://github.com/smithlabcode/dnmtools)（abismal アライナー＋下流の
メチル化解析ツール群）を使用し、Apptainer（NIG スーパーコンピュータ）または
Docker（任意のマシン）で動作する単一コンテナにパッケージ化されています。

**本チュートリアルの実例サンプル:** SRX22130352 — ヒト血漿 cfDNA（細胞フリー DNA）、
ペアエンド、約 100 万リードペア、hg38。

---

## 前提条件

### コンテナランタイム

- **NIG スーパーコンピュータ（kumamoto パーティション）:** Apptainer が
  `/opt/pkg/apptainer/1.4.5/bin/apptainer` に用意されています。PATH に追加するか、
  以下のコマンドでフルパスを使用してください。
- **その他のマシン:** Docker も利用できます。両方のコマンドを以下に示します。

### リファレンスゲノムファイル（ゲノムごとに一度だけ必要）

ゲノムごとに 4 つのファイルが必要です：

| ファイル | 説明 |
|----------|------|
| `hg38.fa` | ゲノム FASTA |
| `hg38.fa.fai` | FASTA インデックス（samtools faidx） |
| `chrom.sizes` | BigWig 生成用の染色体サイズ |
| `hg38.abismal.idx` | abismal バイサルファイトインデックス（hg38 で約 2.7 GB） |

NIG では、事前構築済みの hg38 ファイルが以下にあります：
```
/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/references/
```

他のゲノムや初めてセットアップする場合は、後述の **ステップ 2** を参照してください。

### SRA エクスペリメントアクセッション番号のリスト

処理する SRX/DRX/ERX アクセッション番号を 1 行に 1 件記載したテキストファイルを
用意するか、テスト実行では 1 件のみ使用します。

---

## NIG 環境設定

NIG（kumamoto パーティション）では、このチュートリアルのコマンドを実行する前に
以下の変数を設定してください：

```bash
# NIG環境設定
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
SHARED=/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2
SIF=$SHARED/containers/pipeline-v2-bs.sif
REF=$SHARED/references
SCRIPTS=$SHARED/scripts
```

スクリプトは共有ディレクトリ `$SHARED/scripts/` に用意されています：
- `pipeline-v2-bs.sh` — BS-seq メインパイプライン
- `fast-download.sh` — FASTQ ダウンローダー（ENA API + DDBJ ローカルミラー）

リポジトリ全体（ドキュメント、サンプルリストなど）が必要な場合：
```bash
git clone https://github.com/inutano/chip-atlas-pipeline-v2.git
```

---

## ステップ 1: コンテナを取得する

パイプラインには DNMTools 1.5.1、samtools 1.22.1、fastp 1.3.1、
bedGraphToBigWig を含む専用コンテナを使用します。

**Apptainer（NIG およびその他の HPC）:**
```bash
apptainer pull docker://ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0
```

カレントディレクトリに `pipeline-v2-bs_v1.1.0.sif`（約 1.3 GB）が作成されます。
使いやすいように名前を変更できます：
```bash
mv pipeline-v2-bs_v1.1.0.sif pipeline-v2-bs.sif
```

**Docker:**
```bash
docker pull ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0
```

---

## ステップ 2: リファレンスゲノムを準備する

NIG の `/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/references/` にある事前構築済みリファレンスを使用する場合は
このステップを省略できます。

### 2a. hg38 をダウンロード

```bash
mkdir -p ref
cd ref
wget https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz
gunzip hg38.fa.gz
```

展開後のサイズ：約 3.1 GB。

### 2b. FASTA インデックスと chrom.sizes を作成

```bash
apptainer exec pipeline-v2-bs.sif samtools faidx hg38.fa
cut -f1,2 hg38.fa.fai > chrom.sizes
```

### 2c. abismal インデックスを構築

```bash
apptainer exec pipeline-v2-bs.sif dnmtools abismalidx hg38.fa hg38.abismal.idx
```

インデックスサイズ：約 2.7 GB。構築時間：最新のサーバーで hg38 の場合 約 30 分。
ゲノムごとに一度だけ実行すれば OK です。

**対応ゲノム:** hg38、mm10、rn6、ce11、dm6、sacCer3

---

## ステップ 3: FASTQ ファイルをダウンロードする

付属のダウンロードスクリプトを使って、エクスペリメントアクセッション番号でサンプルを
取得します。ENA API を通じて全ランのアクセッション番号を自動解決し、複数ランを
1 つの FASTQ ペアに結合します。

```bash
bash $SCRIPTS/fast-download.sh SRX22130352 ./fastq/
```

期待される出力：
```
[ENA] Resolving runs for SRX22130352...
[ENA] SRX22130352: 1 run(s), layout=PAIRED
[RUN] SRR...
[CONCAT] Merging 1 run(s) → SRX22130352
  → SRX22130352_1.fastq.gz (~500 MB)
  → SRX22130352_2.fastq.gz (~500 MB)
[DONE] SRX22130352: 1 run(s) downloaded and merged
```

補足：
- 哺乳類ゲノムの WGBS データはほぼすべてペアエンドです。SE データも存在しますが
  （古いエクスペリメント）、パイプラインは両方を自動的に処理します。
- NIG では DRX プレフィックスのサンプルは Lustre 上のローカル DDBJ bz2 ミラー
  （`/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/`）から取得されるため、
  ENA からのダウンロードより大幅に高速です。
- スクリプトは冪等です：出力ファイルがすでに存在する場合は
  `[CACHE] already downloaded` と表示して終了します。

---

## ステップ 4: パイプラインを実行する

### NIG の場合（Apptainer、kumamoto パーティション）

`kumamoto-c768` パーティションに SLURM ジョブとして投入します。`--bind` フラグで
ノードローカルの NVMe スクラッチ（`/data1/tmp`）をパイプラインの `TMPDIR` として
マウントし、実行中の中間ファイルを Lustre に書かないようにします。

```bash
sbatch \
  --partition=kumamoto-c768 \
  --account=kumamoto-group \
  --cpus-per-task=16 \
  --mem=64g \
  --time=0-02:00:00 \
  --job-name=bs-SRX22130352 \
  --output=logs/SRX22130352.log \
  --wrap="apptainer exec \
    --bind /data1/tmp:/tmp \
    $SIF \
    bash $SCRIPTS/pipeline-v2-bs.sh \
      --sample-id SRX22130352 \
      --fastq-fwd fastq/SRX22130352_1.fastq.gz \
      --fastq-rev fastq/SRX22130352_2.fastq.gz \
      --genome-fasta $REF/hg38.fa \
      --abismal-index $REF/hg38.abismal.idx \
      --chrom-sizes $REF/chrom.sizes \
      --genome hg38 \
      --outdir output/SRX22130352 \
      --threads 16"
```

### Docker を使う場合（任意のマシン）

```bash
docker run --rm \
  -v "$(pwd)":/work \
  -v /path/to/ref:/ref:ro \
  -e TMPDIR=/tmp \
  -w /work \
  ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0 \
  bash pipeline-v2-bs.sh \
    --sample-id SRX22130352 \
    --fastq-fwd fastq/SRX22130352_1.fastq.gz \
    --fastq-rev fastq/SRX22130352_2.fastq.gz \
    --genome-fasta /ref/hg38.fa \
    --abismal-index /ref/hg38.abismal.idx \
    --chrom-sizes /ref/chrom.sizes \
    --genome hg38 \
    --outdir output/SRX22130352 \
    --threads 16
```

### 必須引数一覧

| 引数 | 説明 |
|------|------|
| `--sample-id` | 出力ファイルのプレフィックス（エクスペリメントアクセッション番号を推奨） |
| `--fastq-fwd` | フォワード（R1）FASTQ ファイル |
| `--fastq-rev` | リバース（R2）FASTQ ファイル（シングルエンドの場合は省略） |
| `--genome-fasta` | リファレンス FASTA |
| `--abismal-index` | abismal バイサルファイトインデックス |
| `--chrom-sizes` | 染色体サイズファイル |
| `--genome` | CpG カウント参照用のゲノム ID（下表参照） |
| `--outdir` | 出力ディレクトリ（存在しない場合は自動作成） |
| `--threads` | CPU スレッド数（デフォルト：16） |

**`--genome` に指定できる値と CpG 数：**

| ゲノム | CpG 数 |
|--------|-------:|
| hg38 | 61,959,486 |
| mm10 | 43,816,016 |
| rn6 | 53,698,106 |
| ce11 | 6,263,050 |
| dm6 | 11,787,346 |
| sacCer3 | 710,598 |

`--genome` は `stats.tsv` の CpG カバレッジ計算に必要です。省略または未認識の場合、
カバレッジは 0 として報告されます。

---

## ステップ 5: 進捗を確認する

パイプラインは各ステップにタイムスタンプ付きのログを標準出力（SLURM ログ）に出力します：

```
[06:17:01] Step 0: fastp QC/trimming
[06:17:04]   fastp: 3s (PE, trimmed to NVMe)
[06:17:04] Step 1: abismal → format → sort → uniq → dedup BAM
[06:18:05]   abismal: 60s
[06:18:08]   format:  3s
[06:18:09]   sort:    1s
[06:18:11]   uniq:    1s
[06:18:11] Step 1 done: 67s
[06:18:11] Step 2: dnmtools counts
[06:20:00] Step 2 done: 109s
[06:20:00] Step 3: sym + hmr, hypermr, pmd, BigWig (parallel)
[06:20:10] Step 3 done: 10s
[06:20:10] Pipeline complete: 189s (3m)
```

**想定実行時間**（16 スレッド）：

| サンプルサイズ | hg38 PE | 備考 |
|--------------|---------|------|
| 約 100 万リードペア | 約 3 分 | cfDNA / テスト実行 |
| 約 5000 万リードペア | 約 35〜40 分 | 典型的な本番サンプル |

主なボトルネックは `dnmtools counts`（CpG ごとのメチル化計算）で、
リード数 × ゲノムサイズに比例してスケールします。

---

## ステップ 6: 出力ファイルを確認する

正常終了すると `--outdir` に以下のファイルが生成されます：

| ファイル | 説明 | 典型的なサイズ（1M PE） |
|----------|------|------------------------|
| `SRX22130352.methyl.bw` | CpG ごとのメチル化率 BigWig（0〜1） | 8 MB |
| `SRX22130352.cover.bw` | CpG ごとのリードカバレッジ BigWig | 6 MB |
| `SRX22130352.hmr.bed` | 低メチル化領域（HMR：CpG アイランド、プロモーターなど） | 109 KB |
| `SRX22130352.hypermr.bed` | 高メチル化領域（HyperMR） | 1.3 MB |
| `SRX22130352.pmd.bed` | 部分的メチル化ドメイン（PMD） | 約 165 B |
| `SRX22130352.abismal.stats` | アライメント統計（YAML 形式） | 1.3 KB |
| `SRX22130352_fastp.json` | fastp による QC レポート | 可変 |
| `SRX22130352.stats.tsv` | サマリー統計（15 列 TSV） | < 1 KB |

### stats.tsv の読み方

`stats.tsv` はヘッダーなしの 1 行・15 列の TSV ファイルです：

| 列 | 内容 | 例 |
|----|----|-----|
| 1 | サンプル ID | SRX22130352 |
| 2 | レイアウトフラグ（0=SE、1=PE） | 1 |
| 3 | FASTQ ファイル合計サイズ（バイト） | 1073741824 |
| 4 | 重複除去後 BAM サイズ（バイト） | 524288000 |
| 5 | リード数（PE の場合はペア数） | 1003060 |
| 6 | マッピング率（%） | 98.76 |
| 7 | メチル化率（%） | 77.9 |
| 8 | CpG カバレッジ（全ゲノム CpG に対する割合） | 0.016 |
| 9 | HMR 領域数 | 2985 |
| 10 | PMD 領域数 | 3 |
| 11 | HyperMR 領域数 | 36765 |
| 12〜14 | （空欄 — ChIP-seq ピーク列のために予約） | |
| 15 | 実行時間（分） | 3 |

### 正常な出力とは

**マッピング率:** 高品質な哺乳類 WGBS では >90% のユニークマッピングが期待されます。
SRX22130352 cfDNA の例：全体 98.76%、ユニーク 95.3%。

**メチル化の分布:** 哺乳類ゲノムは特徴的な二峰性（バイモーダル）分布を示します。
SRX22130352 の例：

| メチル化率の範囲 | CpG 数 | 割合 |
|----------------|------:|------|
| 0% | 205,556 | 20.8% |
| 1〜20% | 4,708 | 0.5% |
| 20〜50% | 1,643 | 0.2% |
| 50〜80% | 5,937 | 0.6% |
| **80〜100%** | **769,516** | **77.9%** |

「約 78% 高メチル化 + 約 21% 非メチル化」が正常なパターンです。非メチル化の部分は
主に CpG アイランドや活性化プロモーターで、HMR 領域として検出されます。
分布が全体的に約 50% のフラットな形になっていた場合、バイサルファイト変換が
失敗している可能性があります。

**HMR 領域数:** 適度なカバレッジのヒトサンプルでは数千の HMR 領域が期待されます。
この 100 万リードの cfDNA サンプルでは 2,985 個 — 5000 万リードの本番サンプルでは
比例してより多くなります。

**HyperMR 領域数:** この cfDNA サンプルの 36,765 という数値はカバレッジが低いため
（CpG 全体の約 1.6% のみカバー）大きくなっています。十分なカバレッジ（50× 深度）
があれば、根拠となる証拠が増えてこの数値は大幅に減少します。

---

## ステップ 7: 複数サンプルを処理する

NIG での本番実行には `production-run.sh` を使用します。バッチ SLURM 投入、
ディスククォータの監視、エラーリカバリーを自動管理します：

```bash
bash $SCRIPTS/production-run.sh submit hg38 samples.tsv \
  --batch-size 90 \
  --threads 8 \
  --time-limit 0-02:00:00
```

`samples.tsv` のフォーマットはヘッダー行付きのタブ区切りファイルで、
`accession`、`genome`、`experiment_type`、`num_reads` 列が必要です。

大規模 FASTQ 取得の仕組み（ENA のレート制限を回避する方法）については
`docs/production-download-design.md` を参照してください。

---

## NIG 固有の情報

| 項目 | 詳細 |
|------|------|
| Apptainer バイナリ | `/opt/pkg/apptainer/1.4.5/bin/apptainer` |
| NVMe スクラッチ | ノードごとの `/data1/tmp` — TMPDIR としてバインドして中間ファイルを Lustre に書かないようにする |
| 事前構築済み hg38 リファレンス | `/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/references/`（hg38.fa、hg38.abismal.idx、chrom.sizes） |
| SLURM パーティション | `kumamoto-c768` |
| SLURM アカウント | `kumamoto-group` |
| Lustre クォータ | 954 GB — FASTQ ファイルは大きいため、ジョブ完了後に削除する |
| ノードローカルスクラッチ | `/data1` および `/data2`（各 1.5 TB NVMe）— ノード間で共有されない点に注意 |

BS-seq ジョブの SLURM ヘッダー例：
```bash
#SBATCH --partition=kumamoto-c768
#SBATCH --account=kumamoto-group
#SBATCH --cpus-per-task=16
#SBATCH --mem=64g
#SBATCH --time=0-02:00:00
```

---

## パイプライン内部処理の概要

```
ステップ 0: fastp QC/トリミング
  PE: トリミング済み FASTQ を NVMe スクラッチ（/tmp）に書き込む
  SE: abismal へのプロセス置換ストリーム（ディスク書き込みなし）

ステップ 1: abismal アライメント → dnmtools format → samtools sort → dnmtools uniq
  全中間ファイル（mapped.bam、formatted.bam、sorted.bam）は NVMe 上に作成され、
  次のステップで使用後すぐに削除される。
  出力: dedup.bam

ステップ 2: dnmtools counts -cpg-only → counts.tsv
  CpG ごとのメチル化テーブル。カバレッジ 0 の CpG は除外。
  実行時間全体の約 60% を占める主なボトルネック。

ステップ 3: 並列処理（dnmtools sym の後）
  ├── dnmtools hmr  → .hmr.bed
  ├── dnmtools hypermr → .hypermr.bed
  ├── dnmtools pmd → .pmd.bed
  └── bedGraphToBigWig（methyl + cover） → .methyl.bw、.cover.bw
```

全中間ファイルは `$TMPDIR/<sample_id>_<PID>/` に書き込まれ、パイプライン完了時に
削除されます。最終出力ファイルのみ `--outdir` に保存されます。

---

## トラブルシューティング

**dnmtools format で "Operation not permitted" エラー**  
シングルエンドリードには特別な処理が必要です。パイプラインは `--fastq-rev` の有無で
SE/PE を自動判別します。SE サンプルに誤って `--fastq-rev` を指定していないか確認
してください。

**HMR 領域が 0 件**  
CpG メチル化がほとんどない非哺乳類生物（酵母、*C. elegans* など）では正常な結果です。
哺乳類サンプルで 0 件の場合、カバレッジが極端に低いか、バイサルファイト変換に
失敗している可能性があります。

**stats.tsv の CpG カバレッジが 0.0**  
`--genome` 引数が省略されているか、ゲノム ID が認識されていません。
対応ゲノムリストを確認して再実行するか、サマリー出力の CpG 数から手動で計算して
ください。

**abismal.stats ファイルが見つからない**  
アライメントステップが失敗しています。SLURM ログで abismal のエラーメッセージを
確認してください。よくある原因：破損した FASTQ、誤ったインデックスパス、
メモリ不足。

---

*コンテナ:* `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0`  
*パイプラインスクリプト:* `scripts/pipeline-v2-bs.sh`  
*調査ノート:* `docs/bisulfite-seq-investigation.md`
