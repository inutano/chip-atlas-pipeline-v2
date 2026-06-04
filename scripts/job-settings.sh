#!/usr/bin/env bash
#
# job-settings.sh — per-(pipeline,genome) SLURM resource lookup. Pure; sourceable.
# Returns "<cpus> <mem> <time>" so the processor can submit one cgroup-capped
# SLURM job per experiment (NEVER --mem=0). Concurrency is then a SLURM scheduling
# result: min(128/cpus, 512/mem) per 128-core/512GB node.
#
# Values are the current plan settings; the 2026-06 memory benchmark refines them.
# Drivers: ChIP peak = bwa-mem2 index (genome-fixed); BS peak = max(samtools sort
# 2G*threads, dnmtools hypermr CpG-table load, genome-fixed). See docs/production-plan.md.

# job_settings <pipeline> <genome> -> "<cpus> <mem> <time>"  (empty if unknown)
job_settings() {
  local pipeline="$1" genome="$2"
  case "$pipeline" in
    chipseq)
      case "$genome" in
        sacCer3|ce11|dm6|TAIR10) echo "4 16g 0-02:00:00" ;;
        rn6|mm10|hg38)           echo "5 20g 0-02:00:00" ;;
        *) echo "" ;;
      esac ;;
    bsseq)
      case "$genome" in
        sacCer3|ce11|dm6|TAIR10) echo "4 16g 0-02:00:00" ;;
        rn6|mm10|hg38)           echo "4 20g 0-04:00:00" ;;
        *) echo "" ;;
      esac ;;
    *) echo "" ;;
  esac
}
