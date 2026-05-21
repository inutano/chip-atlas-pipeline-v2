# ChIP-Atlas Pipeline v2 — Documentation

This directory holds the project's design record, benchmarks, operational
notes, and user tutorials. The docs are organized as a four-stage narrative:

1. **Where we came from** — survey of the v1 pipeline being replaced
2. **What we planned** — the original v2 plan
3. **What we learned** — investigations and benchmarks
4. **What we built** — the final v2 architecture in production today

If you only read one doc, read [`v2-final-architecture.md`](v2-final-architecture.md):
that's the current state. The other docs explain how we got there.

---

## 1. Where we came from

| Doc | What it covers |
|---|---|
| [`v1-pipeline-survey.md`](v1-pipeline-survey.md) | Architecture of the existing ChIP-Atlas v1 pipeline (Bowtie2 2.2.2 / SAMtools 0.1.19 / MACS2 2.1.0, SGE-orchestrated shell scripts). Establishes the baseline and motivates the rewrite. |

## 2. What we planned

| Doc | What it covers |
|---|---|
| [`v2-initial-plan.md`](v2-initial-plan.md) (en) / [`.ja.md`](v2-initial-plan.ja.md) (ja) | Original v2 plan: tool selection (bwa-mem2, MACS3, DNMTools), CWL workflow design, validation matrix, production deployment plan. **Historical** — the actual implementation diverged in places (CWL approach was abandoned; see investigations and final architecture). |

## 3. What we learned (investigations & benchmarks)

### Pipeline design investigations

| Doc | What it covers |
|---|---|
| [`bisulfite-seq-investigation.md`](bisulfite-seq-investigation.md) | Investigation that selected DNMTools (abismal aligner + downstream tools) over alternatives for the BS-seq sub-pipeline. |
| [`secondary-analysis-plan.md`](secondary-analysis-plan.md) | Design for the three secondary analyses (target genes, colocalization, enrichment). Implementation lives in `scripts/secondary-analysis/`. |
| [`production-download-design.md`](production-download-design.md) | Rationale for splitting download from processing into separate SLURM jobs (the "separated dl/proc" model). |

### Benchmarks

| Doc | What it covers |
|---|---|
| [`benchmark-results.md`](benchmark-results.md) (en) / [`.ja.md`](benchmark-results.ja.md) (ja) | Original ChIP-seq pipeline benchmark — compared Option A (sequential) vs Option B (piped) variants, including a Parabricks GPU variant. Selected "Option B Fast" as production. |
| [`memory-benchmark.md`](memory-benchmark.md) | ChIP-seq pipeline memory characterization for hg38. Recommends piped 5c / `--mem=20g` for NIG kumamoto (~168 samples/hr/node). |
| [`memory-benchmark-bs.md`](memory-benchmark-bs.md) | BS-seq pipeline memory characterization for hg38. Recommends 4c / `--mem=16g` / `-t 04:00:00` (~10.4 samples/hr/node). Different driver from ChIP-seq (samtools sort, not the aligner index). |

### Real-world lessons

| Doc | What it covers |
|---|---|
| [`production-lessons-ce11.md`](production-lessons-ce11.md) | Retrospective from the first production-scale run (2,693 ce11 samples on 6 kumamoto nodes). Disk-quota dynamics, intermediate-file lifecycle, and download throttling lessons. |

## 4. What we built

| Doc | What it covers |
|---|---|
| [`v2-final-architecture.md`](v2-final-architecture.md) | Current-state architecture summary: container/reference layout, the two production models (array vs separated dl/proc), per-genome recommended configs, and known operational gotchas. Cross-references the deeper docs above. |

## Operations and how-to

| Doc | What it covers |
|---|---|
| [`cluster-setup-guide.md`](cluster-setup-guide.md) | How to reproduce the v2 setup on a SLURM cluster (containers, references, scratch dirs). |
| [`tutorial-chipseq.md`](tutorial-chipseq.md) | Step-by-step tutorial: pull container, prepare reference, run ChIP-seq pipeline on one sample. |
| [`tutorial-bsseq.md`](tutorial-bsseq.md) | Same for BS-seq. |

## Assets

| Path | Contents |
|---|---|
| [`diagrams/`](diagrams/) | Pipeline architecture diagrams referenced from `benchmark-results.md` (Option A / Option B variants). |

---

## Reading paths by reader

- **New contributor:** README (this file) → `v2-final-architecture.md` → `tutorial-chipseq.md`
- **Replicating on another cluster:** `v2-final-architecture.md` → `cluster-setup-guide.md` → tutorials
- **Evaluating design decisions:** `v1-pipeline-survey.md` → `v2-initial-plan.md` → investigations → benchmarks → `v2-final-architecture.md`
- **Operating in production:** `v2-final-architecture.md` → `production-lessons-ce11.md` → memory benchmarks → `scripts/nig/README.md`
