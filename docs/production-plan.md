# ChIP-Atlas v2 — Production Processing Plan

How we process the full experiment catalogue on NIG kumamoto: the per-job
resource settings (from benchmarking), how the batch lists are generated, and
how jobs are submitted. This is the operational contract; it supersedes any
ad-hoc settings used during the 2026-06 debugging.

**Current as of 2026-06-09** — the §1 settings reflect the OOM-threshold benchmark
and the sacCer3 smoke test, and supersede the per-genome numbers in the older
`memory-benchmark*.md` docs (those captured generous-cap footprints, which over-state
the true OOM floor; see §1). Deployed + validated; first pass is ready (§5).

Companion docs: [`memory-benchmark.md`](memory-benchmark.md) (ChIP cores/mem),
[`memory-benchmark-bs.md`](memory-benchmark-bs.md) (BS cores/mem),
[`v2-final-architecture.md`](v2-final-architecture.md),
[`production-download-design.md`](production-download-design.md),
[`scripts/experiment-list/README.md`](../scripts/experiment-list/README.md) (list provenance).

---

## 0. Cluster facts that drive every setting

NIG kumamoto compute nodes: **128 cores, 512 GB RAM, ~1.5 TB local NVMe (`/data1`)**, 6 nodes (`at137,138,140-143`).

SLURM enforces memory via cgroup:
```
TaskPlugin           = task/cgroup,task/affinity
ConstrainRAMSpace    = yes        # --mem is a HARD per-job cap
ConstrainSwapSpace   = yes
SelectTypeParameters = CR_CORE_MEMORY   # schedules on BOTH cpu and mem
DefMemPerCPU         = 8000 (8 GB)
```

**Consequences (non-negotiable):**
- **Every per-experiment job MUST set `--mem`.** With cgroup enforcement, `--mem`
  isolates the job: if it over-uses, only *its own* processes are OOM-killed.
- **Never use `--mem=0` (or `--exclusive --mem=0`).** Without a cgroup cap the
  kernel OOM-killer fires node-wide and kills system daemons. On 2026-06-02 this
  killed `sssd` on several nodes → SSH/auth died → nodes appeared "down." Admin
  confirmed nodes hitting load 128+/mem 100% lose SSH. **This is the bug we are
  fixing with this plan.**
- **Concurrency is a SLURM scheduling result, not a number we hand-pick.** If
  each experiment is its own job with the right `--mem`/`--cpus`, SLURM packs
  `min(128/cores, 512/mem)` per node automatically and never oversubscribes.

---

## 1. Per-job resource settings (the benchmarked decision)

**Processing unit = one experiment (SRX/DRX/ERX), not a run/sample.** An
experiment may have multiple sequencing runs (SRR/DRR); `fast-download.sh`
resolves the experiment → all its runs and concatenates them into one FASTQ (or
PE pair) per experiment. The pipeline then processes that aggregated FASTQ. So
**one SLURM job = one experiment** (with all its runs), and the batch-list rows
are experiment accessions. "Concurrency" and `--mem` below are per-experiment.

One genome assembly (and one pipeline) per batch ⇒ all jobs in a batch share
these settings. Pick the row by `(pipeline, genome)`.

### ChIP-seq / ATAC-seq / DNase-seq  (`pipeline-v2.sh`)

| Genome | `--cpus-per-task` | `--mem` | `-t` | conc/node | source |
|---|---|---|---|---|---|
| sacCer3, ce11, dm6, TAIR10 | 4 | 16g | 0-02:00:00 | 32 (cpu-bound) | OOM-threshold sweep: small-ChIP floor **12g** (OOM at 8–10g) |
| rn6, mm10, hg38 | 5 | 20g | 0-02:00:00 | 25 | established floor + throughput sweet spot; see note |

Memory driver: the **bwa-mem2 index** + **MACS3** (read-count-driven). Small
genomes have tiny indexes; their floor is `samtools sort` (16 GB safe; sweep floor
12g). Mammals: 20 GB is the established floor and the throughput sweet spot
(5c/20g = 25/node, cpu-and-mem balanced).

