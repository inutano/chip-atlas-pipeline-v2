# Production Download & Processing Architecture

## Problem

The current `production-run.sh` couples FASTQ download and pipeline processing
in a single SLURM job. At scale (400K+ samples across 6 nodes), this causes:

1. **ENA throttling**: 96 concurrent HTTPS connections to `ftp.sra.ebi.ac.uk`
   triggers rate limiting or IP blocks. We observed connection resets and
   corrupted parallel downloads during testing.
2. **Wasted CPU allocation**: SLURM jobs hold 8 cores while waiting for
   downloads (30–300s per sample). Cores sit idle during I/O.
3. **Unpredictable disk usage**: downloads overlap with processing, making
   Lustre quota hard to manage. We hit the 954 GB quota during the ce11
   production run.
4. **Cascading failures**: download failures waste the full SLURM time
   allocation and require retry of the entire job.

### Local data sources on NIG

**SRA Lite mirror** (`/lustre9/open/database/ddbj-dbt/dra-public/dra/sralite/`):
Quality scores stripped — unusable. Mirror stopped ~1 year ago. `fasterq-dump`
is unreliable (frequent failures causing resource waste). Not viable.

**DDBJ FASTQ mirror** (`/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/`):
Contains `.fastq.bz2` files, but **only for DRA-submitted (DRR) experiments**.
SRA/ERA directories exist as empty stubs — no actual FASTQ files for SRX/ERX.
DRA data is current (updated through April 2026).

**Coverage for ChIP-Atlas (432,318 experiments):**

| Prefix | Experiments | Local FASTQ | Source needed |
|--------|------------:|-------------|---------------|
| DRX    |  7,344 (1.7%) | bz2 on Lustre (100% hit rate) | Local copy + decompress |
| SRX    | 390,424 (90.3%) | None (empty stubs) | ENA HTTPS download |
| ERX    | 34,550 (8.0%) | None (empty stubs) | ENA HTTPS download |

Investigation confirmed: 15/15 random DRX samples found with valid
`.fastq.bz2` files. 30/30 random SRX/ERX samples had empty directories.
The DDBJ fastqlist metadata file is stale (last entry from 2013) but the
DRA filesystem data is current.

**Decompression performance** (tested on kumamoto node):
- `bzcat` (single-threaded): 36 MB/s → 219 MB bz2 in 35s
- `pbzip2 -dc -p4` (4 threads): 145 MB/s → same file in 8.7s
- bwa-mem2 consumes input at ~13 MB/s, so even `bzcat` is never a bottleneck

## Design: Separated Download and Processing

Split the production workflow into two independent phases that communicate
through the filesystem.

```
┌─────────────────────────┐     ┌─────────────────────────┐
│  Phase 1: Downloader    │     │  Phase 2: Processor     │
│  (SLURM job on login    │     │  (SLURM batch jobs on   │
│   partition, 1-2 cores) │     │   kumamoto partition)   │
│                         │     │                         │
│  - Reads sample list    │     │  - Scans staging dir    │
│  - DRX: local bz2 copy │     │    for "ready" samples  │
│    + decompress to gz   │────>│  - Submits SLURM jobs   │
│  - SRX/ERX: ENA HTTPS   │     │  - Each job processes   │
│    download (rate-limit) │     │    one sample           │
│  - Watches disk quota   │     │  - Marks "done" on      │
│  - Marks "ready" when   │<────│    completion           │
│    verified             │     │  - Reports to status    │
│  - Deletes FASTQs after │     │    TSV                  │
│    "done"               │     │                         │
└─────────────────────────┘     └─────────────────────────┘
         │                                │
         ▼                                ▼
   staging/{SRX}/                   output/{SRX}/
     ├── _1.fastq.gz                  ├── .bw
     ├── _2.fastq.gz                  ├── .narrowPeak (×3)
     ├── .ready   ◄── download done   ├── .bb (×3)
     ├── .running ◄── job started     └── ...
     └── .done    ◄── job finished
```

### Phase 1: Downloader

A long-running SLURM job on the **login partition** (a001-a003, 192 cores,
3-day time limit). Uses 1–2 cores, minimal memory.

**Download routing:**

