#!/usr/bin/env python3
"""
Build SQLite database from peak-TSS overlap TSV files.

Usage:
  # Build from individual overlap files
  python3 build-target-genes-db.py output.db overlap1.tsv overlap2.tsv ...

  # Build from all files in a directory
  python3 build-target-genes-db.py output.db --dir results/
"""

import sqlite3
import csv
import sys
import os
import argparse
from pathlib import Path


def create_schema(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS peak_tss_overlap (
            experiment_id TEXT NOT NULL,
            peak_chrom TEXT NOT NULL,
            peak_start INTEGER NOT NULL,
            peak_end INTEGER NOT NULL,
            peak_score REAL,
            gene_symbol TEXT NOT NULL,
            tss_distance INTEGER,
            window_kb INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS metadata (
            experiment_id TEXT PRIMARY KEY,
            genome TEXT,
            experiment_type TEXT,
            antigen TEXT,
            cell_type TEXT,
            cell_type_class TEXT
        );
    """)


def load_overlap_file(conn, filepath):
    """Load a single overlap TSV into the database."""
    loaded = 0
    with open(filepath) as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows = []
        for row in reader:
            rows.append((
                row["experiment_id"],
                row["peak_chrom"],
                int(row["peak_start"]),
                int(row["peak_end"]),
                float(row["peak_score"]) if row["peak_score"] else 0,
                row["gene_symbol"],
                int(row["tss_distance"]) if row["tss_distance"] else 0,
                int(row["window_kb"]),
            ))
        conn.executemany(
            "INSERT INTO peak_tss_overlap VALUES (?,?,?,?,?,?,?,?)",
            rows,
        )
        loaded = len(rows)
    return loaded


def load_metadata(conn, metadata_file, genome):
    """Load experiment metadata from validation-samples.tsv or experimentList.tab."""
    with open(metadata_file) as f:
        reader = csv.reader(f, delimiter="\t")
        next(reader)  # skip header
        rows = []
        for row in reader:
            if len(row) >= 6 and row[1] == genome:
                rows.append((row[0], row[1], row[2], row[3], row[4], row[5]))
        conn.executemany(
            "INSERT OR IGNORE INTO metadata VALUES (?,?,?,?,?,?)",
            rows,
        )
    return len(rows)


def create_indexes(conn):
    conn.executescript("""
        CREATE INDEX IF NOT EXISTS idx_overlap_exp ON peak_tss_overlap(experiment_id);
        CREATE INDEX IF NOT EXISTS idx_overlap_gene ON peak_tss_overlap(gene_symbol);
        CREATE INDEX IF NOT EXISTS idx_overlap_window ON peak_tss_overlap(window_kb);
        CREATE INDEX IF NOT EXISTS idx_overlap_chrom ON peak_tss_overlap(peak_chrom, peak_start, peak_end);
        CREATE INDEX IF NOT EXISTS idx_meta_antigen ON metadata(antigen);
        CREATE INDEX IF NOT EXISTS idx_meta_cell ON metadata(cell_type);
    """)


def print_stats(conn):
    """Print database statistics."""
    cursor = conn.cursor()

    total = cursor.execute("SELECT COUNT(*) FROM peak_tss_overlap").fetchone()[0]
    experiments = cursor.execute("SELECT COUNT(DISTINCT experiment_id) FROM peak_tss_overlap").fetchone()[0]
    genes = cursor.execute("SELECT COUNT(DISTINCT gene_symbol) FROM peak_tss_overlap").fetchone()[0]

    print(f"\n=== Database Statistics ===")
    print(f"Total overlaps: {total:,}")
    print(f"Experiments: {experiments}")
    print(f"Unique genes: {genes}")

    for kb in [1, 5, 10]:
        n = cursor.execute("SELECT COUNT(*) FROM peak_tss_overlap WHERE window_kb = ?", (kb,)).fetchone()[0]
        print(f"  ±{kb}kb: {n:,} overlaps")

    # Top genes
    print(f"\nTop 10 genes by number of experiments (±5kb):")
    for row in cursor.execute("""
        SELECT gene_symbol, COUNT(DISTINCT experiment_id) as n_exp, ROUND(AVG(peak_score), 1) as avg_score
        FROM peak_tss_overlap
        WHERE window_kb = 5
        GROUP BY gene_symbol
        ORDER BY n_exp DESC
        LIMIT 10
    """):
        print(f"  {row[0]}: {row[1]} experiments, avg score {row[2]}")

    # DB file size
    db_path = cursor.execute("PRAGMA database_list").fetchone()[2]
    if db_path and os.path.exists(db_path):
        size_mb = os.path.getsize(db_path) / 1048576
        print(f"\nDatabase size: {size_mb:.1f} MB")


def main():
    parser = argparse.ArgumentParser(description="Build target genes SQLite database")
    parser.add_argument("db", help="Output SQLite database path")
    parser.add_argument("files", nargs="*", help="Overlap TSV files to load")
    parser.add_argument("--dir", help="Directory containing overlap TSV files")
    parser.add_argument("--metadata", help="Metadata TSV file (validation-samples.tsv)")
    parser.add_argument("--genome", default="ce11", help="Genome name for metadata filtering")
    args = parser.parse_args()

    # Collect files
    files = list(args.files)
    if args.dir:
        files.extend(sorted(Path(args.dir).glob("*.tsv")))

    if not files:
        print("No input files specified.", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(args.db)
    create_schema(conn)

    # Load metadata if provided
    if args.metadata:
        n = load_metadata(conn, args.metadata, args.genome)
        print(f"Loaded {n} metadata entries")

    # Load overlap files
    total_loaded = 0
    for filepath in files:
        filepath = str(filepath)
        if not os.path.exists(filepath):
            print(f"WARNING: {filepath} not found, skipping")
            continue
        n = load_overlap_file(conn, filepath)
        total_loaded += n
        print(f"Loaded {n:,} overlaps from {os.path.basename(filepath)}")

    conn.commit()

    # Create indexes
    print("Creating indexes...")
    create_indexes(conn)
    conn.commit()

    # Print stats
    print_stats(conn)

    conn.close()
    print(f"\nDatabase saved to: {args.db}")


if __name__ == "__main__":
    main()
