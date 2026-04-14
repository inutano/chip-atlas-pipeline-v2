#!/usr/bin/env python3
"""
Compute colocalization scores between experiments in the same cell type class.

For each pair of experiments in the same cell type class, compares their peak
scores across genomic bins. Assigns H/M/L categories based on Z-scores of
MACS peak signals, then scores the 9 pairwise combinations.

v1 algorithm:
  1. For each experiment, get peak scores at each genomic position
  2. Fit scores to Gaussian, compute Z-scores
  3. Classify: H (Z > 0.5), M (-0.5 to 0.5), L (Z < -0.5)
  4. Score pairs: H-H=9, H-M/M-H=6, M-M=4, H-L/L-H=3, M-L/L-M=2, L-L=1

Usage:
  python3 compute-colocalization.py <peaks_dir> <metadata.tsv> <genome> <output.json>
"""

import os
import sys
import json
import argparse
import numpy as np
from collections import defaultdict


def load_peaks(filepath):
    """Load narrowPeak file, return dict of chrom:start → score."""
    peaks = {}
    with open(filepath) as f:
        for line in f:
            fields = line.strip().split("\t")
            if len(fields) < 5:
                continue
            chrom = fields[0]
            start = int(fields[1])
            end = int(fields[2])
            score = float(fields[4])
            mid = (start + end) // 2
            # Bin to 1kb resolution
            bin_key = f"{chrom}:{mid // 1000}"
            if bin_key not in peaks or score > peaks[bin_key]:
                peaks[bin_key] = score
        return peaks


def classify_scores(scores):
    """Classify scores into H/M/L based on Z-scores."""
    if len(scores) == 0:
        return {}
    arr = np.array(list(scores.values()))
    mean = np.mean(arr)
    std = np.std(arr)
    if std == 0:
        return {k: "M" for k in scores}
    result = {}
    for k, v in scores.items():
        z = (v - mean) / std
        if z > 0.5:
            result[k] = "H"
        elif z < -0.5:
            result[k] = "L"
        else:
            result[k] = "M"
    return result


def coloc_score(cat_a, cat_b):
    """Score a pair of H/M/L categories."""
    pair = tuple(sorted([cat_a, cat_b]))
    scores = {
        ("H", "H"): 9,
        ("H", "M"): 6,
        ("M", "M"): 4,
        ("H", "L"): 3,
        ("L", "M"): 2,
        ("L", "L"): 1,
    }
    return scores.get(pair, 0)


def compute_pairwise(exp_a_classes, exp_b_classes):
    """Compute colocalization score between two classified experiments."""
    common_bins = set(exp_a_classes.keys()) & set(exp_b_classes.keys())
    if not common_bins:
        return 0, 0, {}

    total_score = 0
    pair_counts = defaultdict(int)
    for bin_key in common_bins:
        ca = exp_a_classes[bin_key]
        cb = exp_b_classes[bin_key]
        total_score += coloc_score(ca, cb)
        pair = "-".join(sorted([ca, cb]))
        pair_counts[pair] += 1

    avg_score = total_score / len(common_bins) if common_bins else 0
    return avg_score, len(common_bins), dict(pair_counts)


def load_metadata(filepath, genome):
    """Load metadata, return dict of accession → info."""
    meta = {}
    with open(filepath) as f:
        header = f.readline().strip().split("\t")
        for line in f:
            fields = line.strip().split("\t")
            if len(fields) < 6:
                continue
            row = dict(zip(header, fields))
            acc = row.get("accession", fields[0])
            g = row.get("genome", fields[1])
            if g != genome:
                continue
            meta[acc] = {
                "experiment_type": row.get("experiment_type", fields[2]),
                "antigen": row.get("antigen", fields[3]),
                "cell_type": row.get("cell_type", fields[4]),
                "cell_type_class": row.get("cell_type_class", fields[5]),
            }
    return meta


def main():
    parser = argparse.ArgumentParser(description="Compute colocalization scores")
    parser.add_argument("peaks_dir", help="Directory with narrowPeak files (per experiment)")
    parser.add_argument("metadata", help="Metadata TSV file")
    parser.add_argument("genome", help="Genome name")
    parser.add_argument("output_dir", help="Output directory for JSON files")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    meta = load_metadata(args.metadata, args.genome)

    # Find all peak files
    peak_files = {}
    for entry in os.listdir(args.peaks_dir):
        if os.path.isdir(os.path.join(args.peaks_dir, entry)):
            acc = entry
            peak_file = os.path.join(args.peaks_dir, acc, f"{acc}.05_peaks.narrowPeak")
            if os.path.exists(peak_file) and acc in meta:
                peak_files[acc] = peak_file

    print(f"Found {len(peak_files)} experiments with peaks and metadata")

    # Group by cell_type_class
    groups = defaultdict(list)
    for acc in peak_files:
        cell_class = meta[acc]["cell_type_class"]
        groups[cell_class].append(acc)

    # Load and classify all peaks
    print("Loading and classifying peaks...")
    classified = {}
    for acc, filepath in peak_files.items():
        peaks = load_peaks(filepath)
        classified[acc] = classify_scores(peaks)
        print(f"  {acc}: {len(peaks)} peaks → {sum(1 for v in classified[acc].values() if v=='H')}H/{sum(1 for v in classified[acc].values() if v=='M')}M/{sum(1 for v in classified[acc].values() if v=='L')}L")

    # Compute pairwise scores per cell class
    print("Computing pairwise colocalization...")
    for cell_class, accs in groups.items():
        if len(accs) < 2:
            continue

        print(f"  {cell_class}: {len(accs)} experiments")

        # For each experiment, compute scores against all others
        for query_acc in accs:
            partners = []
            for target_acc in accs:
                if target_acc == query_acc:
                    continue
                score, n_bins, pair_counts = compute_pairwise(
                    classified[query_acc], classified[target_acc]
                )
                partners.append({
                    "experiment_id": target_acc,
                    "antigen": meta[target_acc]["antigen"],
                    "cell_type": meta[target_acc]["cell_type"],
                    "coloc_score": round(score, 2),
                    "shared_bins": n_bins,
                    "pair_counts": pair_counts,
                })

            partners.sort(key=lambda p: p["coloc_score"], reverse=True)

            result = {
                "query_experiment": query_acc,
                "query_antigen": meta[query_acc]["antigen"],
                "query_cell_type": meta[query_acc]["cell_type"],
                "cell_type_class": cell_class,
                "genome": args.genome,
                "n_partners": len(partners),
                "partners": partners,
            }

            outpath = os.path.join(args.output_dir, f"{query_acc}.json")
            with open(outpath, "w") as f:
                json.dump(result, f)

    # Summary
    total = sum(1 for f in os.listdir(args.output_dir) if f.endswith(".json"))
    print(f"\nGenerated {total} colocalization JSON files in {args.output_dir}/")


if __name__ == "__main__":
    main()
