#!/usr/bin/env bash
#
# failure-classify.sh — pure decision functions shared by the pipeline scripts
# and the production wrapper. No side effects; safe to source.
#
# Purpose: separate DETERMINISTIC "bad data" failures (re-running won't help,
# so mark terminal) from TRANSIENT/infra failures (OOM, NODE_FAIL, truncated
# download — retry a few times before giving up).
#
# Exit-code contract between the pipeline scripts and production-process.sh:
#   0   -> success (stats.tsv written)
#   42  -> deterministic data failure (e.g. MACS3 can't call peaks on sparse
#          data, or a BS sample with zero covered CpGs). Terminal; not retried.
#   any other non-zero -> transient/unknown. Retried up to a cap.
DATA_FAILURE_RC=42

# classify_outcome <rc> <stats_exists 0|1> <attempts> <max_retries> [oom 0|1] [bumped 0|1]
#   -> done | datafail | oomretry | retry | infrafail
# oom (default 0) is the caller's is_oom verdict; bumped (default 0) is whether the
# job already ran at the doubled cap (.mem2x present). An OOM that hasn't been bumped
# yet becomes `oomretry` (resubmit once at 2x mem); a second OOM at 2x gives up.
classify_outcome() {
  local rc="$1" stats="$2" attempts="$3" max="$4" oom="${5:-0}" bumped="${6:-0}"
  if [ "$rc" -eq 0 ] && [ "$stats" -eq 1 ]; then
    echo done
  elif [ "$rc" -eq "$DATA_FAILURE_RC" ]; then
    echo datafail
  elif [ "$oom" -eq 1 ]; then
    if [ "$bumped" -eq 0 ]; then echo oomretry; else echo infrafail; fi
  elif [ "$attempts" -lt "$max" ]; then
    echo retry
  else
    echo infrafail
  fi
}

# is_oom <rc> <cgroup_oom_kill_count> -> 1|0
# An OOM kill shows as rc 137 (128+SIGKILL) and/or a nonzero memory.events oom_kill.
is_oom() {
  local rc="$1" oom_kill="${2:-0}"
  if [ "$rc" -eq 137 ] || [ "${oom_kill:-0}" -gt 0 ]; then echo 1; else echo 0; fi
}

# double_mem <Ng> -> <2N g>   (the 2x cap for an oomretry resubmit)
double_mem() {
  local n="${1%[gG]}"
  echo "$((n * 2))g"
}

# classify_orphan <sacct_state> <attempts> <max_retries> [bumped 0|1]
#   -> fail | oomretry | retry
# Decides what to do with a job that vanished from the queue without writing a
# terminal marker (SLURM killed it mid-run). The first-pass strategy runs every
# sample at a short walltime, so a TIMEOUT is expected and re-running at the same
# limit is futile -> send it to the .fail retry bucket. An OOM that also killed the
# wrapper gets the same one-shot 2x bump as a normal oomretry. Genuinely transient
# losses (NODE_FAIL/PREEMPTED/unknown) retry up to the cap; CANCELLED stays failed.
classify_orphan() {
  local state="$1" attempts="$2" max="$3" bumped="${4:-0}"
  case "$state" in
    TIMEOUT)        echo fail ;;
    OUT_OF_MEMORY|OOM)
      if [ "$bumped" -eq 0 ]; then echo oomretry; else echo fail; fi ;;
    CANCELLED*)     echo fail ;;
    *)  if [ "$attempts" -lt "$max" ]; then echo retry; else echo fail; fi ;;
  esac
}

# classify_macs3_failure <macs3_rc> <peaks_xls_exists 0|1>
#   -> ok | data | infra
# 0 peaks is a valid result (low-signal sample) as long as MACS3 produced its
# _peaks.xls. A non-zero exit with no output is a real failure: a signal/OOM
# kill (rc > 128) is transient infra; a clean non-zero is deterministic data.
classify_macs3_failure() {
  local rc="$1" xls="$2"
  if [ "$rc" -eq 0 ] || [ "$xls" -eq 1 ]; then
    echo ok
  elif [ "$rc" -gt 128 ]; then
    echo infra
  else
    echo data
  fi
}

# classify_bsseq_failure <bigwig_rc> <methyl_bw_ok 0|1> <cover_bw_ok 0|1> <covered_cpgs>
#   -> ok | data | infra
# BigWig is the essential BS-seq output. If it's present and valid, ok. If it's
# missing because the sample had zero covered CpGs, that's deterministic bad
# data. Otherwise (data present but BigWig tool failed) it's transient infra.
classify_bsseq_failure() {
  local bigwig_rc="$1" methyl_ok="$2" cover_ok="$3" covered_cpgs="$4"
  if [ "$bigwig_rc" -eq 0 ] && [ "$methyl_ok" -eq 1 ] && [ "$cover_ok" -eq 1 ]; then
    echo ok
  elif [ "$covered_cpgs" -eq 0 ]; then
    echo data
  else
    echo infra
  fi
}

# ----------------------------------------------------------------------
# Stateful helpers used by production-process.sh to act on an outcome.
# ----------------------------------------------------------------------

# read_attempts <staging_dir> -> integer (0 if no counter yet)
read_attempts() {
  local d="$1"
  if [ -f "$d/.attempts" ]; then
    cat "$d/.attempts"
  else
    echo 0
  fi
}

# apply_outcome <staging_dir> <done|datafail|oomretry|retry|infrafail>
# Transitions the staging-dir markers and manages FASTQs + the attempt counter.
# Assumes the sample currently holds a .running marker.
#   done      -> .done; drop FASTQs + counter + mem-bump (processed successfully)
#   datafail  -> .fail; drop FASTQs + counter + mem-bump (deterministic; futile)
#   oomretry  -> .ready; set .mem2x bump; KEEP FASTQs; do NOT bump .attempts
#               (coordinator resubmits this experiment once at 2x mem)
#   retry     -> .ready; bump counter; KEEP FASTQs (will be reprocessed)
#   infrafail -> .fail; drop counter + mem-bump; KEEP FASTQs (manual rerun)
apply_outcome() {
  local d="$1" outcome="$2"
  rm -f "$d/.running"
  case "$outcome" in
    done)
      rm -f "$d"/*.fastq.gz "$d"/*.fastq "$d/.attempts" "$d/.mem2x"
      touch "$d/.done"
      ;;
    datafail)
      rm -f "$d"/*.fastq.gz "$d"/*.fastq "$d/.attempts" "$d/.mem2x"
      touch "$d/.fail"
      ;;
    oomretry)
      touch "$d/.mem2x"
      touch "$d/.ready"
      ;;
    retry)
      local n
      n="$(read_attempts "$d")"
      echo $((n + 1)) > "$d/.attempts"
      touch "$d/.ready"
      ;;
    infrafail)
      rm -f "$d/.attempts" "$d/.mem2x"
      touch "$d/.fail"
      ;;
  esac
}
