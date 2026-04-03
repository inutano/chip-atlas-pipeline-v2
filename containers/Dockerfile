# ChIP-Atlas Pipeline v2: All-in-one container
#
# Contains all tools needed for the Option B Fast pipeline with pinned
# versions matching the individual BioContainers used in step-by-step CWL.
#
# Build:
#   docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2:latest containers/
#
# Test:
#   docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:latest bash -c \
#     "fastp --version && bwa-mem2 version && samtools --version | head -1 && \
#      macs3 --version && bamCoverage --version && bedtools --version && \
#      bedToBigBed 2>&1 | head -1"
#
FROM mambaorg/micromamba:1.5-jammy

LABEL org.opencontainers.image.source="https://github.com/inutano/chip-atlas-pipeline-v2"
LABEL org.opencontainers.image.description="ChIP-Atlas Pipeline v2 all-in-one container"

USER root

# Install via conda with pinned versions
RUN micromamba install -y -n base -c bioconda -c conda-forge \
    fastp=0.23.4 \
    bwa-mem2=2.2.1 \
    samtools=1.19.2 \
    macs3=3.0.4 \
    deeptools=3.5.6 \
    bedtools=2.31.1 \
    ucsc-bedgraphtobigwig=482 \
    ucsc-bedtobigbed=482 \
    && micromamba clean -afy

# Verify all tools are accessible
RUN fastp --version 2>&1 && \
    bwa-mem2 version 2>&1 | head -1 && \
    samtools --version | head -1 && \
    macs3 --version && \
    bamCoverage --version && \
    bedtools --version && \
    bedToBigBed 2>&1 | head -1 || true

ENV PATH="/opt/conda/bin:$PATH"

ENTRYPOINT []
CMD ["/bin/bash"]