⚠ **Mammal-ChIP OOM rate at 20 GB is non-trivial.** Mammal-ChIP memory tracks the
MACS3 tag count (≈ read depth), so deep samples span ~15–34 GB; an OOM-rate test
(2026-06-09) saw several deep samples OOM at 20 GB (and even at 24 GB). We do **not**
escalate per sample — an OOM is recorded as `.fail` tagged `oom` (§1.5) and counted.
After the first pass, if the `oom` tally for mammal-ChIP is too high, raise its
setting and reprocess just that bucket. (The benchmark set skews deep, so the
population OOM rate is lower than the test's.)

### BS-seq  (`pipeline-v2-bs.sh`)

| Genome | `--cpus-per-task` | `--mem` | `-t` | conc/node | source |
|---|---|---|---|---|---|
| sacCer3, ce11, dm6, TAIR10 | 4 | **16g** | 0-02:00:00 | 32 (cpu-bound) | OOM-threshold sweep: small-BS floor **10g** |
| rn6, mm10, hg38 | 4 | **16g** | 0-02:00:00 | 32 (cpu-bound) | sweep: hg38 (most CpGs) passes the full pipeline at **8g** |

**Memory (OOM-threshold sweep, 2026-06-09 — supersedes the earlier "rises with
genome size" model).** The BS peak is driven by `samtools sort -m 2G × 4 = 8 GB`
(genome-independent, depth-fills) and *not* the sum of that plus the abismal index
or `hypermr` CpG table: those load at **separate pipeline stages** (abismal exits
before sort runs), so they don't stack. The 2.7 GB hg38 abismal index and the
62 M-CpG `hypermr` table each stay under the 8 GB sort peak. The sweep confirmed
**16 GB is safe for every genome** (a deep small-BS sample OOM'd only below 10 GB;
hg38 ran the whole pipeline at 8 GB). At 4 cpu, anything ≤16 GB is **cpu-bound at
32/node**, so 16 GB is both the simple default and concurrency-optimal — no reason
to go lower.

**Time, not memory, is the BS risk.** BS-seq is ~18× slower than ChIP (abismal
dominates) and some deep WGBS samples exceed **2 h**. We deliberately keep the
**2-hour** limit on every BS job rather than pay 4 h on all of them for the rare
monster: a sample that exceeds 2 h is killed by SLURM → recorded as `.fail`
tagged `timeout` → reprocessed in the **retry pass** with a longer limit (see
§1.5). The smoke test (2026-06-09) confirmed a 2.8 GB sacCer3 BS sample completes
in ~6 min once downloaded.

> ⚠ **Step-3 `dnmtools pmd` can hang.** The 2026-06-04 sacCer3 benchmark caught
> `pmd` spinning at 99.9% CPU for 38+ min on a 0.7 M-CpG sample (`hmr`/`hypermr`
> finished in seconds; only `pmd` stuck). Left unguarded this runs every BS job
> to the SLURM time limit → fail. **Fix: wrap each Step-3 caller in `timeout`**
> in `pipeline-v2-bs.sh` (they're already non-blocking — a killed `pmd` just
> yields no `.pmd.bed` → 0 PMD regions → sample still completes). PMDs aren't
> biologically meaningful on small genomes anyway. (Added to §5.)

> These are the cgroup `--mem` values that make concurrency self-limiting and
> keep the node responsive. Do **not** raise concurrency by lowering `--mem`
> below these — slots above the cpu-bound count are blocked by cpu anyway, and
> you'd only discard the safety margin (and risk OOM).

---

## 1.5 Failure handling — uniform first pass, then a retry pass

The corpus is processed in **one uniform first pass** at the §1 settings, with NO
per-sample memory escalation. Every per-experiment job ends in a marker, and a
`.fail` carries a **reason word** so failures are tallied by type:

| outcome | marker | FASTQ | meaning |
|---|---|---|---|
| success | `.done` | dropped | `stats.tsv` written |
| OOM | `.fail` = `oom` | **kept** | exceeded `--mem` at this setting |
| walltime | `.fail` = `timeout` | kept | exceeded `-t` (mostly deep BS) |
| bad data | `.fail` = `data` | dropped | deterministic — MACS3 no peaks / 0 covered CpGs (rc 42) |
| transient exhausted | `.fail` = `infra` | kept | node/network; `MAX_RETRIES` used up |

- **OOM is a counted failure, not an auto-retry** (decided 2026-06-09). Re-running
  a sample at the same `--mem` just OOMs again, so it goes straight to the `oom`
  bucket. Genuinely transient losses (NODE_FAIL/preemption) retry up to
  `MAX_RETRIES`; TIMEOUT / OUT_OF_MEMORY / CANCELLED do not (deterministic at this
  setting). The coordinator routes a SLURM-killed orphan by its `sacct` State
  (`classify_orphan`), so a >walltime sample can't churn forever.
- **Tally after the pass:**
  `find <staging> -name .fail -exec cat {} \; | sort | uniq -c` → counts by reason.
  Then decide *globally*: if a class's `oom`/`timeout` count is too high, raise that
  class's `--mem`/`-t` and **reprocess just that bucket** — its FASTQ is still
  staged, so no re-download.
- Decision logic is pure and unit-tested: `classify_outcome`, `classify_orphan`,
  `apply_outcome` in `scripts/failure-classify.sh`.

---

## 2. Building the batch lists

Source list is **generated, not stored** — produced by the SPARQL queries in
[`scripts/experiment-list/`](../scripts/experiment-list/) (vendored from the
`insdc-rdf` repo) and consumed here. Current snapshot: 532,700 experiments,
sha256 `8867eb49…` (see that dir's README).

```bash
# one-time per snapshot, run where chipatlas_fast.tsv lives:
scripts/make-batches.sh  chipatlas_fast.tsv  sample-lists/batches/  5000
```

This writes, under `sample-lists/batches/`:
- `<genome>-<pipeline>/batch-NNNN.tsv` — **5,000 experiments each**, one
  `(genome, pipeline)` per file (4 cols: accession, genome, strategy, `SINGLE`).
- `manifest.tsv` — one row per batch (genome, pipeline, batch_id, path, n, status).

Batches are emitted **smallest-genome-first** (rn6 → ce11 → dm6 → sacCer3 →
TAIR10 → mm10 → hg38). Verified invariants: per-group totals match an independent
tally, every batch == 5,000 except each group's last, zero duplicate accessions.

Catalogue shape (114 batches): rn6 3,533 · ce11 7,465 · dm6 16,882 · sacCer3
19,013 · TAIR10 21,696 · mm10 219,364 · hg38 244,747. hg38+mm10 = 87%.

---

## 3. Submitting a batch

Each batch runs as the **separated download + processor** model
([`production-download-design.md`](production-download-design.md)): a downloader
fills a staging dir; a processor turns each staged experiment into **its own SLURM
job** with the batch's `(cores, mem, time)`.

```
submit-batch <genome> <pipeline> sample-lists/batches/<genome>-<pipeline>/batch-NNNN.tsv
   │
   ├─ Downloader  (SLURM job on kumamoto-c768, 2 cores / 4 GB, cgroup-capped)
   │    per experiment: resolve runs, download+concatenate all runs → one FASTQ;
   │    ENA-first routing; aria2c -x4 -s4; ≤4 concurrent downloads (=16 conns);
   │    buffer 100; writes staging/<exp>/.ready. On a compute node (NOT the a001
   │    login partition) because the SRA fasterq-dump fallback is real compute +
   │    scratch and must be cgroup-isolated — see §5.
   │
   └─ Processor   (1 long-running coordinator job, also on kumamoto-c768)
        polls staging for .ready, and for each submits ONE per-EXPERIMENT SLURM job:
          sbatch -p kumamoto-c768 --account=kumamoto-group \
                 --cpus-per-task=<C> --mem=<M> -t <T>  \   # ← §1 settings
                 --wrap "process one experiment (apptainer exec pipeline-v2[-bs].sh)"
        SLURM cgroup-isolates each job at <M> and packs min(128/C, 512/M) per node.
```

### Download settings (gentle on ENA)
- Routing: **ENA-first** for all (ENA serves DRR `.gz` too); DDBJ-local bz2 only
  a DRR fallback; SRA `fasterq-dump` last (`scripts/download-route.sh`).
- **aria2c `-x4 -s4`** × **`DL_CONCURRENT=4`** = **16 connections** to ENA.
  (`6×8=48` got the IP rate-limited to ~98% failures on 2026-06-02.)
- Buffer 100 `.ready` ahead; FASTQs staged on `so-ddmku` shared storage.

### Why per-sample jobs (not the old inline loop)
- cgroup `--mem` per job ⇒ an over-heavy sample is OOM-killed *in its own
  cgroup*, never touching `sssd`/the node.
- SLURM schedules across **all healthy nodes** and never oversubscribes cpu/mem.
- No hand-tuned `MAX_CONCURRENT`; no `--exclusive --mem=0`.

---

## 4. Progress tracking & operations

- **Progress** is reconstructed from disk (so it can't desync):
  `scripts/batch-status.sh sample-lists/batches/ <outbase>` → per-group
  done/total/pct (done = a sample's `stats.tsv` exists).
- **Output**: `/home/okishinya/chipatlas-v2/<genome>/<prefix6>/<exp>/` (group
  `so-ddmku`, SGID-inherited).
- **Resumable**: re-submitting a batch skips `.done` samples and retries `.fail`
  (≤ `MAX_ATTEMPTS=3`). Nothing is lost across interruptions.
- **Node health**: skip nodes that fail the `apptainer exec <sif> echo OK` test
  (e.g. a node whose Lustre `/home` hasn't remounted → `rc=255`). Per-sample
  jobs that land on a bad node fail transiently and reschedule.

---

## 5. Implementation status (2026-06-09)

The plan is implemented, deployed, and smoke-tested; the first pass is
production-ready. Status of the original change list:

- ✅ **Per-experiment `sbatch`** with cgroup `--mem`/`--cpus` from §1 — no inline
  loop, no `--mem=0`. `production-process.sh` is a thin coordinator;
  `process-experiment.sh` is the job body. Validated under load (40+ benchmark jobs,
  zero node crashes).
- ✅ **`submit-separated.sh`** pulls per-genome settings from `job-settings.sh`
  (`job_settings <pipeline> <genome>` → `cores mem time`); no `--mem=0`.
- ✅ **Self-exit / robustness** — coordinator exits on downloads-complete + nothing
  ready/in-flight; clears stale `.downloads-complete`; orphan recovery is bounded by
  `sacct` state (§1.5) so a timeout can't loop forever.
- ✅ **Download fixes** — ENA-first routing, SRA fallback (apptainer PATH),
  16-connection budget.
- ✅ **`pipeline-v2-bs.sh` Step-3 `timeout`** (pmd-hang fix) — validated in the smoke
  test (yeast `pmd.bed` empty, sample completes). `STEP0_START` log bug fixed.
- ✅ **Failure buckets with reason tags** + uniform first pass (§1.5).
- ✅ **Downloader stays on kumamoto-c768** (2 cores, cgroup-capped). We tried the
  a001-a003 login partition (2026-06-09) to free the slot, but the SRA `fasterq-dump`
  fallback ran heavy compute writing to `/tmp` on the shared login node — unsafe
  (could break SSH for all users) — so we reverted. The `login` SLURM partition is
  also INACTIVE (can't sbatch to it). A 2-core downloader slot is negligible;
  protecting the shared nodes wins.
- ✅ **`.fail` marker disambiguation fix** — the downloader stores an integer
  download-attempt count in `.fail`; the processor writes a reason word. `sample_terminal`
  now disambiguates by content (non-integer = already-terminal downstream → skip),
  fixing the `[: : integer expression expected` crash on a processor/legacy `.fail`.

**Smoke test (2026-06-09, sacCer3, 15 chip + 15 bs):** 30/30 `.done`, 0 fail; both
pipelines produced complete, valid outputs (bigwig, 3 peak sets, methyl/cover bigwig,
hmr/hypermr/pmd, `stats.tsv`); both coordinators terminated cleanly. Key lesson: at
scale the bottleneck is **download robustness** (checksum-retry), not compute.

---

## 6. Decisions (confirmed; latest 2026-06-09)

- **Processing unit = experiment** — one SLURM job per experiment, with all its
  runs concatenated by the downloader.
- **Submission model = per-experiment `sbatch`** with cgroup `--mem` (never
  `--exclusive --mem=0`).
- **All classes 4c / 16g / 2h, except mammal-ChIP (rn6/mm10/hg38) = 5c / 20g / 2h.**
  OOM-threshold-confirmed; mammal-ChIP is the one class that needs >16 GB. rn6 uses
  the mammal ChIP setting (its index ≤ hg38's).
- **Uniform first pass, then a retry pass** — OOM and timeout are *counted* failures
  (§1.5) reconsidered globally, not escalated per sample.
- **mm10 memory benchmark: done** (OOM-threshold sweep, 2026-06-09) — folded into the
  settings above; no separate pre-mm10 benchmark needed.
- **Downloader runs on kumamoto-c768** (cgroup-capped SLURM job), NOT the a001-a003
  login partition — the SRA `fasterq-dump` fallback is real compute and must be
  isolated on a compute node, not run on a shared login node (tried + reverted
  2026-06-09; §5). Protecting the shared nodes outweighs the 2-core slot.
- **Order: colleague-requested rn6 first**, then smallest-genome-first for the rest
  (ce11 → dm6 → sacCer3 → TAIR10 → mm10 → hg38); sacCer3 path validated by the
  2026-06-09 smoke test.
