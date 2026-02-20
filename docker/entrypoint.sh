#!/bin/bash
#===============================================================================
# MEGAM ARG Detection — Entrypoint Docker
# Initialise mamba, lance nginx et uvicorn
#===============================================================================

set -e

echo "=============================================="
echo "  MEGAM ARG Detection Pipeline v3.2 — Docker"
echo "=============================================="

# ─────────────────────────────────────────────────────────────────────────────
# Initialiser mamba/conda
# ─────────────────────────────────────────────────────────────────────────────
echo "[entrypoint] Initialisation de mamba..."
eval "$(/opt/conda/bin/conda shell.bash hook)"
conda activate megam_arg

# ─────────────────────────────────────────────────────────────────────────────
# jobs.db dans le volume persistant
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /app/backend/db
# Si jobs.db existe comme fichier normal (pas symlink), le déplacer dans le volume
if [ -f /app/backend/jobs.db ] && [ ! -L /app/backend/jobs.db ]; then
    mv /app/backend/jobs.db /app/backend/db/jobs.db 2>/dev/null || true
fi
# Créer/mettre à jour le symlink vers le volume persistant
ln -sf /app/backend/db/jobs.db /app/backend/jobs.db

# ─────────────────────────────────────────────────────────────────────────────
# Vérifier les bases de données
# ─────────────────────────────────────────────────────────────────────────────
DB_DIR="/app/pipeline/databases"
if [ ! -d "$DB_DIR/amrfinder_db" ] || [ ! -d "$DB_DIR/card_db" ]; then
    echo ""
    echo "=========================================================="
    echo "  INFO: Les bases de données ARG ne sont pas encore"
    echo "  installées. Utilisez la page 'Bases de données' dans"
    echo "  l'interface web pour les télécharger."
    echo "=========================================================="
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Lancer nginx en arrière-plan
# ─────────────────────────────────────────────────────────────────────────────
echo "[entrypoint] Démarrage de nginx..."
nginx

# ─────────────────────────────────────────────────────────────────────────────
# Lancer uvicorn en foreground
# ─────────────────────────────────────────────────────────────────────────────
echo "[entrypoint] Démarrage de l'API backend (uvicorn)..."
echo ""
echo "  Application accessible sur : http://localhost:${MEGAM_PORT:-8080}"
echo ""

cd /app/backend
exec python -m uvicorn main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers 1 \
    --log-level info
