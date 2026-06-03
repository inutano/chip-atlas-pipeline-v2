# ChIP-Atlas v2 — Production Processing Plan

How we process the full experiment catalogue on NIG kumamoto: the per-job
resource settings (from benchmarking), how the batch lists are generated, and
how jobs are submitted. This is the operational contract; it supersedes any
ad-hoc settings used during the 2026-06 debugging.

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

| Genome | `--cpus-per-task` | `--mem` | `-t` | conc/node | per-sample wall | source |
|---|---|---|---|---|---|---|
| sacCer3, ce11, dm6 | 4 | 16g | 0-02:00:00 | 32 (cpu-bound) | short | small-genome default |
| rn6 | 5 | 20g | 0-02:00:00 | 25 (mem-bound) | ~10–20 min | **use hg38 setting** (index ~14 GB < hg38) |
| mm10 | 5 | 20g | 0-02:00:00 | 25 (mem-bound) | tbd | hg38 setting is **safe** (index ~13 GB < hg38, ~4 GB margin); **benchmark to optimise** before the 219k run |
| hg38 | 5 | 20g | 0-02:00:00 | 25 (mem-bound) | ~9 min | `memory-benchmark.md` (168/hr) |

Memory driver: the **bwa-mem2 index** (hg38 ~16 GB resident → 18 GB min, 20 GB
with pipe overhead). Small genomes are tiny indexes; their floor is
`samtools sort -m 4G × threads`, so **16 GB is the safe minimum** (we saw OOM at
8 GB on sacCer3). rn6/mm10 indexes (~9 GB resident) → 20 GB is safe.

### BS-seq  (`pipeline-v2-bs.sh`)

| Genome | `--cpus-per-task` | `--mem` | `-t` | conc/node | per-sample wall | source |
|---|---|---|---|---|---|---|
| sacCer3, ce11, dm6 | 4 | 24g | 0-02:00:00 | 21 | — | small-genome default |
| rn6, mm10, hg38 | 4 | 16g | **0-04:00:00** | 32 | ~180 min | `memory-benchmark-bs.md` (10.4/hr) |

Memory driver: **`samtools sort -m 2G × threads` + Step-3 `hypermr`** (~17 GB
floor on hg38), *not* the abismal index. BS-seq is ~18× slower than ChIP
(abismal alignment dominates) → needs the **4-hour** limit. Alt for mammals if
4 h is unacceptable: `8c / 24g / 0-02:30:00`. Watch for very deep WGBS (>30 GB
FASTQ) outliers that may need 6 h.

> These are the cgroup `--mem` values that make concurrency self-limiting and
> keep the node responsive. Do **not** raise concurrency by lowering `--mem`
> below these — slots above the cpu-bound count are blocked by cpu anyway, and
> you'd only discard the safety margin (and risk OOM).

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
   ├─ Downloader  (1 job on the LOGIN partition a001-a003, 1–2 cores, 3-day limit)
   │    per experiment: resolve runs, download+concatenate all runs → one FASTQ;
   │    ENA-first routing; aria2c -x4 -s4; ≤4 concurrent downloads (=16 conns);
   │    buffer 100; writes staging/<exp>/.ready
   │
   └─ Processor   (1 long-running coordinator job)
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

## 5. Changes required vs the scripts as they stand (2026-06-03)

The settings above are NOT yet what the deployed scripts do. To execute this plan:

1. **`production-process.sh`: stop running pipelines inline; submit one SLURM job
   per experiment** with `--cpus-per-task`/`--mem`/`-t` from §1. (Today it runs 32
   inline on one `--exclusive --mem=0` node — the cause of the node crashes.)
2. **`submit-separated.sh`: drop `--exclusive --mem=0`** from the processor; pass
   the per-genome `(cores, mem, time)` through to the per-experiment jobs. Add a
   per-genome settings lookup table keyed by `(pipeline, genome)`.
3. **Downloader → login partition `a001-a003`** (3-day limit, 1–2 cores) so it
   doesn't consume kumamoto compute. Shared with other users, but the downloader
   is light (confirmed OK to run there). (Today it runs on kumamoto.)
4. **Self-exit / robustness**: processor should exit when its downloader job is
   gone (not loop forever waiting for `.downloads-complete`); clear stale
   `.downloads-complete` at download start (done); node-exclude/health gate.
5. Keep the already-deployed download fixes: ENA-first routing, SRA fallback
   (apptainer PATH), 16-connection budget.

Implement test-first; smoke-test on one small batch before scaling.

---

## 6. Decisions (confirmed 2026-06-03)

- **Processing unit = experiment** — one SLURM job per experiment, with all its
  runs concatenated by the downloader (the pipeline is built for this).
- **Submission model = per-experiment `sbatch`** with `--mem` (not the inline
  `--exclusive --mem=0` loop). This is what the benchmark assumes and what keeps
  the node safe.
- **Downloader runs on the login partition `a001-a003`** (shared with other
  users; the light downloader is fine there).
- **rn6 uses the human (hg38) settings** for both pipelines (ChIP 5c/20g; BS
  4c/16g/4h) — its index is smaller than hg38's.
- **mm10**: the hg38 setting (5c/20g) is *safe* (index ~13 GB < hg38). Because
  mm10 has ~219k experiments, **run a quick memory benchmark right before mm10's
  batch** to see if a lower `--mem` (→ higher concurrency) is justified — tuning,
  not a blocker.