1. **DRX** → copy `.fastq.bz2` from local Lustre mirror at
   `/lustre9/open/database/ddbj-dbt/dra-public/dra/fastq/DRA*/DRA*/{DRX}/`,
   decompress with `pbzip2 -dc` and recompress with `pigz` to `.fastq.gz`
   (or leave uncompressed if disk allows).
2. **ERR/SRR** → download `.fastq.gz` from ENA HTTPS via `aria2c -x 8 -s 8`
   with md5 checksum verification.
3. **ERR/SRR fallback** → `fasterq-dump` via container (last resort).

**Rate limiting:**

- Max concurrent ENA downloads: configurable (default: 4–6).
- DRX local copies are not rate-limited (Lustre-to-Lustre, fast).
- Lustre disk quota check before each download. Pause when usage exceeds
  `--disk-limit-gb` (default: 400 GB).
- Backoff on ENA errors (HTTP 429, connection reset): exponential backoff
  starting at 60s.

**FASTQ lifecycle:**

```
download started → staging/{SRX}/{SRR}_1.fastq.gz (partial)
download + verified → staging/{SRX}/.ready
SLURM job starts → staging/{SRX}/.running (downloader won't delete)
SLURM job finishes → staging/{SRX}/.done
downloader sees .done → rm -rf staging/{SRX}/
```

The `.ready` / `.running` / `.done` markers are empty files used for
coordination. No database or message queue needed.

### Phase 2: Processor

Periodic SLURM batch submission on **kumamoto partition** (can run as a
loop with sleep, or triggered by the downloader via a signal file).

**Behavior:**

1. Scan `staging/` for directories containing `.ready` but NOT `.running`
   or `.done`.
2. For each ready sample, submit a SLURM job that:
   a. Writes `.running` marker.
   b. Copies FASTQ from Lustre staging to local NVMe (`/data1/tmp`).
   c. Runs `pipeline-v2.sh` (or `pipeline-v2-bs.sh` for Bisulfite-seq).
   d. On success: writes `.done` marker, appends to status TSV.
   e. On failure: removes `.running`, appends error to status TSV.
