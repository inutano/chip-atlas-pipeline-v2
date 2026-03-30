#!/usr/bin/env python3
"""
Generate target genes JSON files from peak-TSS overlap TSV files.
One JSON per experiment, suitable for the target-genes.html template.

Usage:
  # Single file
  python3 generate-target-genes-json.py overlap.tsv metadata.tsv output_dir/

  # All files in a directory
  python3 generate-target-genes-json.py --dir overlaps/ metadata.tsv output_dir/
"""

import csv
import json
import sys
import os
import argparse
from collections import defaultdict
from pathlib import Path


def process_overlap_file(filepath, metadata):
    """Process one overlap TSV into a JSON structure."""
    genes_by_window = defaultdict(lambda: defaultdict(list))
    exp_id = None

    with open(filepath) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            exp_id = row["experiment_id"]
            window_kb = int(row["window_kb"])
            genes_by_window[window_kb][row["gene_symbol"]].append({
                "score": float(row["peak_score"]) if row["peak_score"] else 0,
                "distance": int(row["tss_distance"]) if row["tss_distance"] else 0,
            })

    if not exp_id:
        return None

    meta = metadata.get(exp_id, {})
    result = {
        "experiment_id": exp_id,
        "genome": meta.get("genome", ""),
        "experiment_type": meta.get("experiment_type", ""),
        "antigen": meta.get("antigen", ""),
        "cell_type": meta.get("cell_type", ""),
    }

    # Generate per-window gene lists
    for window_kb in [1, 5, 10]:
        genes = genes_by_window.get(window_kb, {})
        gene_list = []
        for symbol, peaks in genes.items():
            scores = [p["score"] for p in peaks]
            distances = [p["distance"] for p in peaks]
            gene_list.append({
                "symbol": symbol,
                "n_peaks": len(peaks),
                "avg_score": round(sum(scores) / len(scores), 1),
                "nearest_tss_distance": min(distances, key=abs),
            })
        gene_list.sort(key=lambda g: g["avg_score"], reverse=True)

        result[f"window_{window_kb}kb"] = {
            "total_genes": len(gene_list),
            "genes": gene_list,
        }

    return result


def load_metadata(filepath):
    """Load metadata from validation-samples.tsv."""
    meta = {}
    with open(filepath) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            meta[row["accession"]] = {
                "genome": row["genome"],
                "experiment_type": row["experiment_type"],
                "antigen": row["antigen"],
                "cell_type": row["cell_type"],
            }
    return meta


def main():
    parser = argparse.ArgumentParser(description="Generate target genes JSON")
    parser.add_argument("metadata", help="Metadata TSV file")
    parser.add_argument("output_dir", help="Output directory for JSON files")
    parser.add_argument("files", nargs="*", help="Overlap TSV files")
    parser.add_argument("--dir", help="Directory containing overlap TSV files")
    args = parser.parse_args()

    files = list(args.files)
    if args.dir:
        files.extend(sorted(Path(args.dir).glob("*.tsv")))

    os.makedirs(args.output_dir, exist_ok=True)
    metadata = load_metadata(args.metadata)

    for filepath in files:
        filepath = str(filepath)
        result = process_overlap_file(filepath, metadata)
        if result:
            outpath = os.path.join(args.output_dir, f"{result['experiment_id']}.json")
            with open(outpath, "w") as f:
                json.dump(result, f)
            size_kb = os.path.getsize(outpath) / 1024
            print(f"{result['experiment_id']}: {result['window_5kb']['total_genes']} genes, {size_kb:.0f} KB")

    print(f"\nGenerated {len(files)} JSON files in {args.output_dir}/")


if __name__ == "__main__":
    main()
