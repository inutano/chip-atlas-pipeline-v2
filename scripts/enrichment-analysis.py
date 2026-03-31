#!/usr/bin/env python3
"""
Enrichment analysis (In Silico ChIP): test if user-provided regions
are enriched for peaks from specific experiments.

Uses a compiled BED file containing all peaks with experiment annotation.
Runs bedtools intersect, then Fisher's exact test with BH correction.

Usage:
  python3 enrichment-analysis.py <query.bed> <compiled_peaks.bed> <metadata.tsv> <genome> -o result.json

Output JSON contains ranked experiments by enrichment significance.
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict

# Try scipy for Fisher's test, fall back to simple approximation
try:
    from scipy.stats import fisher_exact
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False


def fisher_test_simple(a, b, c, d):
    """Simple Fisher's exact test approximation when scipy unavailable."""
    # Use log odds ratio as a proxy
    import math
    if b == 0 or c == 0:
        return 0, 1.0
    odds_ratio = (a * d) / (b * c) if b * c > 0 else float('inf')
    # Very rough p-value approximation — use scipy for real analysis
    n = a + b + c + d
    if n == 0:
        return 1.0, 1.0
    expected_a = (a + b) * (a + c) / n
    if expected_a == 0:
        return odds_ratio, 1.0
    chi2 = (a - expected_a) ** 2 / expected_a
    # Approximate p-value from chi2 with 1 df
    p = math.exp(-chi2 / 2)
    return odds_ratio, p


def bh_correction(pvalues):
    """Benjamini-Hochberg FDR correction."""
    n = len(pvalues)
    if n == 0:
        return []
    indexed = sorted(enumerate(pvalues), key=lambda x: x[1])
    corrected = [0] * n
    for rank, (idx, p) in enumerate(indexed, 1):
        corrected[idx] = min(p * n / rank, 1.0)
    # Ensure monotonicity
    for i in range(n - 2, -1, -1):
        sorted_idx = indexed[i][0]
        next_idx = indexed[i + 1][0]
        corrected[sorted_idx] = min(corrected[sorted_idx], corrected[next_idx])
    return corrected


