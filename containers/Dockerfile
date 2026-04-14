# ChIP-Atlas Pipeline v2: All-in-one container
#
# Contains all tools for the v2 ChIP-seq / ATAC-seq / DNase-seq pipeline.
# Tool versions are pinned for reproducibility.
#
# Build:
#   docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 \
#     -t ghcr.io/inutano/chip-atlas-pipeline-v2:latest \
#     -f containers/Dockerfile containers/
#
# Test:
#   docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:v1.0.0 versions.sh
#
FROM condaforge/mambaforge:latest

LABEL org.opencontainers.image.source="https://github.com/inutano/chip-atlas-pipeline-v2"
LABEL org.opencontainers.image.description="ChIP-Atlas Pipeline v2 all-in-one container"
LABEL org.opencontainers.image.version="1.0.0"

RUN mamba install -y -c bioconda -c conda-forge \
    fastp=1.3.1 \
    bwa-mem2=2.3 \
    samtools=1.23.1 \
    macs3=3.0.4 \
    bedtools=2.31.1 \
    ucsc-bedgraphtobigwig=482 \
    ucsc-bedtobigbed=482 \
    && mamba clean -afy

# Version check script
RUN printf '#!/bin/bash\n\
echo "fastp $(fastp --version 2>&1)"\n\
echo "bwa-mem2 $(bwa-mem2 version 2>&1 | head -1)"\n\
echo "samtools $(samtools --version | head -1)"\n\
echo "macs3 $(macs3 --version 2>&1)"\n\
echo "bedtools $(bedtools --version 2>&1)"\n\
echo "bedGraphToBigWig $(bedGraphToBigWig 2>&1 | head -1)"\n\
echo "bedToBigBed $(bedToBigBed 2>&1 | head -1)"\n' > /usr/local/bin/versions.sh \
    && chmod +x /usr/local/bin/versions.sh

# Verify all tools work
RUN versions.sh

ENTRYPOINT []
CMD ["/bin/bash"]
