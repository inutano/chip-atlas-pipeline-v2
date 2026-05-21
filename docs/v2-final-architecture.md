# ChIP-Atlas Pipeline v2 — Final Architecture

What the v2 pipeline actually is, as built and running in production. This
is the doc to read first if you want the current state. For the journey
that got us here, see [`README.md`](README.md).

## At a glance

- **Modern tooling**: fastp → bwa-mem2 → SAMtools 1.22 → MACS3 (ChIP) and
  fastp → DNMTools abismal → DNMTools format/sort/uniq/counts/hmr/pmd
  (BS-seq). Replaces v1's Bowtie2 2.2.2 + SAMtools 0.1.19 + MACS2 + bmap.
- **Single-container piped pipelines.** Each per-sample run launches one
  container (Apptainer on NIG, Docker elsewhere) that streams everything
  through pipes; only final outputs land on shared storage.
- **NVMe scratch for intermediates.** Per-sample working dir lives on node-
  local NVMe (`/data1/tmp` on NIG kumamoto), deleted on job exit. The
  pipeline never writes intermediate BAMs to Lustre.
- **Outputs land on shared storage** at `/home/okishinya/chipatlas-v2/<genome>/<prefix6>/<experiment>/`,
  group-owned (`so-ddmku`) so collaborators can read.
- **No workflow engine.** Plain bash scripts orchestrated by SLURM. CWL was
  trialled and abandoned in favor of simpler shell ([`v2-initial-plan.md`](v2-initial-plan.md)
  has the original CWL design for context).

## Two production models

| Model | When to use | Entry point | How it works |
|---|---|---|---|
| **SLURM array** | Small genomes (sacCer3, ce11) where per-sample wall is short and download dominates | [`scripts/nig/submit-sacCer3.sh`](../scripts/nig/submit-sacCer3.sh) | One array task per sample. Each task: download → dispatch into container → write outputs. Skip-on-`stats.tsv` makes resubmits cheap. |
| **Separated dl / proc** | Larger genomes (dm6, rn6, mm10, hg38) where pipeline cost dominates and the processor must not starve | [`scripts/nig/submit-separated.sh`](../scripts/nig/submit-separated.sh) | One long-running downloader fills a staging dir with `.ready` markers (bounded buffer). One long-running processor polls the staging dir and dispatches per-sample sub-jobs. Decoupled so the processor never blocks on the network. Design rationale: [`production-download-design.md`](production-download-design.md). |

Common scripts: [`scripts/nig/run-sample.sh`](../scripts/nig/run-sample.sh) (per-sample wrapper for the array model),
[`scripts/production-download.sh`](../scripts/production-download.sh) (download daemon, general),
[`scripts/nig/production-process.sh`](../scripts/nig/production-process.sh) (staging-dir processor).

## Per-genome recommended SLURM configs

For NIG kumamoto Type 2 nodes (128 cores, 512 GB RAM, 1.5 TB local NVMe).

### ChIP-seq / ATAC-seq / DNase-seq

| Genome | Threads | `--mem` | `-t` | Concurrent / node | Throughput | Source |
|---|---|---|---|---|---|---|
| sacCer3, ce11, dm6 | 4c | 16g | 02:00:00 | 32 | high | small-genome default |
| rn6, mm10 | 4-5c | 20g | 02:00:00 | 25-32 | tbd | extrapolated |
| hg38 | 5c | 20g | 02:00:00 | 25 | ~168 / hr | [`memory-benchmark.md`](memory-benchmark.md) |

### BS-seq

| Genome | Threads | `--mem` | `-t` | Concurrent / node | Throughput | Source |
|---|---|---|---|---|---|---|
| sacCer3, ce11, dm6 | 4c | 24g | 02:00:00 | 21 | — | small-genome (24g absorbs samtools-sort variability) |
| hg38 | 4c | 16g | 04:00:00 | 32 | ~10.4 / hr | [`memory-benchmark-bs.md`](memory-benchmark-bs.md). Alt: 8c/24g/02:30:00 if 4hr unacceptable. |

