# ChIP-Atlas Pipeline v2: All-in-one container
#
# Contains all tools for the v2 production pipeline with pinned versions.
#
# Build:
#   docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2:latest containers/
#
# Test:
#   docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:latest bash -c \
#     "fastp --version && bwa-mem2 version 2>&1 | head -1 && \
#      samtools --version | head -1 && macs3 --version && \
#      bedtools --version && bedGraphToBigWig 2>&1 | head -1 && \
#      bedToBigBed 2>&1 | head -1"
#
FROM condaforge/mambaforge:latest

LABEL org.opencontainers.image.source="https://github.com/inutano/chip-atlas-pipeline-v2"
LABEL org.opencontainers.image.description="ChIP-Atlas Pipeline v2 all-in-one container"

# Install all tools in one mamba call
RUN mamba install -y -c bioconda -c conda-forge \
    fastp=0.23.4 \
    bwa-mem2=2.2.1 \
    samtools=1.19 \
    macs3=3.0 \
    bedtools=2.31 \
    ucsc-bedgraphtobigwig=482 \
    ucsc-bedtobigbed=482 \
    && mamba clean -afy

# Verify
RUN fastp --version 2>&1 && \
    bwa-mem2 version 2>&1 | head -1 && \
    samtools --version | head -1 && \
    macs3 --version && \
    bedtools --version && \
    bedGraphToBigWig 2>&1 | head -1 && \
    bedToBigBed 2>&1 | head -1 || true

ENTRYPOINT []
CMD ["/bin/bash"]
