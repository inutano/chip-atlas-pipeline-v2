# メモリ使用量とパイプ/逐次実行の比較

Pipeline v2 の ChIP-seq パイプラインにおけるメモリ使用量の調査結果です。
hg38 ゲノム、PE サンプル（SRX26106775, 8.3M reads）で測定しました。

## 背景

NIG kumamoto パーティション（128コア/515GB RAM ノード）でスループットを最大化するには、1ジョブあたりのコア数・メモリ使用量と同時実行数のバランスが重要です。パイプ処理（全ツール同時実行）と逐次処理（1ツールずつ実行）でメモリ使用量がどう変わるかを調査しました。

## パイプ処理のメモリ内訳

パイプ処理ではすべてのツールが同時に動作し、メモリが積み重なります。
各プロセスのピーク RSS を計測しました（8コア、メモリ制限なし）：

| プロセス | ピーク RSS | 内訳 |
|----------|----------:|------|
| bwa-mem2 | 18.25 GB | ゲノムインデックス（~16 GB）+ ワーキングメモリ（~2 GB） |
| samtools（全体） | 5.48 GB | sort バッファ（`-m 4G × 3 threads`）+ collate/fixmate/markdup |
| fastp | 1.16 GB | リードバッファ |

パイプ全体のピーク RSS は **19.4 GB** です。各ツールのピークは同時に発生しないため、
単純合計（24.9 GB）よりも低くなります。

## パイプ vs 逐次実行の比較

8コアでの測定結果：

| 方式 | 実行時間 | ピーク RSS | 説明 |
|------|----------|-----------|------|
| パイプ | 359s | 19.4 GB | 全ツール同時実行、メモリが積み重なる |
| 逐次 | 480s | 18.2 GB | 1ツールずつ実行、ピーク = bwa-mem2 のみ |
| **差分** | **+121s (+34%)** | **-1.2 GB (-6%)** | |

メモリ差はわずか 1.2 GB です。bwa-mem2 のゲノムインデックス（~16 GB）がメモリ使用量の大部分を占めるため、パイプ処理のオーバーヘッドは相対的に小さいです。

## bwa-mem2 の最小メモリ要件

hg38 における bwa-mem2 単体の最小メモリをテストしました（Docker `--memory` による cgroup 制限）：

| メモリ制限 | 結果 | 備考 |
|-----------|------|------|
| 16 GB | **OOM killed**（exit 137, 31秒で強制終了） | インデックスロード中に超過 |
| 18 GB | 成功 | bwa-mem2 単体の最小要件 |
| 20 GB | 成功 | |
| 22 GB | 成功 | |

**hg38 における bwa-mem2 の最小メモリ: 18 GB/プロセス**

## パイプ処理の最小メモリ要件

パイプ処理では同時実行中の他ツールのメモリが加算されるため、
bwa-mem2 単体よりも多くのメモリが必要です（5コアでの測定）：

| メモリ制限 | 結果 | 実行時間 | ピーク RSS |
|-----------|------|---------|-----------|
| 18 GB | **OOM killed** | - | - |
| 20 GB | 成功 | 564s | 18.8 GB |
| 22 GB | 成功 | 528s | 18.8 GB |
| 24 GB | 成功 | 508s | 18.8 GB |

**パイプ処理の最小メモリ: 20 GB/ジョブ**

## コア数別スループット比較

各構成でのスループットを計算しました（515 GB ノード）：

### パイプ処理（20 GB/ジョブ）

| コア/ジョブ | 同時実行 | メモリ合計 | 1ジョブ時間 | スループット/時 |
|-----------|---------|----------|-----------|-------------:|
| 5c | 25 | 500 GB | ~536s | ~168 |
| 6c | 21 | 420 GB | ~508s | ~149 |
| 8c | 16 | 320 GB | ~359s | ~160 |

### 逐次処理（18 GB/ジョブ）

