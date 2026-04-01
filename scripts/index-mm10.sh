#!/bin/bash
# Wait for the prepare-genomes script to finish, then build mm10 index
set -e

echo "Waiting for prepare-genomes.sh to finish..."
while pgrep -f 'prepare-genomes.sh' > /dev/null 2>&1; do
  sleep 60
done
echo "prepare-genomes.sh finished."

echo "Building mm10 BWA-MEM2 index..."
cd /data3/chip-atlas-v2/test-run/mm10
docker run --rm -u "$(id -u):$(id -g)" -v "$(pwd)":/data -w /data \
  quay.io/biocontainers/bwa-mem2:2.2.1--he70b90d_8 bwa-mem2 index mm10.fa 2>&1

echo "mm10 index complete!"
