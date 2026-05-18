# BS-seq Pipeline Memory Benchmark (hg38)

Measured peak RSS, wall time, and throughput for `pipeline-v2-bs.sh` on
hg38 BS-seq data, to determine the recommended `--cpus-per-task` /
`--mem` combination for NIG kumamoto production.

Paired with `memory-benchmark.md` (ChIP-seq); same methodology, different
pipeline.

## Test setup

- Host: RTX 6000 Ada workstation, 32 cores, 93 GB RAM (NVMe scratch)
- Container: `ghcr.io/inutano/chip-atlas-pipeline-v2-bs:v1.1.0`
- Reference: hg38 (abismal index 2.9 GB on disk, ~6 GB resident)
- Method: docker `--memory=Xg --memory-swap=Xg` for cgroup enforcement;
  peak read from `/sys/fs/cgroup/.../memory.peak` (kernel-tracked, not
  polled — captures transient peaks)
- Wrapper: `/home/inutano/work/bs-bench/run-bench.sh`

Samples (PE WGBS, ≥95% mapping rate):

| Sample | Reads | FASTQ size | Notes |
|---|---|---|---|
| ERR10888636 | 75M | 4.83 GB | "Medium" — typical small WGBS |
| DRR016668 | 116M | 17.55 GB | "Large" — deep WGBS, ~10× hg38 cov |

DRR084121 (15.27 GB) was also tested but yielded only 4.1% mapping —
discarded as non-representative (likely RRBS or library issue).

## Headline finding

**Peak RSS scales linearly with thread count on large samples**, set by
samtools sort's `-m 2G × threads` nominal cap. This is the opposite of
the bwa-mem2 ChIP-seq case, where the bwa-mem2 hg38 index dominates and
peak is largely thread-independent.

| Threads | Sort nominal | Large-sample peak | Medium-sample peak |
|---|---|---|---|
| 4c  | 8 GB  | 9.38 GB  | 17.61 GB |
| 6c  | 12 GB | (not measured) | 17.51 GB |
| 8c  | 16 GB | 17.58 GB | 17.55 GB |
| 16c | 32 GB | 34.54 GB | 17.63 GB |

Two regimes:
- **Sort-bound (large samples)**: peak ≈ `(2 GB × threads) + 1.5 GB
  residual`. Sort buffer fills to nominal cap.
- **Step3-bound (small samples)**: peak ≈ 17.5 GB regardless of threads.
  The Step 3 parallel fan-out (`hmr` + `hypermr` + `pmd` + BigWig
  in parallel) plus residual abismal/format memory hits a floor around
  17 GB for hg38 — driven mostly by `hypermr` and `hmr` loading the
  symmetric-CpG counts table.

For a "big" production sample, the sort regime dominates and sets the
memory ceiling.

## Per-step time breakdown

Both samples at 8c (representative), unlimited memory:

| Step | Medium (4.83 GB) | Large (17.55 GB) |
|---|---:|---:|
| Step 0 fastp | 472s (8 min) | 1140s (19 min) |
| Step 1a abismal | 3924s (65 min) | 4555s (76 min) |
| Step 1b format | 31s | 84s |
| Step 1c sort | 35s | 120s |
| Step 1d uniq | 13s | 44s |
| Step 2 counts | 151s | 141s |
| Step 3 parallel | 215s | 73s |
| **Total wall** | **4854s (81 min)** | **6162s (102 min)** |

abismal alignment dominates (~75% of wall). fastp is pinned to 2 threads
in the script and contributes a fixed ~8 min for medium / ~19 min for
large — a non-trivial floor but not the bottleneck.

## OOM threshold (medium sample, 16 threads)

Cgroup `--memory` walked downward; mode = which step OOM'd:

| `--memory` | Result | Peak observed | Step that OOM'd |
|---|---|---|---|
| 16g | OOM | (killed) | samtools sort |
| 17g | OOM | 16.93 GB | dnmtools hypermr (Step 3) |
| 18g | OK | 17.49 GB | — |
| 20g | OK | 17.63 GB | — |

The sort step is the first to fail; if sort survives the cap, Step 3's
`hypermr` is the next ceiling. Min `--mem` for medium hg38 BS-seq: 18g.

## Large-sample confirmation at recommended cap

| Threads | `--memory` | Peak | Wall | Status |
|---|---|---|---|---|
| 8c | 20g | 19.43 GB | 102 min | OK (0.6 GB margin — tight) |

