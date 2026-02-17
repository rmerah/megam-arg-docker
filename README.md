# MEGAM ARG Detection — Docker Edition

Pipeline de détection des gènes de résistance aux antimicrobiens (ARG) packagé dans Docker avec un installeur Windows.

## Installation rapide (Windows)

1. Téléchargez `MEGAM-ARG-Detection-Setup-3.2.exe` depuis la page [Releases](https://github.com/rmerah/megam-arg-docker/releases)
2. Double-cliquez sur l'installeur et suivez les instructions
3. L'installeur vérifie et installe automatiquement WSL2 et Docker Desktop si nécessaire
4. Double-cliquez sur le raccourci **MEGAM ARG Detection** sur le bureau

## Installation (Linux / Docker)

```bash
git clone https://github.com/rmerah/megam-arg-docker.git
cd megam-arg-docker
cp .env.example .env
docker compose -f docker/docker-compose.yml up -d
```

L'application est accessible sur `http://localhost:8080`.

## Architecture Docker

L'image Docker contient tous les outils bioinformatiques pré-installés via mamba :

| Environnement | Outils |
|---------------|--------|
| `megam_arg` | FastQC, fastp, MultiQC, SRA-tools, SPAdes, QUAST, SeqKit, MEGAHIT, samtools, bcftools, AMRFinderPlus, KMA, BLAST, MLST |
| `snippy_prokka` | Snippy, Prokka |
| `abricate_env` | Abricate |

### Volumes persistants

| Volume | Contenu |
|--------|---------|
| `megam-databases` | Bases de données ARG (AMRFinder, CARD, etc.) |
| `megam-outputs` | Résultats des analyses |
| `megam-data` | Données téléchargées (SRA, GenBank) |
| `megam-db` | Base SQLite des jobs |

## Configuration

Copiez `.env.example` en `.env` :

```bash
cp .env.example .env
```

| Variable | Défaut | Description |
|----------|--------|-------------|
| `MEGAM_PORT` | `8080` | Port d'accès à l'application |
| `MEGAM_THREADS` | `4` | Nombre de threads pour le pipeline |

## Types d'entrée supportés

| Type | Pattern | Exemple |
|------|---------|---------|
| SRA | `SRR*`, `ERR*`, `DRR*` | SRR28083254 |
| GenBank | `CP*`, `NC_*`, `NZ_*` | CP133916.1 |
| Assembly | `GCA_*`, `GCF_*` | GCA_000005845.2 |
| Fichier local | `.fasta`, `.fna`, `.fa` | Upload via l'interface |

## Commandes utiles

```bash
# Démarrer
docker compose -f docker/docker-compose.yml up -d

# Arrêter
docker compose -f docker/docker-compose.yml down

# Voir les logs
docker compose -f docker/docker-compose.yml logs -f

# Reconstruire l'image
docker compose -f docker/docker-compose.yml build --no-cache
```

## Auteur

Rachid Merah — rachid.merah77@gmail.com

## Licence

MIT