3. Respect `--max-concurrent` limit (don't over-submit).
4. Loop with configurable interval (e.g., every 60s).

**SLURM jobs no longer include download time**, so:
- The `--time-limit` can be tighter (2h instead of 3h).
- CPU cores are never idle waiting for network I/O.
- Failed downloads don't waste SLURM allocation.

### Dispatch: ChIP-seq vs Bisulfite-seq

The processor checks `experiment_type` from the sample list:
- `Bisulfite-Seq` → `pipeline-v2-bs.sh` with the BS-seq container
- Everything else → `pipeline-v2.sh` with the ChIP-seq container

Both pipelines share the same CLI interface (`--sample-id`, `--fastq-fwd`,
`--fastq-rev`, `--outdir`, `--threads`) plus pipeline-specific reference
arguments.

### Configuration

Both phases share a config file or common CLI options:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--staging-dir` | `production-{genome}/staging` | FASTQ staging area (Lustre) |
| `--output-dir` | `production-{genome}/results` | Final output directory |
| `--max-downloads` | 4 | Concurrent ENA download limit |
| `--max-concurrent` | 96 | Max SLURM processing jobs |
| `--threads` | 8 | CPUs per SLURM job (TBD from benchmark) |
| `--disk-limit-gb` | 400 | Pause downloads at this Lustre usage |
| `--buffer-size` | 100 | Max samples downloaded but not yet processed |
| `--status-file` | `production-{genome}/status.tsv` | Append-only progress tracking |

### Error Handling

**Download errors:**
- md5 mismatch → retry up to 3 times with exponential backoff.
- ENA connection error → backoff 60s, 120s, 240s, then skip and log.
- Skipped samples collected in a "failed downloads" list for manual review.

**Processing errors:**
- SLURM job failure → `.running` removed, error logged to status TSV.
- Retry: processor re-submits samples without `.done` (up to `--max-retries`).
- Persistent failures (3+ retries) → marked as `permanent_fail` in status.

## Disk Budget

Available Lustre quota for staging depends on the output destination.
If `--output-base` points to the collaborator's larger shared storage,
the full 954 GB home quota is available for staging + overhead.

Assumptions:
- Lustre quota: 954 GB total, reserve 100 GB for overhead → 850 GB usable
- Final outputs stay on `--output-base` (separate filesystem), not counted

**Compressed FASTQ sizes by read count (hg38, PE, gzipped):**

| Read tier | Avg compressed size | % of hg38 samples |
|-----------|--------------------:|-------------------:|
| < 1M      | ~50 MB              | ~10%               |
| 1–10M     | ~500 MB             | ~25%               |
| 10–50M    | ~3 GB               | ~35%               |
| 50–200M   | ~12 GB              | ~25%               |
| 200M+     | ~40 GB              | ~5%                |

Weighted average across the full distribution: ~4 GB per sample (compressed).

**Buffer size at different limits:**

| Lustre budget | Avg sample size | Buffer capacity |
|--------------:|----------------:|----------------:|
| 200 GB        | 4 GB            | ~50 samples     |
| 400 GB        | 4 GB            | ~100 samples    |
| 800 GB        | 4 GB            | ~200 samples    |

At 96 concurrent SLURM jobs (8 cores × 96 = 768 cores) with ~8 min avg
pipeline time, processing consumes ~720 samples/hour. A 100-sample buffer
lasts ~8 minutes of processing — tight but workable if the downloader keeps
pace. A 200-sample buffer provides ~16 minutes of runway.

**Recommendation:** default `--buffer-size 100`, `--disk-limit-gb 400`.
This leaves ~500 GB headroom on Lustre for any intermediate spill, logs,
and the status tracking files. Tune up if `--output-base` is on separate
storage and more quota is available for staging.

## Migration from Current production-run.sh

The current `production-run.sh` will be refactored into two scripts:

1. `production-download.sh` — Phase 1 (downloader)
2. `production-run.sh` — Phase 2 (processor), refactored to read from
   staging dir instead of downloading

The status TSV format remains the same (append-only, 14 columns). The
`status` and `summary` subcommands work unchanged. The `submit` subcommand
becomes the processor loop. The `retry` subcommand works on processing
failures only (download retries are handled by the downloader).

## Core Count Benchmark

The optimal `--threads` setting is TBD. Theoretical analysis (Amdahl's law
with ~80% parallelizable pipeline) suggests fewer cores per job yields higher
cluster throughput, but real-world factors (memory bandwidth, I/O contention,
Lustre metadata pressure) favor larger allocations.

**Planned benchmark:** Use 3 kumamoto nodes (1 per configuration), each
running as many samples as possible in 12 hours:

| Node | Cores/job | Concurrent jobs | Goal |
|------|----------:|----------------:|------|
| at137 | 4 | 32 | Measure total samples completed |
| at138 | 8 | 16 | Same |
| at140 | 16 | 8 | Same |

Pre-download FASTQs to staging to isolate compute performance from download
variability. Measure: total samples processed, average per-sample time,
memory high-water mark per job.

## Design Decisions

1. **Downloader runs on the login partition** (a001-a003, 3-day limit,
   1–2 cores). Gateway processes are killed by admins. The login partition
   has idle 192-core nodes with a 3-day time limit — use 1 core for the
   downloader, leaving 191 idle (acceptable since login nodes are designed
   for this).

2. **DDBJ local bz2 for DRX, ENA HTTPS for SRX/ERX.** Only 1.7% of
   ChIP-Atlas samples (7,344 DRX) have local FASTQs on the NIG Lustre
   mirror. The remaining 98.3% (425K SRX/ERX) require ENA download.
   DDBJ HTTPS (`ddbj.nig.ac.jp`) can be tried as a domestic mirror for
   ERR/SRR as well, though filesystem investigation showed no local FASTQs
   for these prefixes.

3. **Keep FASTQs compressed** (`.fastq.gz`) on Lustre. Both fastp and
   bwa-mem2 read gzipped input natively. abismal (BS-seq) also reads
   `.fastq.gz`. Compressed FASTQs use ~3× less Lustre quota, which is
   critical given the 954 GB limit. The decompression step in
   `fast-download.sh` should be removed.

4. **DRX local copy decompresses bz2 and recompresses to gz** (or stores
   uncompressed) so the pipeline sees a uniform input format regardless of
   origin. `pbzip2 -dc file.bz2 | pigz > file.fastq.gz` if pigz is
   available, otherwise `bzcat file.bz2 | gzip > file.fastq.gz`.
