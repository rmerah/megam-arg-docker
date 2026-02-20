#===============================================================================
# MEGAM ARG Detection — Dockerfile
# Image unique contenant tous les outils bioinformatiques + backend + frontend
#===============================================================================

FROM condaforge/mambaforge:latest

LABEL maintainer="Rachid Merah <rachid.merah77@gmail.com>"
LABEL description="MEGAM ARG Detection Pipeline v3.2 — Docker Edition"

# Éviter les prompts interactifs
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Dépendances système + nginx
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    procps \
    curl \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Environnement mamba principal : megam_arg
# Tous les outils bioinformatiques dans un seul env
# ─────────────────────────────────────────────────────────────────────────────
# QC: fastqc, fastp, multiqc
# Données: sra-tools
# Assemblage: spades, quast, seqkit, megahit
# Mapping: samtools, bcftools
# ARG detection: amrfinderplus, kma, blast
# MLST: mlst
# Analyse Python: pandas, matplotlib, seaborn, openpyxl, biopython
RUN mamba create -n megam_arg -c conda-forge -c bioconda -c defaults \
    python=3.11 \
    fastqc=0.12.1 fastp multiqc=1.19 \
    sra-tools">=3.0" \
    spades=3.15.5 quast=5.2.0 seqkit=2.5.1 megahit \
    samtools=1.18 bcftools=1.18 \
    ncbi-amrfinderplus kma blast \
    mlst=2.23.0 \
    pandas matplotlib seaborn openpyxl biopython \
    --yes \
    && mamba clean -afy

# Snippy et Prokka dans un env séparé (conflits fréquents avec spades/quast)
RUN mamba create -n snippy_prokka -c conda-forge -c bioconda -c defaults \
    snippy=4.6.0 \
    prokka=1.14.6 \
    --yes \
    && mamba clean -afy

# Abricate dans un env séparé (conflits Perl fréquents)
RUN mamba create -n abricate_env -c conda-forge -c bioconda -c defaults \
    abricate \
    --yes \
    && mamba clean -afy

# ─────────────────────────────────────────────────────────────────────────────
# Dépendances backend Python (FastAPI, uvicorn, etc.)
# ─────────────────────────────────────────────────────────────────────────────
COPY src/backend/requirements.txt /tmp/requirements.txt
RUN /opt/conda/envs/megam_arg/bin/pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# ─────────────────────────────────────────────────────────────────────────────
# Copier le code source
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR /app

COPY src/backend/    /app/backend/
COPY src/frontend/   /app/frontend/
COPY src/pipeline/   /app/pipeline/
COPY src/python/     /app/python/

# Rendre le pipeline exécutable
RUN chmod +x /app/pipeline/*.sh

# ─────────────────────────────────────────────────────────────────────────────
# Configuration nginx
# ─────────────────────────────────────────────────────────────────────────────
COPY docker/nginx.conf /etc/nginx/sites-available/default

# ─────────────────────────────────────────────────────────────────────────────
# Créer les répertoires persistants
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /app/pipeline/databases \
             /app/pipeline/outputs \
             /app/pipeline/data \
             /app/backend

# ─────────────────────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────────────────────
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/api/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
