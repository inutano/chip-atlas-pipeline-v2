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

### Why not use local SRA files on NIG?

NIG/DDBJ mirrors NCBI `.sra` files at `/lustre9/open/database/ddbj-dbt/dra-public/dra/sralite/`,
but only in SRA Lite format (quality scores stripped — unusable for our pipeline).
The mirror also stopped updating ~1 year ago. Additionally, `fasterq-dump` is
unreliable in practice — frequent failures cause CPU and memory allocation loss.
The v1 pipeline used local `.sra` files successfully, but this path is no longer
viable for v2.

## Design: Separated Download and Processing

Split the production workflow into two independent phases that communicate
through the filesystem.

```
┌─────────────────────────┐     ┌─────────────────────────┐
│  Phase 1: Downloader    │     │  Phase 2: Processor     │
│  (single long-running   │     │  (SLURM batch jobs)     │
│   process, NOT a SLURM  │     │                         │
│   job)                  │     │                         │
│                         │     │                         │
│  - Reads sample list    │     │  - Scans staging dir    │
│  - Downloads FASTQs     │     │    for "ready" samples  │
│  - Rate-limited (N      │────>│  - Submits SLURM jobs   │
│    concurrent downloads)│     │  - Each job processes   │
│  - Watches disk quota   │     │    one sample           │
│  - Marks "ready" when   │     │  - Marks "done" on      │
│    verified             │<────│    completion           │
│  - Deletes FASTQs after │     │                         │
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

A single long-running process (run in `tmux`/`screen` on the gateway or a
login node, NOT as a SLURM job) that continuously downloads FASTQs.

**Behavior:**

1. Read the sample list TSV (accession, genome, experiment_type, num_reads).
2. Skip samples that already have `.ready`, `.running`, or `.done` markers.
3. Download the next sample's FASTQs from ENA via `aria2c -x 8 -s 8` (HTTPS).
4. Verify md5 checksum against ENA's reported hash.
5. Write a `.ready` marker file on success.
6. Loop, respecting concurrency and quota limits.

**Rate limiting:**

- Max concurrent downloads: configurable (default: 4–6).
- Lustre disk quota check before each download. Pause when usage exceeds
  threshold (e.g., 80% of quota).
- Backoff on ENA errors (HTTP 429, connection reset): exponential backoff
  starting at 60s.

**FASTQ lifecycle:**

```
download started → staging/{SRX}/{SRR}_1.fastq.gz (partial)
download + md5 verified → staging/{SRX}/.ready
SLURM job starts → staging/{SRX}/.running (downloader won't delete)
SLURM job finishes → staging/{SRX}/.done
downloader sees .done → rm -rf staging/{SRX}/
```

The `.ready` / `.running` / `.done` markers are empty files used for
coordination. No database or message queue needed.

### Phase 2: Processor

Periodic SLURM batch submission (can run as a cron job or a loop with sleep).

**Behavior:**

1. Scan `staging/` for directories containing `.ready` but NOT `.running`
   or `.done`.
2. For each ready sample, submit a SLURM job that:
   a. Writes `.running` marker.
   b. Runs `pipeline-v2.sh` (or `pipeline-v2-bs.sh` for Bisulfite-seq).
   c. On success: writes `.done` marker, appends to status TSV.
   d. On failure: removes `.running`, appends error to status TSV.
3. Respect `--max-concurrent` limit (don't over-submit).
4. Loop with configurable interval (e.g., every 60s).

**SLURM jobs no longer include download time**, so:
- The `--time-limit` can be tighter (2h instead of 3h).
- CPU cores are never idle waiting for network I/O.
- Failed downloads don't waste SLURM allocation.

### Disk Budget

For hg38 at steady state (download ahead of processing):

| Item | Size per sample | Count | Total |
|------|----------------:|------:|------:|
| FASTQ pair (compressed) | ~2 GB | 20 buffered | ~40 GB |
| Pipeline intermediates (NVMe) | ~15 GB peak | 16 concurrent | ~240 GB (NVMe, not Lustre) |
| Final outputs | ~15 MB | accumulates | grows |

With 20 samples buffered on Lustre + concurrent processing intermediates
on local NVMe, Lustre usage stays well within the 954 GB quota. The
downloader pauses automatically when the buffer is full or quota is near.

### Configuration

Both phases share a config file or common CLI options:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--staging-dir` | `production-{genome}/staging` | FASTQ staging area (Lustre) |
| `--output-dir` | `production-{genome}/results` | Final output directory |
| `--max-downloads` | 4 | Concurrent download limit |
| `--max-concurrent` | 96 | Max SLURM jobs |
| `--threads` | 8 | CPUs per SLURM job |
| `--disk-limit-gb` | 800 | Pause downloads at this Lustre usage |
| `--buffer-size` | 50 | Max samples downloaded but not yet processed |
| `--status-file` | `production-{genome}/status.tsv` | Append-only progress tracking |

### Dispatch: ChIP-seq vs Bisulfite-seq

The processor checks `experiment_type` from the sample list:
- `Bisulfite-Seq` → `pipeline-v2-bs.sh` with the BS-seq container
- Everything else → `pipeline-v2.sh` with the ChIP-seq container

Both pipelines have the same interface (`--sample-id`, `--fastq-fwd`,
`--fastq-rev`, `--outdir`, `--threads`) plus pipeline-specific reference
arguments.

### Core Count Benchmark

The optimal `--threads` setting is TBD. Theoretical analysis (Amdahl's law
with ~80% parallelizable pipeline) suggests fewer cores per job yields higher
cluster throughput, but real-world factors (memory bandwidth, I/O contention,
Lustre metadata pressure) favor larger allocations.

**Planned benchmark:** Run 100 hg38 samples at 4, 8, and 16 cores/job on
NIG kumamoto. Measure:
- Total wall-clock time for the batch
- Average per-sample pipeline time
- Lustre I/O metrics (if available)
- Memory high-water mark per job

This benchmark should use the separated architecture (pre-downloaded FASTQs)
to isolate compute performance from download variability.

### Error Handling

**Download errors:**
- md5 mismatch → retry up to 3 times with exponential backoff.
- ENA connection error → backoff 60s, 120s, 240s, then skip and log.
- Skipped samples collected in a "failed downloads" list for manual review.

**Processing errors:**
- SLURM job failure → `.running` removed, error logged to status TSV.
- Retry: processor re-submits samples without `.done` (up to `--max-retries`).
- Persistent failures (3+ retries) → marked as `permanent_fail` in status.

### Migration from Current production-run.sh

The current `production-run.sh` can be refactored into two scripts:

1. `production-download.sh` — Phase 1 (downloader)
2. `production-run.sh` — Phase 2 (processor), refactored to read from
   staging dir instead of downloading

The status TSV format remains the same (append-only, 14 columns). The
`status` and `summary` subcommands work unchanged. The `submit` subcommand
becomes the processor loop. The `retry` subcommand works on processing
failures only (download retries are handled by the downloader).

## Open Questions

1. **Gateway vs login node for downloader**: The downloader is a long-running
   process. On NIG, should it run on the gateway (`gw`) or on a compute node
   via an interactive SLURM session? Gateway is simpler but may have network
   restrictions.

2. **DDBJ fallback for DRR samples**: `fast-download.sh` already routes DRR
   accessions to DDBJ first. Should the downloader use this routing, or
   always go to ENA for consistency?

3. **Compressed vs decompressed FASTQs**: The current pipeline accepts both
   `.fastq` and `.fastq.gz`. Keeping FASTQs compressed on Lustre saves ~3×
   disk space. fastp and bwa-mem2 both read gzipped input natively. Should
   we skip the decompression step in `fast-download.sh`?

4. **Optimal buffer size**: How many samples should be pre-downloaded? Too
   few → processing stalls waiting for downloads. Too many → wastes Lustre
   quota. Depends on relative download vs processing speed. Start with 50
   and tune based on observation.
