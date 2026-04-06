# Production Lessons: ce11 Test Run (2026-04-06)

First production-scale run: 2,693 ce11 samples on 6 kumamoto nodes.

## Issues Found

### 1. Disk quota exhaustion (CRITICAL)
- 954 GB Lustre quota fills up from accumulated results (~45 MB/sample × 2,693 = ~120 GB)
  plus concurrent FASTQs (~7 GB × 42 running = ~300 GB)
- Hit 922 GB at 39% completion
- **Fix**: Use `--output-base` to write results to shared directory with larger quota

### 2. Submission backpressure timeout
- The `--max-concurrent 90` backpressure loop ran in an SSH session that timed out
- Only submitted 107 of 2,693 samples before the script exited
- **Fix**: Submit all at once (`--max-concurrent 99999`), let SLURM handle queuing
- Or: run the submission script inside `screen`/`tmux` on NIG

### 3. chrom.sizes path not expanded in heredoc
- Single-quoted heredoc template didn't expand `${genome}` variable
- All Wave 1 jobs (90) failed with `no_bigwig_output`
- **Fix**: Added `__CHROM_SIZES__` placeholder with sed replacement

### 4. count_my_jobs double output
- `grep -c || echo 0` produces `0\n0` when grep has no matches
- Caused `wait_for_job_slots` to loop forever
- **Fix**: Use `|| true` instead of `|| echo 0`

### 5. Download failures (17 samples)
- `no_fastq_found`: ENA didn't have FASTQ and fasterq-dump fallback failed
- Retriable via `production-run.sh retry ce11`

## Performance Summary

| Tier | Samples | Avg download | Avg pipeline | Avg total |
|------|--------:|-----------:|-----------:|----------:|
| <1M | 5 | 21s | 31s | 0.9 min |
| 1-10M | 504 | 19s | 103s | 2.0 min |
| 10-50M | 531 | 64s | 402s | 7.8 min |
| 50M+ | 39 | 363s | 1133s | 24.9 min |
| **Overall** | **1,079** | **53s** | **287s** | **5.7 min** |

| Experiment type | Samples | Avg total |
|----------------|--------:|----------:|
| TFs and others | 689 | 4.0 min |
| Histone | 217 | 7.8 min |
| RNA polymerase | 112 | 3.9 min |
| ATAC-Seq | 60 | 20.0 min |

**Throughput**: 216 samples/hr across 6 nodes (36/hr/node)

**Failures**: 23 total — 21 no_fastq_found (ENA download), 2 pipeline_exit_1

**Projection**: Full ce11 (2,693) would take ~12.5 hours. hg38 (197K) ~46 days on 6 nodes.

## What Worked

- Single-container pipeline: consistent, no startup overhead
- NVMe scratch: fast intermediate I/O
- Append-only status file: no corruption from 42 concurrent writers
- FASTQ cleanup: down to 4 KB after completion
- SLURM queue management: 2,659 jobs submitted, processed smoothly
- Average 5.7 min/sample (including download) — consistent with benchmarks

## Recommendations for hg38 Production

1. **Must use `--output-base`** — shared directory with >>1 TB quota
2. Submit all at once — don't use backpressure via SSH
3. Monitor disk during first hour to catch issues early
4. Pre-resolve SRX→SRR before submission (TogoID bulk)
5. Run `retry` after main run completes for download failures
