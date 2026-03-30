#!/usr/bin/env python3
"""
Generate aggregated target genes JSON per antigen.
Groups all experiments for a given antigen, showing genes × experiments matrix.

Usage:
  python3 generate-antigen-target-json.py chip_atlas.db output_dir/ [--genome ce11]
"""

import sqlite3
import json
import os
import sys
import argparse
from collections import defaultdict


def generate_antigen_json(conn, antigen, genome, window_kb):
    """Generate target genes JSON for one antigen at one window size."""

    # Get all experiments for this antigen
    experiments = conn.execute("""
        SELECT experiment_id, cell_type, cell_type_class
        FROM metadata
        WHERE antigen = ? AND genome = ?
        ORDER BY cell_type
    """, (antigen, genome)).fetchall()

    if not experiments:
        return None

    exp_ids = [e[0] for e in experiments]

    # Get all peak-TSS overlaps for these experiments at this window
    placeholders = ",".join("?" * len(exp_ids))
    rows = conn.execute(f"""
        SELECT experiment_id, gene_symbol, peak_score
        FROM peak_tss_overlap
        WHERE experiment_id IN ({placeholders})
          AND window_kb = ?
    """, exp_ids + [window_kb]).fetchall()

    # Build gene × experiment score matrix
    # For each gene × experiment, take the max peak score
    gene_scores = defaultdict(lambda: defaultdict(float))
    for exp_id, gene, score in rows:
        if score > gene_scores[gene][exp_id]:
            gene_scores[gene][exp_id] = score

    # Compute average score per gene across experiments
    gene_avg = {}
    for gene, exp_scores in gene_scores.items():
        scores = list(exp_scores.values())
        gene_avg[gene] = sum(scores) / len(exp_ids)  # avg over ALL experiments (0 for missing)

    # Sort genes by average score descending
    sorted_genes = sorted(gene_avg.keys(), key=lambda g: gene_avg[g], reverse=True)

    result = {
        "antigen": antigen,
        "genome": genome,
        "window_kb": window_kb,
        "total_genes": len(sorted_genes),
        "experiments": [
            {
                "id": e[0],
                "cell_type": e[1],
                "cell_type_class": e[2],
            }
            for e in experiments
        ],
        "genes": [
            {
                "symbol": gene,
                "avg_score": round(gene_avg[gene], 1),
                "scores": {
                    exp_id: round(gene_scores[gene].get(exp_id, 0), 1)
                    for exp_id in exp_ids
                },
            }
            for gene in sorted_genes
        ],
    }

    return result


def main():
    parser = argparse.ArgumentParser(description="Generate per-antigen target genes JSON")
    parser.add_argument("db", help="SQLite database path")
    parser.add_argument("output_dir", help="Output directory for JSON files")
    parser.add_argument("--genome", default="ce11", help="Genome")
    parser.add_argument("--antigen", help="Specific antigen (default: all)")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    conn = sqlite3.connect(args.db)

    # Get all antigens
    if args.antigen:
        antigens = [args.antigen]
    else:
        antigens = [r[0] for r in conn.execute(
            "SELECT DISTINCT antigen FROM metadata WHERE genome = ? AND antigen != ''",
            (args.genome,)
        ).fetchall()]

    print(f"Processing {len(antigens)} antigens for {args.genome}")

    for antigen in antigens:
        for window_kb in [1, 5, 10]:
            result = generate_antigen_json(conn, antigen, args.genome, window_kb)
            if not result or not result["genes"]:
                continue

            safe_name = antigen.replace("/", "_").replace(" ", "_")
            outpath = os.path.join(args.output_dir, f"{safe_name}.{window_kb}.json")
            with open(outpath, "w") as f:
                json.dump(result, f)

            size_kb = os.path.getsize(outpath) / 1024
            print(f"  {antigen} ±{window_kb}kb: {result['total_genes']} genes, "
                  f"{len(result['experiments'])} experiments, {size_kb:.0f} KB")

    conn.close()
    print(f"\nDone. Files in {args.output_dir}/")


if __name__ == "__main__":
    main()
