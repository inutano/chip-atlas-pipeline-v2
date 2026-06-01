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

# classify_outcome <rc> <stats_exists 0|1> <attempts> <max_retries>
#   -> done | datafail | retry | infrafail
classify_outcome() {
  local rc="$1" stats="$2" attempts="$3" max="$4"
  if [ "$rc" -eq 0 ] && [ "$stats" -eq 1 ]; then
    echo done
  elif [ "$rc" -eq "$DATA_FAILURE_RC" ]; then
    echo datafail
  elif [ "$attempts" -lt "$max" ]; then
    echo retry
  else
    echo infrafail
  fi
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

# apply_outcome <staging_dir> <done|datafail|retry|infrafail>
# Transitions the staging-dir markers and manages FASTQs + the attempt counter.
# Assumes the sample currently holds a .running marker.
#   done      -> .done; drop FASTQs + counter (processed successfully)
#   datafail  -> .fail; drop FASTQs + counter (deterministic; retry is futile)
#   retry     -> .ready; bump counter; KEEP FASTQs (will be reprocessed)
#   infrafail -> .fail; KEEP FASTQs (retries exhausted; allow manual rerun)
apply_outcome() {
  local d="$1" outcome="$2"
  rm -f "$d/.running"
  case "$outcome" in
    done)
      rm -f "$d"/*.fastq.gz "$d"/*.fastq "$d/.attempts"
      touch "$d/.done"
      ;;
    datafail)
      rm -f "$d"/*.fastq.gz "$d"/*.fastq "$d/.attempts"
      touch "$d/.fail"
      ;;
    retry)
      local n
      n="$(read_attempts "$d")"
      echo $((n + 1)) > "$d/.attempts"
      touch "$d/.ready"
      ;;
    infrafail)
      rm -f "$d/.attempts"
      touch "$d/.fail"
      ;;
  esac
}