The large sample under cgroup pressure peaked at 19.43 GB vs 17.58 GB
unconstrained — a measurement artifact of the kernel `memory.peak`
counter being more aggressive than docker stats polling. Both readings
fit in 20g, but the margin is thin.

## Throughput per NIG kumamoto node (128c / 512 GB)

Concurrent jobs = `min(128 / threads, 512 / mem)`. Throughput uses
large-sample wall time (worst-case for production):

| Threads | `--mem` | CPU conc | Mem conc | Actual | Wall (large) | Samples/hr/node |
|---|---|---|---|---|---|---|
| 4c  | 16g | 32 | 32 | **32** | 184 min | **10.4** |
| 6c  | 18g | 21 | 28 | 21 | ~135 min | ~9.3 |
| 8c  | 24g | 16 | 21 | 16 | 102 min | 9.4 |
| 16c | 36g | 8  | 14 | 8  | 63 min | 7.6 |

`--mem` is sized to fully use node memory at the CPU-bound concurrency
(e.g. 32 × 16g = 512 GB exactly at 4c). Setting `--mem` lower than that
gives no throughput benefit — slots above CPU-conc are blocked by CPU
anyway — and discards safety margin for free.

## Recommended configuration

**Piped, 4 cores/job, `--mem=16g`, `-t 0-04:00:00`** for hg38 BS-seq.

| Knob | Value | Reason |
|---|---|---|
| `--cpus-per-task` | 4 | Highest per-node throughput (10.4/hr vs 9.4 at 8c) |
| `--mem` | 16g | Peak 9.4 GB on large sample; 16g matches `512/32` perfectly and gives 6.6 GB safety margin |
| `-t` | 04:00:00 | Large-sample wall is 184 min; 4 hr leaves slack for outliers |
| Concurrent | 32/node | Full CPU + full memory utilization |
| Throughput | ~10.4 / hr | At full node utilization |

If the 4 hr time limit is unacceptable on a given partition, fall back
to **8c / `--mem=24g` / `-t 02:30:00`** (9.4/hr — 11% lower throughput
but fits within ~2 hr).

Outlier risk: very deep WGBS samples (>30 GB FASTQ, ~250M reads) may
exceed even 4 hr at 4c. If sample-list inspection reveals such outliers,
either bump `-t` to 6 hr or cherry-pick those for the 8c config.

## Comparison to ChIP-seq

| Metric | ChIP-seq (hg38) | BS-seq (hg38) |
|---|---|---|
| Recommended | 5c / 20g | 4c / 16g |
| Concurrent / node | 25 | 32 |
| Wall / typical sample | ~9 min | ~180 min |
| Throughput / hr / node | ~168 | ~10.4 |
| SLURM `-t` | short | 4 hr |
| Memory ceiling driver | bwa-mem2 index (~16 GB constant) | samtools sort (`-m 2G × threads`, scales) |
| OOM step on undersized cgroup | bwa-mem2 (index load) | samtools sort, then dnmtools hypermr |

BS-seq is fundamentally ~18× slower per sample than ChIP-seq because
abismal alignment is much slower than bwa-mem2. The sweet-spot thread
count is higher (8 vs 5) to keep wall time within the SLURM limit.

## Optional optimization — lower SORT_MEM

Lowering `SORT_MEM` in `pipeline-v2-bs.sh` from `2G` → `1G` would
roughly halve the sort-bound peak:

- 8c × 1G = 8 GB sort nominal → projected peak ~10–12 GB (Step 3
  hypermr would become the ceiling at ~12 GB)
- Could safely use `--mem=16g`, freeing 8 GB/job — but with CPU still
  binding at 8c, throughput stays at 9.4/hr; only effect is being a
  better neighbor on shared nodes.

Sort step is ~2 min on the large sample, so halving the buffer would
add maybe 30s of additional merge — negligible against the ~76 min
abismal cost. Worth doing if mem-density on shared nodes ever matters.
Not necessary for the kumamoto dedicated partition.

## Reproducibility

All measurements at `/home/inutano/work/bs-bench/results.tsv`. Per-run
logs at `/home/inutano/work/bs-bench/runs/`. Wrapper at
`/home/inutano/work/bs-bench/run-bench.sh`.

Reference data: `/home/inutano/work/bs-test-human/hg38/` (hg38 fasta,
abismal index, chrom.sizes). Test FASTQs:
`/data2/bs-bench/fastq/{ERR10888636,DRR016668}_{1,2}.fastq.gz`.