| コア/ジョブ | 同時実行 | メモリ合計 | 1ジョブ時間 | スループット/時 |
|-----------|---------|----------|-----------|-------------:|
| 4c | 28* | 504 GB | 671s | ~150 |
| 5c | 25 | 450 GB | 601s | ~150 |
| 6c | 21 | 378 GB | ~480s | ~158 |

*4c は CPU では 32 並列だが、メモリ制限（515 GB / 18 GB = 28）で制約される

### 結論

パイプ処理と逐次処理のスループットは **ほぼ同等**（~150 サンプル/時）です。
逐次処理は同時実行数を増やせますが、1ジョブの実行時間が長くなり、結果として相殺されます。

## 推奨構成

**パイプ処理、6コア/ジョブ、20 GB/ジョブ** を推奨します。

| 項目 | パイプ 6c | 逐次 5c | 逐次 4c |
|------|----------|---------|---------|
| スループット | ~150/時 | ~150/時 | ~150/時 |
| メモリ/ジョブ | 20 GB | 18 GB | 18 GB |
| メモリ余裕 | 95 GB（安全） | 65 GB（十分） | 11 GB（危険） |
| NVMe I/O | 最小（パイプ） | 重い（中間 BAM） | 重い |
| 中間ファイル | なし | ~3-5 GB/ジョブ | ~3-5 GB/ジョブ |
| 障害時の挙動 | パイプ全体が失敗 | ステップ単位で再試行可 | ステップ単位で再試行可 |

パイプ処理が推奨される理由:
- スループットが同等で、NVMe への I/O 負荷が少ない
- 中間ファイルを書かないため、ディスク容量を節約
- NIG kumamoto での 6 時間ベンチマークで 29.7 サンプル/時の実績あり
- 95 GB のメモリ余裕で本番運用に十分なマージン

## 小ゲノムでの考慮事項

上記はすべて hg38（ゲノムインデックス ~16 GB）の結果です。
小さいゲノムではインデックスサイズが大幅に小さくなります：

| ゲノム | bwa-mem2 インデックス | 最小メモリ/ジョブ | 4c で最大同時実行 |
|--------|---------------------|-----------------|-----------------|
| hg38 | ~16 GB | ~18 GB | 28（メモリ制約） |
| ce11 | ~0.5 GB | ~2 GB | 32（CPU 制約） |
| dm6 | ~0.3 GB | ~2 GB | 32（CPU 制約） |
| sacCer3 | ~0.02 GB | ~2 GB | 32（CPU 制約） |

小ゲノムでは 4コア/ジョブ（32 並列）がメモリ制限なく動作します。
`production-run.sh` の `--threads` はゲノムごとに設定可能です。

---

# Memory Usage and Piped vs Sequential Execution Comparison

Investigation of memory usage in the Pipeline v2 ChIP-seq pipeline.
Measured with hg38 genome, PE sample (SRX26106775, 8.3M reads).

## Background

To maximize throughput on NIG kumamoto nodes (128 cores / 515 GB RAM),
the balance between cores per job, memory usage, and concurrent job count
is critical. We investigated how piped execution (all tools running
simultaneously) compares to sequential execution (one tool at a time)
in terms of memory usage and throughput.

## Per-Process Memory Breakdown (Piped)

In piped mode, all tools run simultaneously and their memory stacks.
Peak RSS measured per process (8 cores, no memory limit):

| Process | Peak RSS | Breakdown |
|---------|---------|-----------|
| bwa-mem2 | 18.25 GB | Genome index (~16 GB) + working memory (~2 GB) |
| samtools (all) | 5.48 GB | sort buffers (`-m 4G × 3 threads`) + collate/fixmate/markdup |
| fastp | 1.16 GB | Read buffers |

Total pipe peak RSS: **19.4 GB**. Individual peaks don't occur simultaneously,
so the total is less than the sum (24.9 GB).

## Piped vs Sequential Comparison

Measured at 8 cores:

| Mode | Wall clock | Peak RSS | Notes |
|------|-----------|---------|-------|
| Piped | 359s | 19.4 GB | All tools concurrent, memory stacks |
| Sequential | 480s | 18.2 GB | One tool at a time, peak = bwa-mem2 only |
| **Delta** | **+121s (+34%)** | **-1.2 GB (-6%)** | |

