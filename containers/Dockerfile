# ChIP-Atlas Pipeline v2: All-in-one container
#
# Contains all tools for the v2 production pipeline.
# Versions resolved by conda solver — record actual versions in build log.
#
# Build:
#   docker build -t ghcr.io/inutano/chip-atlas-pipeline-v2:latest containers/
#
# Test:
#   docker run --rm ghcr.io/inutano/chip-atlas-pipeline-v2:latest versions.sh
#
FROM condaforge/mambaforge:latest

LABEL org.opencontainers.image.source="https://github.com/inutano/chip-atlas-pipeline-v2"
LABEL org.opencontainers.image.description="ChIP-Atlas Pipeline v2 all-in-one container"

RUN mamba install -y -c bioconda -c conda-forge \
    fastp \
    bwa-mem2 \
    samtools \
    macs3 \
    bedtools \
    ucsc-bedgraphtobigwig \
    ucsc-bedtobigbed \
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
