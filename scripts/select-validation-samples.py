#!/usr/bin/env python3
"""
Select a representative subset of ChIP-Atlas experiments for v2 pipeline validation.

Reads experimentList.tab and selects samples stratified by:
  - Genome (6 current assemblies)
  - Experiment type (6 types)
  - Read count tier (low/medium/high)

Within each stratum, picks the 3 newest experiments (by accession number).

Usage:
  python select-validation-samples.py experimentList.tab -o data/validation-samples.tsv
"""

import argparse
import csv
import re
import sys
from collections import defaultdict

TARGET_GENOMES = {"hg38", "mm10", "rn6", "dm6", "ce11", "sacCer3"}

TARGET_TYPES = {
    "Histone",
    "TFs and others",
    "ATAC-Seq",
    "DNase-seq",
    "RNA polymerase",
    "Bisulfite-Seq",
}

SAMPLES_PER_STRATUM = 3

HEADER = [
    "accession",
    "genome",
    "experiment_type",
    "antigen",
    "cell_type",
    "cell_type_class",
    "title",
    "num_reads",
    "mapping_rate",
    "dup_rate",
    "num_peaks",
    "read_tier",
]


def parse_accession_number(accession: str) -> int:
    """Extract numeric part from accession ID (e.g., SRX12345 -> 12345)."""
    m = re.search(r"(\d+)$", accession)
    return int(m.group(1)) if m else 0


def classify_read_tier(num_reads: int) -> str:
    if num_reads < 10_000_000:
        return "low"
    elif num_reads <= 50_000_000:
        return "medium"
    else:
        return "high"


def parse_stats(stats_field: str):
    """Parse column 8: 'num_reads,mapping_rate,dup_rate,num_peaks'."""
    parts = stats_field.split(",")
    if len(parts) < 4:
        return None
    try:
        return {
            "num_reads": int(parts[0]),
            "mapping_rate": float(parts[1]),
            "dup_rate": float(parts[2]),
            "num_peaks": int(parts[3]),
        }
    except (ValueError, IndexError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="Path to experimentList.tab")
    parser.add_argument(
        "-o", "--output", default="data/validation-samples.tsv", help="Output TSV path"
    )
    parser.add_argument(
        "-n",
        "--samples-per-stratum",
        type=int,
        default=SAMPLES_PER_STRATUM,
        help=f"Samples per stratum (default: {SAMPLES_PER_STRATUM})",
    )
    args = parser.parse_args()

    # Read and filter
    strata = defaultdict(list)
    skipped = defaultdict(int)

    with open(args.input, "r", encoding="utf-8") as f:
        reader = csv.reader(f, delimiter="\t")
        for row in reader:
            if len(row) < 9:
                skipped["short_row"] += 1
                continue

            accession = row[0]
            genome = row[1]
            exp_type = row[2]

            # Filter genome
            if genome not in TARGET_GENOMES:
                skipped["legacy_genome"] += 1
                continue

            # Filter experiment type
            if exp_type not in TARGET_TYPES:
                skipped["excluded_type"] += 1
                continue

            # Parse stats
            stats = parse_stats(row[7])
            if stats is None:
                skipped["bad_stats"] += 1
                continue

            # Skip zero-read or zero-peak experiments
            if stats["num_reads"] == 0:
                skipped["zero_reads"] += 1
                continue

            read_tier = classify_read_tier(stats["num_reads"])
            key = (genome, exp_type, read_tier)

            strata[key].append(
                {
                    "accession": accession,
                    "genome": genome,
                    "experiment_type": exp_type,
                    "antigen": row[3],
                    "cell_type": row[4],
                    "cell_type_class": row[5],
                    "title": row[8] if len(row) > 8 else "",
                    "num_reads": stats["num_reads"],
                    "mapping_rate": stats["mapping_rate"],
                    "dup_rate": stats["dup_rate"],
                    "num_peaks": stats["num_peaks"],
                    "read_tier": read_tier,
                    "_acc_num": parse_accession_number(accession),
                }
            )

    # Select top N newest per stratum
    selected = []
    for key in sorted(strata.keys()):
        candidates = sorted(strata[key], key=lambda x: x["_acc_num"], reverse=True)
        picked = candidates[: args.samples_per_stratum]
        selected.extend(picked)

    # Write output
    with open(args.output, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f, fieldnames=HEADER, delimiter="\t", extrasaction="ignore"
        )
        writer.writeheader()
        writer.writerows(selected)

    # Summary
    print(f"Total samples selected: {len(selected)}")
    print(f"\nPer genome:")
    genome_counts = defaultdict(int)
    for s in selected:
        genome_counts[s["genome"]] += 1
    for g in sorted(genome_counts):
        print(f"  {g}: {genome_counts[g]}")

    print(f"\nPer experiment type:")
    type_counts = defaultdict(int)
    for s in selected:
        type_counts[s["experiment_type"]] += 1
    for t in sorted(type_counts):
        print(f"  {t}: {type_counts[t]}")

    print(f"\nPer read tier:")
    tier_counts = defaultdict(int)
    for s in selected:
        tier_counts[s["read_tier"]] += 1
    for t in ["low", "medium", "high"]:
        print(f"  {t}: {tier_counts.get(t, 0)}")

    print(f"\nStrata with no candidates:")
    for genome in sorted(TARGET_GENOMES):
        for exp_type in sorted(TARGET_TYPES):
            for tier in ["low", "medium", "high"]:
                key = (genome, exp_type, tier)
                if key not in strata:
                    print(f"  {genome} / {exp_type} / {tier}")

    print(f"\nSkipped rows: {dict(skipped)}")
    print(f"\nOutput written to: {args.output}")


if __name__ == "__main__":
    main()