The memory difference is only 1.2 GB. The bwa-mem2 genome index (~16 GB)
dominates memory usage, making the piping overhead relatively small.

## bwa-mem2 Minimum Memory (hg38)

Tested with Docker `--memory` cgroup limits:

| Memory limit | Result | Notes |
|-------------|--------|-------|
| 16 GB | **OOM killed** (exit 137, killed at 31s) | Exceeded during index load |
| 18 GB | Passes | Minimum for bwa-mem2 alone |
| 20 GB | Passes | |
| 22 GB | Passes | |

**Minimum memory for bwa-mem2 on hg38: 18 GB per process.**

## Piped Pipeline Minimum Memory

The piped pipeline needs more than bwa-mem2 alone due to concurrent tool
memory (measured at 5 cores):

| Memory limit | Result | Time | Peak RSS |
|-------------|--------|------|---------|
| 18 GB | **OOM killed** | - | - |
| 20 GB | Passes | 564s | 18.8 GB |
| 22 GB | Passes | 528s | 18.8 GB |
| 24 GB | Passes | 508s | 18.8 GB |

**Minimum memory for piped pipeline: 20 GB per job.**

## Throughput Comparison by Configuration

Calculated for a 515 GB node:

### Piped (20 GB/job)

| Cores/job | Concurrent | Total memory | Per-job time | Throughput/hr |
|-----------|-----------|-------------|-------------|-------------:|
| 5c | 25 | 500 GB | ~536s | ~168 |
| 6c | 21 | 420 GB | ~508s | ~149 |
| 8c | 16 | 320 GB | ~359s | ~160 |

### Sequential (18 GB/job)

| Cores/job | Concurrent | Total memory | Per-job time | Throughput/hr |
|-----------|-----------|-------------|-------------|-------------:|
| 4c | 28* | 504 GB | 671s | ~150 |
| 5c | 25 | 450 GB | 601s | ~150 |
| 6c | 21 | 378 GB | ~480s | ~158 |

*4c CPU limit is 32, but memory constraint (515 GB / 18 GB = 28) caps it at 28.

### Conclusion

Piped and sequential throughput is **roughly equivalent** (~150 samples/hr).
Sequential allows more concurrent jobs but each takes longer — the effects
cancel out.

## Recommended Configuration

**Piped, 6 cores/job, 20 GB/job.**

| | Piped 6c | Sequential 5c | Sequential 4c |
|---|---|---|---|
| Throughput | ~150/hr | ~150/hr | ~150/hr |
| Memory/job | 20 GB | 18 GB | 18 GB |
| Memory headroom | 95 GB (safe) | 65 GB (ok) | 11 GB (risky) |
| NVMe I/O | Minimal (piped) | Heavy (intermediate BAMs) | Heavy |
| Intermediates | None | ~3-5 GB/job | ~3-5 GB/job |
| Failure mode | Whole pipe fails | Per-step retry possible | Per-step retry possible |

Piped is recommended because:
- Same throughput with less NVMe I/O pressure
- No intermediate files — saves disk space
- Proven at 29.7 samples/hr sustained in the 6-hour NIG benchmark
- 95 GB memory headroom provides a safe production margin

## Smaller Genomes

The above results are specific to hg38 (genome index ~16 GB).
Smaller genomes have much smaller index sizes:

| Genome | bwa-mem2 index | Min memory/job | Max concurrent at 4c |
|--------|---------------|---------------|---------------------|
| hg38 | ~16 GB | ~18 GB | 28 (memory-limited) |
| ce11 | ~0.5 GB | ~2 GB | 32 (CPU-limited) |
| dm6 | ~0.3 GB | ~2 GB | 32 (CPU-limited) |
| sacCer3 | ~0.02 GB | ~2 GB | 32 (CPU-limited) |

For small genomes, 4 cores/job (32 concurrent) works without memory issues.
The `--threads` parameter in `production-run.sh` can be set per genome.