def run_intersect(query_bed, compiled_bed):
    """Run bedtools intersect, return overlaps."""
    result = subprocess.run(
        ["bedtools", "intersect", "-a", query_bed, "-b", compiled_bed, "-wa", "-wb"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        # Try with docker
        query_dir = os.path.dirname(os.path.abspath(query_bed))
        peaks_dir = os.path.dirname(os.path.abspath(compiled_bed))
        result = subprocess.run(
            ["docker", "run", "--rm",
             "-v", f"{query_dir}:/query",
             "-v", f"{peaks_dir}:/peaks",
             "quay.io/biocontainers/bedtools:2.31.1--hf5e1c6e_2",
             "bedtools", "intersect",
             "-a", f"/query/{os.path.basename(query_bed)}",
             "-b", f"/peaks/{os.path.basename(compiled_bed)}",
             "-wa", "-wb"],
            capture_output=True, text=True
        )
    return result.stdout


def count_regions(bed_file):
    """Count regions in a BED file."""
    with open(bed_file) as f:
        return sum(1 for line in f if line.strip() and not line.startswith("#"))


def count_peaks_per_experiment(compiled_bed):
    """Count total peaks per experiment in the compiled BED."""
    counts = Counter()
    with open(compiled_bed) as f:
        for line in f:
            if not line.strip():
                continue
            fields = line.strip().split("\t")
            exp_id = fields[3].split("|")[0]
            counts[exp_id] += 1
    return counts


def main():
    parser = argparse.ArgumentParser(description="Enrichment analysis (In Silico ChIP)")
    parser.add_argument("query", help="Query BED file (user regions)")
    parser.add_argument("peaks", help="Compiled peaks BED file")
    parser.add_argument("metadata", help="Metadata TSV file")
    parser.add_argument("genome", help="Genome name")
    parser.add_argument("-o", "--output", default="enrichment_result.json", help="Output JSON")
    args = parser.parse_args()

    print(f"Query: {args.query}")
    print(f"Peaks: {args.peaks}")

    # Count query regions
    n_query = count_regions(args.query)
    print(f"Query regions: {n_query}")

    # Count total peaks per experiment
    print("Counting peaks per experiment...")
    exp_peak_counts = count_peaks_per_experiment(args.peaks)
    total_peaks = sum(exp_peak_counts.values())
    n_experiments = len(exp_peak_counts)
    print(f"Total experiments: {n_experiments}, total peaks: {total_peaks:,}")

    # Run intersection
    print("Running bedtools intersect...")
    intersect_output = run_intersect(args.query, args.peaks)

    # Count overlaps per experiment
    overlap_counts = Counter()  # experiment → n_query_regions that overlap
    overlap_details = defaultdict(set)  # experiment → set of query regions that overlap

    for line in intersect_output.strip().split("\n"):
        if not line:
            continue
        fields = line.split("\t")
        query_region = f"{fields[0]}:{fields[1]}-{fields[2]}"
        annotation = fields[6]  # experiment_id|antigen|cell_type
        exp_id = annotation.split("|")[0]
        overlap_details[exp_id].add(query_region)

    for exp_id, regions in overlap_details.items():
        overlap_counts[exp_id] = len(regions)

    print(f"Experiments with overlaps: {len(overlap_counts)}")

    # Load metadata
    meta = {}
    with open(args.metadata) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            acc = row.get("accession", "")
            if row.get("genome") == args.genome:
                meta[acc] = {
                    "experiment_type": row.get("experiment_type", ""),
                    "antigen": row.get("antigen", ""),
                    "cell_type": row.get("cell_type", ""),
                }

    # Fisher's exact test for each experiment
    # 2x2 table:
    #                overlap    no_overlap
    # query regions:    a           b        = n_query
    # background:       c           d        = total_peaks - n_exp_peaks (approx)
    #
    # a = n_query_regions overlapping this experiment's peaks
    # b = n_query - a
    # c = n_experiment_peaks (total peaks for this experiment)
    # d = genome_size_bins - c (approximate)

    print("Computing Fisher's exact test...")
    genome_bins = 100000  # approximate number of 1kb bins in genome

    results = []
    pvalues = []

    for exp_id in exp_peak_counts:
        a = overlap_counts.get(exp_id, 0)
        b = n_query - a
        c = exp_peak_counts[exp_id]
        d = genome_bins - c

        if a == 0:
            odds_ratio, pvalue = 0, 1.0
        elif HAS_SCIPY:
            odds_ratio, pvalue = fisher_exact([[a, b], [c, d]], alternative="greater")
        else:
            odds_ratio, pvalue = fisher_test_simple(a, b, c, d)

        fold = (a / n_query) / (c / genome_bins) if c > 0 and n_query > 0 else 0

        exp_meta = meta.get(exp_id, {})
        results.append({
            "experiment_id": exp_id,
            "antigen": exp_meta.get("antigen", ""),
            "cell_type": exp_meta.get("cell_type", ""),
            "experiment_type": exp_meta.get("experiment_type", ""),
            "n_overlap": a,
            "n_query": n_query,
            "n_peaks": c,
            "fold_enrichment": round(fold, 2),
            "p_value": pvalue,
        })
        pvalues.append(pvalue)

    # BH correction
    qvalues = bh_correction(pvalues)
    for i, r in enumerate(results):
        r["q_value"] = qvalues[i]

    # Sort by q-value
    results.sort(key=lambda r: r["q_value"])

    # Filter significant
    significant = [r for r in results if r["q_value"] < 0.05]

    output = {
        "query_file": os.path.basename(args.query),
        "genome": args.genome,
        "n_query_regions": n_query,
        "n_experiments_tested": n_experiments,
        "n_significant": len(significant),
        "results": results,
    }

    with open(args.output, "w") as f:
        json.dump(output, f, indent=2)

    print(f"\nResults: {len(significant)} significant (q < 0.05) out of {n_experiments}")
    print(f"Top 5:")
    for r in results[:5]:
        print(f"  {r['experiment_id']} ({r['antigen']}, {r['cell_type']}): "
              f"overlap={r['n_overlap']}/{n_query}, fold={r['fold_enrichment']}, q={r['q_value']:.2e}")
    print(f"\nSaved to: {args.output}")


if __name__ == "__main__":
    main()
