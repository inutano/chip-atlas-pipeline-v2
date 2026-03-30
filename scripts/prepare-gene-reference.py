#!/usr/bin/env python3
"""
Prepare gene reference TSS file from UCSC refFlat.
Filters for protein-coding genes (NM_ prefix), deduplicates TSS positions.

Usage:
  python3 prepare-gene-reference.py refFlat.txt > genes_tss.bed
"""

import sys
from collections import defaultdict


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 prepare-gene-reference.py refFlat.txt > genes_tss.bed", file=sys.stderr)
        sys.exit(1)

    seen_tss = set()

    with open(sys.argv[1]) as f:
        for line in f:
            fields = line.strip().split("\t")
            if len(fields) < 6:
                continue

            gene_symbol = fields[0]
            refseq_id = fields[1]
            chrom = fields[2]
            strand = fields[3]
            tx_start = int(fields[4])
            tx_end = int(fields[5])

            # Filter: protein-coding only (NM_ prefix)
            if not refseq_id.startswith("NM_"):
                continue

            # TSS is txStart for + strand, txEnd for - strand
            if strand == "+":
                tss = tx_start
            else:
                tss = tx_end

            # Deduplicate by gene + chrom + TSS position
            key = (gene_symbol, chrom, tss)
            if key in seen_tss:
                continue
            seen_tss.add(key)

            # Output as BED4: chrom, tss, tss+1, gene_symbol
            print(f"{chrom}\t{tss}\t{tss + 1}\t{gene_symbol}")


if __name__ == "__main__":
    main()
