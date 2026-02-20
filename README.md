<p align="center">
  <img src="src/frontend/logo.png" alt="MEGAM ARG Detection" width="400">
</p>

<h3 align="center">Pipeline de détection des gènes de résistance aux antimicrobiens</h3>

<p align="center">
  AMRFinderPlus · ResFinder · CARD · Prokka · SPAdes · MEGAHIT · Snippy · Abricate
</p>

<p align="center">
  <a href="https://github.com/rmerah/megam-arg-docker/releases/latest">
    <img src="https://img.shields.io/github/v/release/rmerah/megam-arg-docker?label=T%C3%A9l%C3%A9charger&style=for-the-badge&color=blue" alt="Télécharger">
  </a>
</p>

---

## Installation sur Windows (recommandé)

**1.** Téléchargez l'installeur : **[MEGAM-ARG-Detection-Setup-3.2.exe](https://github.com/rmerah/megam-arg-docker/releases/latest/download/MEGAM-ARG-Detection-Setup-3.2.exe)**

**2.** Double-cliquez sur le fichier téléchargé

**3.** Suivez l'assistant — il installe **tout automatiquement** :
   - WSL2 (si absent) → ~3 min, redémarrage nécessaire
   - Docker Desktop (si absent) → ~5 min, redémarrage nécessaire

**4.** Double-cliquez sur le raccourci **MEGAM ARG Detection** sur votre bureau

**5.** Au premier lancement, l'image Docker se télécharge (~10-15 min, une seule fois)

**6.** Votre navigateur s'ouvre sur l'interface → collez un identifiant (ex: `SRR28083254`) et lancez l'analyse

> Les lancements suivants prennent **~30 secondes**.

---

## Installation sur Linux / WSL

**1.** Installez Docker si ce n'est pas déjà fait :
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Déconnectez-vous puis reconnectez-vous
```

**2.** Téléchargez et lancez :
```bash
git clone https://github.com/rmerah/megam-arg-docker.git
cd megam-arg-docker
cp .env.example .env
docker compose -f docker/docker-compose.yml up -d
```

**3.** Ouvrez votre navigateur sur **http://localhost:8080**

**4.** Pour arrêter :
```bash
docker compose -f docker/docker-compose.yml down
```

---

## Utilisation

| Type d'entrée | Exemples | Description |
|---------------|----------|-------------|
| SRA | `SRR28083254`, `ERR123456` | Reads depuis NCBI SRA |
| GenBank | `CP133916.1`, `NC_000913` | Séquence assemblée |
| Assembly | `GCA_000005845.2` | Assemblage NCBI |
| Fichier local | Upload `.fasta`, `.fna` | Votre propre fichier |

1. Collez un identifiant ou uploadez un fichier FASTA
2. Cliquez **Lancer l'analyse**
3. Suivez la progression en temps réel sur le dashboard
4. Consultez les résultats (gènes ARG détectés, tableaux, graphiques)

> Lors de la première analyse, téléchargez les bases de données (AMRFinder, CARD...) depuis la page **Bases de données** de l'interface.

---

## Configuration (optionnel)

Modifiez le fichier `.env` à la racine du projet :

| Variable | Défaut | Description |
|----------|--------|-------------|
| `MEGAM_PORT` | `8080` | Port d'accès à l'application |
| `MEGAM_THREADS` | `4` | Nombre de threads pour le pipeline |

---

## Commandes utiles (Linux)

```bash
# Voir les logs en temps réel
docker compose -f docker/docker-compose.yml logs -f

# Reconstruire l'image après mise à jour
docker compose -f docker/docker-compose.yml build --no-cache

# Supprimer les données (bases, résultats, jobs)
docker compose -f docker/docker-compose.yml down -v
```

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Conteneur Docker                   │
│                                                 │
│  ┌──────────┐       ┌───────────────────────┐   │
│  │  Nginx   │──────>│  Backend FastAPI       │   │
│  │  :80     │ /api/ │  (uvicorn :8000)      │   │
│  │          │       │                       │   │
│  │  sert le │       │  Lance le pipeline    │   │
│  │  frontend│       │  bash en subprocess   │   │
│  └──────────┘       └───────────┬───────────┘   │
│                                 │               │
│                     ┌───────────▼───────────┐   │
│                     │  Pipeline bash v3.2   │   │
│                     │  (mamba envs)         │   │
│                     │                       │   │
│                     │  megam_arg: FastQC,   │   │
│                     │    SPAdes, AMRFinder  │   │
│                     │  snippy_prokka:       │   │
│                     │    Prokka, Snippy     │   │
│                     │  abricate_env:        │   │
│                     │    Abricate           │   │
│                     └───────────────────────┘   │
│                                                 │
│  Volumes: databases/ outputs/ data/ jobs.db     │
└─────────────────────────────────────────────────┘
```

---

## Auteur

Rachid Merah — rachid.merah77@gmail.com

## Licence

MIT