BS-seq memory ceiling is driven by `samtools sort -m 2G × threads` rather
than the aligner index, so peak RSS scales linearly with thread count
(opposite of ChIP-seq where bwa-mem2's hg38 index dominates).

## Container & reference layout on NIG

```
/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/
├── containers/
│   ├── pipeline-v2.sif       # ChIP-seq, v1.0.0
│   └── pipeline-v2-bs.sif    # BS-seq, v1.1.0
└── references/
    └── <genome>/             # fasta, indexes (bwa-mem2 + abismal), chrom.sizes
```

Built once via [`scripts/prepare-genomes.sh`](../scripts/prepare-genomes.sh)
and shared at group permission. Per-sample jobs read-only mount.

Per-host scripts deployed flat at `~/chip-atlas-v2/scripts/` (mix of
general + NIG-specific from the repo's `scripts/` and `scripts/nig/`).

## Output layout

```
/home/okishinya/chipatlas-v2/<genome>/<exp_prefix6>/<experiment_id>/
    <experiment>.bw                 # RPM-normalized coverage
    <experiment>.{05,10,20}.bb      # peaks at three q-value tiers (BigBed)
    <experiment>.{05,10,20}_peaks.narrowPeak
    <experiment>_fastp.json
    <experiment>.stats.tsv          # v1-compatible 15-column stats row
```

Three-level prefix (`<genome>/<exp_prefix6>/<experiment>/`) avoids any
single directory exceeding ~10K entries.

## Lessons learned in production

These came out of the 2026-04 to 2026-05 production of sacCer3 + ce11
(~28K samples). They're the things the next person should not have to
rediscover.

### Things to set correctly

- **fasterq-dump needs `--temp`** ([`scripts/fast-download.sh`](../scripts/fast-download.sh)).
  Without it, fasterq-dump writes internal scratch (`fasterq.tmp.<host>.<pid>`)
  in CWD, which on SLURM jobs without `--workdir` is `$HOME`. On killed
  jobs the trap can't reach them and they pile up. Fix: always pass
  `--temp $TMPDIR_DL`.
- **Export `TMPDIR` before invoking download scripts**
  ([`scripts/nig/run-sample.sh:66`](../scripts/nig/run-sample.sh)). Otherwise
  `${TMPDIR:-/tmp}` in `fast-download.sh` defaults to host `/tmp` (root FS),
  not the intended `/data1/tmp` NVMe. We had ~1.4 TB leak into root `/tmp`
  across nodes before we caught this (one node filled to 100%, wedging
  sshd).
- **`/data1` vs `/`.** The local NVMe (`/data1`) and the system root (`/`)
  are separate partitions. sshd writes session state to root, so a full
  `/data1` doesn't break SSH but a full `/tmp` (which lives under root)
  does.
- **Cleanup all per-job scratch.** Track WORK + TMPDIR_DL + fasterq temp
  dirs. A killed job that leaves any of them behind compounds across
  thousands of samples.

### Known bugs in `fast-download.sh` (still pending)

These caused ~388 / 20K sacCer3 + ~200 / 7.5K ce11 failures in production.
Recoverable on retry once patched:

1. **PAIRED metadata vs single-file reality.** ENA's `library_layout=PAIRED`
   doesn't guarantee `_1.fastq.gz` / `_2.fastq.gz` files — some records
   serve interleaved paired data in a single `<run>.fastq.gz`. Script
   trusts the layout flag and does `cat *_1.fastq.gz` → no match → fail.
2. **ENA-fallback leaves stale state.** Multi-file ENA downloads where
   one part fails return non-zero with the other part already on disk.
   The script then falls back to fasterq-dump which produces uncompressed
   `.fastq`, and the gzip step collides with the existing `.gz` from the
   partial ENA download.
3. **No retry on transient ENA HTTPS failure.** Single 5xx triggers
   immediate SRA fallback, which often can't recover because ENA and SRA
   indexes drift.

These three are responsible for the bulk of "failures" we saw — almost
none were truly withdrawn samples (verified by querying ENA: failed
accessions were still listed with valid FTP URLs).

### Operational nuances

- **Group vs user quota.** NIG charges your primary group's quota for
  files in `$HOME`. Our group's 953 GB hard limit got hit when fasterq
  orphans accumulated to 720 GB. Watch `lfs quota -hg <group>`.
- **SLURM-pinned cleanup as SSH workaround.** When sshd is wedged on a
  node (e.g. from disk-full), `sbatch --nodelist=<node>` can still run
  cleanup commands locally on it. We used this to recover at138.
- **Skip-on-output marker.** Per-sample wrappers check for
  `<experiment>.stats.tsv`. Always write that file *last* so an
  interrupted job is recognisable as incomplete and re-run cleanly.

## Status as of 2026-05-20

Production progress against the 400K-sample goal:

| Genome | Target | Done | % | Notes |
|---|---:|---:|---:|---|
| sacCer3 | 20,710 | 20,394 | 98.5% | 316 unfinished, mostly fast-download bugs (recoverable) |
| ce11 | 7,558 | 6,476 | 85.7% | 1,082 unfinished |
| dm6 | 17,913 | — | — | List ready; references not yet built on NIG |
| rn6 | 6,287 | — | — | Same |
| mm10 | tbd | — | — | Not started; references not built |
| hg38 | tbd | — | — | Same; BS-seq pilot blocked on abismal index |

The architecture has been validated end-to-end on the two smallest
genomes. ~93% of the 400K (concentrated in mm10 / hg38) is still ahead.

## Next steps

1. Patch the three known `fast-download.sh` bug classes — recovers most of
   the ~1.4K unfinished samples on resubmit.
2. Build dm6 + rn6 references on NIG, kick off those productions.
3. Build hg38 abismal index, run a small hg38 BS-seq pilot.
4. Start mm10 + hg38 ChIP-seq at scale.

## Pointers

- Pipeline scripts: [`scripts/`](../scripts/) (general) and [`scripts/nig/`](../scripts/nig/) (NIG-specific).
  See [`scripts/README.md`](../scripts/README.md) and [`scripts/nig/README.md`](../scripts/nig/README.md).
- Container Dockerfiles: [`containers/`](../containers/).
- All other docs: [`README.md`](README.md).
