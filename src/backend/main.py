"""
API FastAPI pour le Pipeline ARG — Version Docker
"""
from fastapi import FastAPI, HTTPException, UploadFile, File, status
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import logging
from pathlib import Path
from datetime import datetime
from typing import List, Optional
import os
import shutil
import subprocess
import threading
import time
import re as re_module

from models import (
    LaunchAnalysisRequest,
    JobResponse,
    JobStatusResponse,
    JobListResponse,
    JobListItem,
    AnalysisResults,
    DeduplicatedGene,
    DeduplicationStats,
    ErrorResponse,
    JobStatus,
    InputType
)
from database import db
from pipeline_launcher import PipelineLauncher
from output_parser import OutputParser

# Configuration logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration paths
BACKEND_DIR = Path(__file__).parent
PROJECT_ROOT = BACKEND_DIR.parent
PIPELINE_DIR = PROJECT_ROOT / "pipeline"
# Version Docker du pipeline (sans conda, outils pré-installés)
PIPELINE_SCRIPT = PIPELINE_DIR / "MANUAL_MEGA_MONOLITHIC_PIPELINE_v3.2_DOCKER.sh"

# Vérification que le pipeline existe
if not PIPELINE_SCRIPT.exists():
    logger.error(f"ERREUR CRITIQUE: Pipeline script non trouvé: {PIPELINE_SCRIPT}")
    raise FileNotFoundError(f"Pipeline script manquant: {PIPELINE_SCRIPT}")

# Initialiser le launcher
launcher = PipelineLauncher(
    pipeline_script=str(PIPELINE_SCRIPT),
    work_dir=str(PIPELINE_DIR)
)


# Lifespan context manager pour startup/shutdown
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Gestion du cycle de vie de l'application"""
    # Startup
    logger.info("=" * 60)
    logger.info("🚀 Démarrage API Pipeline ARG v3.2")
    logger.info("=" * 60)
    logger.info(f"Pipeline script: {PIPELINE_SCRIPT}")
    logger.info(f"Work directory: {PIPELINE_DIR}")
    logger.info(f"Database: {BACKEND_DIR / 'jobs.db'}")

    # Initialiser la base de données
    await db.initialize()
    logger.info("✅ Base de données initialisée")

    # Nettoyer les jobs zombies (optionnel)
    await db.cleanup_stale_jobs(max_age_hours=24)
    logger.info("✅ Nettoyage jobs zombies effectué")

    logger.info("✅ API prête à recevoir des requêtes")

    yield

    # Shutdown
    logger.info("🛑 Arrêt de l'API")


# Créer l'application FastAPI
app = FastAPI(
    title="Pipeline ARG API",
    description="API pour lancer et monitorer le pipeline de détection de gènes de résistance antimicrobienne",
    version="1.0.0",
    lifespan=lifespan
)

# Configuration CORS
# Détection du port backend (via --port de uvicorn ou variable PORT)
def _detect_backend_port():
    import sys
    for i, arg in enumerate(sys.argv):
        if arg == '--port' and i + 1 < len(sys.argv):
            return int(sys.argv[i + 1])
    return int(os.environ.get("PORT", "8000"))

# Port frontend = port backend + 80 (ex: 8000→8080, 8002→8082)
_backend_port = _detect_backend_port()
_frontend_port = _backend_port + 80
_default_origins = f"http://localhost:{_frontend_port},http://localhost:{_backend_port}"
ALLOWED_ORIGINS = os.environ.get("CORS_ORIGINS", _default_origins).split(",")

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Content-Type", "Cache-Control", "Pragma", "Expires"],
)


# ============================================================================
# ROUTES API
# ============================================================================

@app.get("/")
async def root():
    """Endpoint racine - informations API"""
    return {
        "name": "Pipeline ARG API",
        "version": "1.0.0",
        "status": "running",
        "pipeline_version": "3.2",
        "endpoints": {
            "launch": "POST /api/launch",
            "status": "GET /api/status/{job_id}",
            "results": "GET /api/results/{job_id}",
            "jobs": "GET /api/jobs",
            "health": "GET /health"
        }
    }


@app.get("/health")
@app.get("/api/health")
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "pipeline_script_exists": PIPELINE_SCRIPT.exists()
    }


# Répertoire pour les fichiers uploadés
UPLOAD_DIR = PIPELINE_DIR / "data" / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

ALLOWED_EXTENSIONS = {'.fasta', '.fa', '.fna', '.fasta.gz', '.fa.gz'}
# Note: les fichiers FASTQ ne sont pas supportés en upload local car le pipeline nécessite
# un génome pré-assemblé. Les reads bruts doivent être soumis via accession SRA.

@app.post("/api/upload")
async def upload_file(file: UploadFile = File(...)):
    """
    Upload un fichier FASTA/FASTQ pour analyse

    Returns:
        Le chemin du fichier sur le serveur à utiliser comme sample_id
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="Nom de fichier manquant")

    # Valider l'extension
    filename = file.filename.lower()
    valid = False
    for ext in ALLOWED_EXTENSIONS:
        if filename.endswith(ext):
            valid = True
            break
    if not valid:
        # Message spécifique pour les FASTQ
        if any(filename.endswith(ext) for ext in ('.fastq', '.fq', '.fastq.gz', '.fq.gz')):
            raise HTTPException(
                status_code=400,
                detail=(
                    "Les fichiers FASTQ (reads bruts) ne peuvent pas être uploadés directement. "
                    "Pour analyser des reads Illumina, utilisez un accession SRA (ex: SRR28083254). "
                    "Le pipeline téléchargera les reads et effectuera QC + assemblage automatiquement."
                )
            )
        raise HTTPException(
            status_code=400,
            detail="Format non supporté. Extensions acceptées pour l'upload : .fasta, .fa, .fna (génome assemblé)"
        )

    # Nettoyer le nom de fichier (sécurité)
    safe_filename = re_module.sub(r'[^a-zA-Z0-9._-]', '_', file.filename)
    dest_path = UPLOAD_DIR / safe_filename

    # Écrire le fichier
    try:
        with open(dest_path, "wb") as f:
            content = await file.read()
            if len(content) == 0:
                raise HTTPException(status_code=400, detail="Fichier vide")
            f.write(content)

        logger.info(f"Fichier uploadé : {dest_path} ({len(content)} bytes)")

        return {
            "filename": safe_filename,
            "path": str(dest_path),
            "size": len(content)
        }
    except HTTPException:
        raise
    except OSError:
        raise HTTPException(status_code=500, detail="Erreur lors de l'enregistrement du fichier")


@app.post("/api/launch", response_model=JobResponse, status_code=status.HTTP_201_CREATED)
async def launch_analysis(request: LaunchAnalysisRequest):
    """
    Lance une nouvelle analyse ARG

    Args:
        request: Paramètres de l'analyse

    Returns:
        JobResponse avec job_id et statut initial

    Raises:
        HTTPException 400: Si les paramètres sont invalides
        HTTPException 500: Si erreur lors du lancement
    """
    try:
        logger.info(f"📥 Nouvelle requête d'analyse: {request.sample_id}")

        # Créer le job dans la base de données
        job_id = await db.create_job(
            sample_id=request.sample_id,
            threads=request.threads,
            prokka_mode=request.prokka_mode.value,
            prokka_genus=request.prokka_genus,
            prokka_species=request.prokka_species
        )

        logger.info(f"✅ Job créé: {job_id}")

        # Définir callback de complétion
        async def on_complete(exit_code: int, stdout: str, stderr: str):
            """Callback appelé quand le pipeline se termine"""
            if exit_code == 0:
                await db.update_job_status(
                    job_id=job_id,
                    status=JobStatus.COMPLETED,
                    completed_at=datetime.now(),
                    exit_code=exit_code
                )
                logger.info(f"✅ Job {job_id} terminé avec succès")
            else:
                # Extraire message d'erreur du stderr et des logs
                error_msg = "Erreur inconnue"

                # Essayer de récupérer les dernières lignes du log pipeline
                try:
                    job_data = await db.get_job(job_id)
                    if job_data and job_data.get('run_number'):
                        log_tail = await launcher.get_log_tail(
                            sample_id=request.sample_id,
                            run_number=job_data['run_number'],
                            lines=50
                        )
                        if log_tail:
                            # Chercher les lignes d'erreur (ERROR, FAILED, Exception)
                            error_lines = [
                                line for line in log_tail.split('\n')
                                if any(x in line for x in ['[ERROR]', 'FAILED', 'Exception', 'Error'])
                            ]
                            if error_lines:
                                error_msg = '\n'.join(error_lines[-3:])  # 3 dernières erreurs
                            else:
                                error_msg = log_tail[-500:]  # Sinon, derniers 500 chars
                except Exception as e:
                    logger.warning(f"Impossible de lire logs pour erreur: {e}")

                # Fallback sur stderr si pas de log
                if error_msg == "Erreur inconnue" and stderr:
                    error_msg = stderr[-500:]

                await db.update_job_status(
                    job_id=job_id,
                    status=JobStatus.FAILED,
                    completed_at=datetime.now(),
                    exit_code=exit_code,
                    error_message=error_msg
                )
                logger.error(f"❌ Job {job_id} échoué (exit code: {exit_code}): {error_msg[:100]}")

        # Lancer le pipeline
        launch_result = await launcher.launch(
            sample_id=request.sample_id,
            threads=request.threads,
            prokka_mode=request.prokka_mode.value,
            prokka_genus=request.prokka_genus,
            prokka_species=request.prokka_species,
            force=request.force,
            on_complete=on_complete
        )

        # Mettre à jour le job avec les infos du lancement
        await db.update_job_status(
            job_id=job_id,
            status=JobStatus.RUNNING,
            started_at=datetime.now(),
            pid=launch_result['pid'],
            input_type=launch_result['input_type'],
            run_number=launch_result['run_number'],
            output_dir=launch_result['output_dir']
        )

        logger.info(f"🚀 Pipeline lancé (PID: {launch_result['pid']}, Run: {launch_result['run_number']})")

        # Retourner la réponse
        job = await db.get_job(job_id)
        return JobResponse(
            job_id=job_id,
            sample_id=request.sample_id,
            status=JobStatus.RUNNING,
            created_at=job['created_at'],
            message=f"Analyse lancée avec succès (Run #{launch_result['run_number']})"
        )

    except Exception as e:
        logger.error(f"❌ Erreur lancement analyse: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors du lancement de l'analyse"
        )


@app.get("/api/status/{job_id}", response_model=JobStatusResponse)
async def get_job_status(job_id: str):
    """
    Récupère le statut d'un job

    Args:
        job_id: ID du job

    Returns:
        JobStatusResponse avec statut actuel, progression, logs, etc.

    Raises:
        HTTPException 404: Si job non trouvé
    """
    try:
        # Récupérer le job
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Job {job_id} non trouvé"
            )

        # Estimer la progression selon le statut
        progress = None
        current_step = None
        logs_preview = None

        if job['status'] == JobStatus.COMPLETED.value:
            # Job terminé = 100%
            progress = 100
            current_step = "Analyse terminée avec succès"

            # Récupérer les derniers logs même si complété
            if job['run_number']:
                logs_preview = await launcher.get_log_tail(
                    sample_id=job['sample_id'],
                    run_number=job['run_number'],
                    lines=30
                )

        elif job['status'] == JobStatus.FAILED.value:
            # Job échoué = estimer où il s'est arrêté
            if job['input_type'] and job['run_number']:
                progress = await launcher.estimate_progress(
                    sample_id=job['sample_id'],
                    run_number=job['run_number'],
                    input_type=InputType(job['input_type'])
                )
            else:
                progress = 0

            current_step = f"Échec: {job['error_message'][:80] if job['error_message'] else 'Erreur inconnue'}"

            # Récupérer les logs pour voir l'erreur
            if job['run_number']:
                logs_preview = await launcher.get_log_tail(
                    sample_id=job['sample_id'],
                    run_number=job['run_number'],
                    lines=30
                )

        elif job['status'] == JobStatus.RUNNING.value:
            # Job en cours = estimer progression
            if job['input_type'] and job['run_number']:
                progress = await launcher.estimate_progress(
                    sample_id=job['sample_id'],
                    run_number=job['run_number'],
                    input_type=InputType(job['input_type'])
                )
            else:
                progress = 0

            # Récupérer aperçu des logs
            if job['run_number']:
                logs_preview = await launcher.get_log_tail(
                    sample_id=job['sample_id'],
                    run_number=job['run_number'],
                    lines=30
                )

                # Extraire l'étape actuelle du log
                if logs_preview:
                    # Chercher dernière ligne avec [INFO]
                    for line in reversed(logs_preview.split('\n')):
                        if '[INFO]' in line:
                            current_step = line.split('[INFO]')[-1].strip()[:100]
                            break

        else:
            # PENDING ou autre statut
            progress = 0
            current_step = "En attente de démarrage"

        return JobStatusResponse(
            job_id=job_id,
            sample_id=job['sample_id'],
            status=JobStatus(job['status']),
            input_type=InputType(job['input_type']) if job['input_type'] else None,
            run_number=job['run_number'],
            progress=progress,
            current_step=current_step,
            created_at=job['created_at'],
            started_at=job['started_at'],
            completed_at=job['completed_at'],
            exit_code=job['exit_code'],
            error_message=job['error_message'],
            logs_preview=logs_preview
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"❌ Erreur récupération statut: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors de la récupération du statut"
        )


@app.get("/api/results/{job_id}", response_model=AnalysisResults)
async def get_job_results(job_id: str):
    """
    Récupère les résultats d'une analyse terminée

    Args:
        job_id: ID du job

    Returns:
        AnalysisResults avec gènes ARG détectés, stats assemblage, etc.

    Raises:
        HTTPException 404: Si job non trouvé
        HTTPException 400: Si job pas encore terminé
        HTTPException 500: Si erreur parsing résultats
    """
    try:
        # Récupérer le job
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Job {job_id} non trouvé"
            )

        # Vérifier que le job est terminé
        if job['status'] != JobStatus.COMPLETED.value:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Job {job_id} pas encore terminé (statut: {job['status']})"
            )

        # Parser les résultats
        parser = OutputParser(job['output_dir'])

        # Parser détection ARG (brut par outil)
        arg_detection = parser.parse_all_arg_detection()

        # Parser détection ARG avec déduplication (comme le rapport HTML)
        deduplicated_data = parser.parse_all_arg_deduplicated()
        deduplicated_genes = [
            DeduplicatedGene(**gene) for gene in deduplicated_data['genes']
        ]
        dedup_stats = DeduplicationStats(
            total_raw=deduplicated_data['stats']['total_raw'],
            total_deduplicated=deduplicated_data['stats']['total_deduplicated'],
            duplicates_removed=deduplicated_data['stats']['duplicates_removed'],
            by_type=deduplicated_data['stats']['by_type']
        )

        # Parser stats assemblage (si disponible)
        assembly_stats = parser.parse_assembly_stats()

        # Parser informations taxonomiques (via NCBI API)
        ncbi_info = parser.fetch_ncbi_organism(job['sample_id'], job['input_type'])
        taxonomy_info = {'ncbi': ncbi_info, 'source': 'NCBI'} if ncbi_info else None
        mlst_info = parser.parse_mlst()

        # Trouver rapport HTML
        report_html_path = parser.get_report_html_path()

        # Calculer statistiques globales
        total_arg_genes_raw = sum(r.num_genes for r in arg_detection.values())
        total_unique_genes = deduplicated_data['stats']['total_deduplicated']
        unique_resistance_types = parser.get_unique_resistance_types(arg_detection)

        return AnalysisResults(
            job_id=job_id,
            sample_id=job['sample_id'],
            run_number=job['run_number'],
            input_type=InputType(job['input_type']),
            assembly_stats=assembly_stats,
            arg_detection=arg_detection,
            deduplicated_genes=deduplicated_genes,
            deduplication_stats=dedup_stats,
            total_arg_genes=total_arg_genes_raw,
            total_unique_genes=total_unique_genes,
            unique_resistance_types=unique_resistance_types,
            taxonomy=taxonomy_info,
            mlst=mlst_info,
            report_html_path=report_html_path,
            output_directory=job['output_dir'],
            completed_at=job['completed_at']
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"❌ Erreur récupération résultats: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors du parsing des résultats"
        )


@app.get("/api/jobs", response_model=JobListResponse)
async def list_jobs(
    status_filter: Optional[JobStatus] = None,
    limit: int = 100,
    offset: int = 0
):
    """
    Liste tous les jobs avec filtres optionnels

    Args:
        status_filter: Filtrer par statut (optionnel)
        limit: Nombre maximum de résultats (défaut: 100)
        offset: Offset pour pagination (défaut: 0)

    Returns:
        JobListResponse avec liste des jobs
    """
    try:
        # Récupérer les jobs
        jobs = await db.get_jobs(status=status_filter, limit=limit, offset=offset)
        total = await db.count_jobs(status=status_filter)

        # Convertir en JobListItem
        job_items = [
            JobListItem(
                job_id=job['id'],
                sample_id=job['sample_id'],
                status=JobStatus(job['status']),
                input_type=InputType(job['input_type']) if job['input_type'] else None,
                created_at=job['created_at'],
                completed_at=job['completed_at']
            )
            for job in jobs
        ]

        return JobListResponse(
            total=total,
            jobs=job_items
        )

    except Exception as e:
        logger.error(f"❌ Erreur listing jobs: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors de la récupération de la liste des jobs"
        )


@app.delete("/api/jobs/{job_id}")
async def delete_job(job_id: str, delete_files: bool = True):
    """
    Supprime un job spécifique et ses fichiers associés

    Args:
        job_id: ID du job à supprimer
        delete_files: Supprimer aussi les fichiers sur disque (défaut: True)

    Returns:
        Message de confirmation

    Raises:
        HTTPException 404: Si job non trouvé
    """
    try:
        # Vérifier que le job existe
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Job {job_id} non trouvé"
            )

        # Supprimer les fichiers sur disque
        files_deleted = False
        if delete_files and job.get('output_dir'):
            output_path = Path(job['output_dir'])
            if output_path.exists():
                try:
                    shutil.rmtree(output_path)
                    files_deleted = True
                    logger.info(f"🗑️ Fichiers supprimés: {output_path}")
                except OSError as e:
                    logger.error(f"Erreur suppression fichiers {output_path}: {e}")

        # Supprimer le job de la DB
        await db.delete_job(job_id)
        logger.info(f"🗑️ Job {job_id} supprimé (fichiers: {'oui' if files_deleted else 'non'})")

        return {"message": f"Job {job_id} supprimé avec succès"}

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"❌ Erreur suppression job: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors de la suppression du job"
        )


@app.delete("/api/jobs")
async def delete_all_jobs(delete_files: bool = True):
    """
    Supprime TOUS les jobs et leurs fichiers associés

    Args:
        delete_files: Supprimer aussi les fichiers sur disque (défaut: True)

    Returns:
        Message de confirmation avec nombre de jobs supprimés
    """
    try:
        files_deleted = 0

        # Supprimer les fichiers de chaque job avant de vider la DB
        if delete_files:
            jobs = await db.get_jobs(limit=10000)
            for job in jobs:
                if job.get('output_dir'):
                    output_path = Path(job['output_dir'])
                    if output_path.exists():
                        try:
                            shutil.rmtree(output_path)
                            files_deleted += 1
                            logger.info(f"🗑️ Fichiers supprimés: {output_path}")
                        except OSError as e:
                            logger.error(f"Erreur suppression {output_path}: {e}")

        count = await db.delete_all_jobs()
        logger.warning(f"🗑️ Tous les jobs supprimés ({count} jobs, {files_deleted} dossiers)")

        return {
            "message": f"{count} jobs supprimés avec succès ({files_deleted} dossiers nettoyés)"
        }

    except Exception as e:
        logger.error(f"❌ Erreur suppression tous jobs: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors de la suppression de tous les jobs"
        )


# ============================================================================
# ARRÊT DE JOB
# ============================================================================

@app.post("/api/jobs/{job_id}/stop")
async def stop_job(job_id: str):
    """
    Arrête un job en cours d'exécution

    Args:
        job_id: ID du job à arrêter

    Returns:
        Message de confirmation

    Raises:
        HTTPException 404: Si job non trouvé
        HTTPException 400: Si job pas en cours d'exécution
    """
    try:
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Job {job_id} non trouvé"
            )

        if job['status'] != JobStatus.RUNNING.value:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Job {job_id} n'est pas en cours d'exécution (statut: {job['status']})"
            )

        # Récupérer le PID
        pid = job.get('pid')

        # Tenter de tuer le processus si PID disponible
        process_killed = False
        if pid:
            try:
                process_killed = await launcher.kill_job(pid)
            except Exception as e:
                logger.warning(f"Impossible de tuer le processus {pid}: {e}")

        # TOUJOURS mettre à jour le statut dans la base de données
        await db.update_job_status(
            job_id=job_id,
            status=JobStatus.FAILED,
            completed_at=datetime.now(),
            error_message="Arrêté manuellement par l'utilisateur"
        )

        logger.info(f"🛑 Job {job_id} marqué comme arrêté (processus tué: {process_killed})")

        return {
            "message": f"Job {job_id} arrêté avec succès",
            "success": True,
            "process_killed": process_killed
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"❌ Erreur arrêt job: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors de l'arrêt du job"
        )


# ============================================================================
# LISTE DES FICHIERS D'UN JOB
# ============================================================================

@app.get("/api/jobs/{job_id}/files")
async def list_job_files(job_id: str):
    """
    Liste tous les fichiers générés par un job

    Args:
        job_id: ID du job

    Returns:
        Liste des fichiers avec leurs métadonnées
    """
    try:
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Job {job_id} non trouvé"
            )

        output_dir = job.get('output_dir')
        if not output_dir or not Path(output_dir).exists():
            return {"files": [], "output_dir": output_dir, "message": "Répertoire de sortie non trouvé"}

        output_path = Path(output_dir)
        files = []

        # Parcourir tous les fichiers récursivement
        for file_path in output_path.rglob("*"):
            if file_path.is_file():
                # Déterminer le type de fichier
                suffix = file_path.suffix.lower()
                file_type = "other"
                icon = "📄"

                if suffix in ['.tsv', '.csv']:
                    file_type = "data"
                    icon = "📊"
                elif suffix in ['.html', '.htm']:
                    file_type = "report"
                    icon = "📑"
                elif suffix in ['.log', '.txt']:
                    file_type = "log"
                    icon = "📋"
                elif suffix in ['.fasta', '.fna', '.fa', '.faa', '.ffn']:
                    file_type = "sequence"
                    icon = "🧬"
                elif suffix in ['.gff', '.gff3', '.gbk', '.gb']:
                    file_type = "annotation"
                    icon = "📝"
                elif suffix in ['.json']:
                    file_type = "json"
                    icon = "🔧"
                elif suffix in ['.png', '.jpg', '.jpeg', '.svg', '.pdf']:
                    file_type = "image"
                    icon = "🖼️"

                # Chemin relatif depuis output_dir
                relative_path = file_path.relative_to(output_path)

                # Catégorie basée sur le dossier parent
                parts = relative_path.parts
                category = parts[0] if len(parts) > 1 else "root"

                files.append({
                    "name": file_path.name,
                    "path": str(file_path),
                    "relative_path": str(relative_path),
                    "size": file_path.stat().st_size,
                    "size_human": format_size(file_path.stat().st_size),
                    "modified": datetime.fromtimestamp(file_path.stat().st_mtime).isoformat(),
                    "type": file_type,
                    "icon": icon,
                    "category": category,
                    "extension": suffix
                })

        # Trier par catégorie puis par nom
        files.sort(key=lambda x: (x['category'], x['name']))

        # Grouper par catégorie
        categories = {}
        for f in files:
            cat = f['category']
            if cat not in categories:
                categories[cat] = []
            categories[cat].append(f)

        return {
            "output_dir": str(output_path),
            "total_files": len(files),
            "total_size": format_size(sum(f['size'] for f in files)),
            "files": files,
            "categories": categories
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"❌ Erreur listing fichiers job: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erreur lors du listing des fichiers"
        )


@app.get("/api/jobs/{job_id}/files/download/{file_path:path}")
async def download_job_file(job_id: str, file_path: str):
    """
    Télécharge un fichier spécifique d'un job
    """
    from fastapi.responses import FileResponse

    try:
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail=f"Job {job_id} non trouvé")

        output_dir = job.get('output_dir')
        if not output_dir:
            raise HTTPException(status_code=404, detail="Répertoire de sortie non trouvé")

        full_path = Path(output_dir) / file_path

        # Sécurité: vérifier que le chemin est bien dans output_dir
        if not str(full_path.resolve()).startswith(str(Path(output_dir).resolve())):
            raise HTTPException(status_code=403, detail="Accès non autorisé")

        if not full_path.exists():
            raise HTTPException(status_code=404, detail=f"Fichier non trouvé: {file_path}")

        return FileResponse(
            path=str(full_path),
            filename=full_path.name,
            media_type="application/octet-stream"
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Erreur téléchargement fichier: {e}")
        raise HTTPException(status_code=500, detail="Erreur lors du téléchargement du fichier")


@app.get("/api/jobs/{job_id}/files/view/{file_path:path}")
async def view_job_file(job_id: str, file_path: str, lines: int = 500):
    """
    Affiche le contenu d'un fichier texte d'un job
    """
    try:
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail=f"Job {job_id} non trouvé")

        output_dir = job.get('output_dir')
        if not output_dir:
            raise HTTPException(status_code=404, detail="Répertoire de sortie non trouvé")

        full_path = Path(output_dir) / file_path

        # Sécurité
        if not str(full_path.resolve()).startswith(str(Path(output_dir).resolve())):
            raise HTTPException(status_code=403, detail="Accès non autorisé")

        if not full_path.exists():
            raise HTTPException(status_code=404, detail=f"Fichier non trouvé: {file_path}")

        # Vérifier taille
        size = full_path.stat().st_size
        if size > 10 * 1024 * 1024:  # 10 MB max
            return {
                "error": "Fichier trop volumineux pour affichage",
                "size": format_size(size),
                "path": str(full_path)
            }

        # Lire le contenu
        try:
            content = full_path.read_text(encoding='utf-8', errors='ignore')
            content_lines = content.split('\n')

            return {
                "name": full_path.name,
                "path": str(full_path),
                "size": format_size(size),
                "total_lines": len(content_lines),
                "lines_returned": min(lines, len(content_lines)),
                "content": '\n'.join(content_lines[:lines]),
                "truncated": len(content_lines) > lines
            }
        except Exception as e:
            return {
                "error": f"Impossible de lire le fichier: {e}",
                "path": str(full_path)
            }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Erreur affichage fichier: {e}")
        raise HTTPException(status_code=500, detail="Erreur lors de l'affichage du fichier")


@app.get("/api/jobs/{job_id}/files/serve/{file_path:path}")
async def serve_job_file(job_id: str, file_path: str):
    """
    Sert un fichier directement (HTML, images, etc.) pour affichage dans le navigateur
    """
    from fastapi.responses import FileResponse
    import mimetypes

    try:
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail=f"Job {job_id} non trouvé")

        output_dir = job.get('output_dir')
        if not output_dir:
            raise HTTPException(status_code=404, detail="Répertoire de sortie non trouvé")

        full_path = Path(output_dir) / file_path

        # Sécurité : vérifier que le chemin est bien dans le répertoire de sortie
        if not str(full_path.resolve()).startswith(str(Path(output_dir).resolve())):
            raise HTTPException(status_code=403, detail="Accès non autorisé")

        if not full_path.exists():
            raise HTTPException(status_code=404, detail=f"Fichier non trouvé: {file_path}")

        # Déterminer le type MIME
        mime_type, _ = mimetypes.guess_type(str(full_path))
        if mime_type is None:
            mime_type = "application/octet-stream"

        # Pour les fichiers HTML, servir avec le bon content-type
        return FileResponse(
            path=full_path,
            media_type=mime_type,
            filename=full_path.name
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Erreur service fichier: {e}")
        raise HTTPException(status_code=500, detail="Erreur lors du service du fichier")


# ============================================================================
# GESTION DES BASES DE DONNÉES
# ============================================================================

def _validate_db_key(db_key: str) -> str:
    """Valide et retourne la clé de base de données"""
    if not re_module.match(r'^[a-z0-9_]+$', db_key):
        raise HTTPException(status_code=400, detail="Clé de base invalide")
    if db_key not in DATABASES_CONFIG:
        raise HTTPException(status_code=404, detail=f"Base '{db_key}' non trouvée")
    return db_key


DATABASES_DIR = PIPELINE_DIR / "databases"

def _mamba_wrap(cmd: str, env: str = None) -> str:
    """Wrap une commande avec mamba run si un env spécifique est requis.
    Dans Docker, l'env megam_arg est déjà activé par l'entrypoint."""
    if env:
        return f"mamba run --no-banner -n {env} {cmd}"
    return cmd

# Configuration des bases de données
DATABASES_CONFIG = {
    "amrfinder": {
        "name": "AMRFinderPlus",
        "description": "Détection ARG (NCBI)",
        "path": "amrfinder_db",
        "check_files": ["AMRProt", "AMR.LIB"],
        "size_estimate": "~200 MB",
        "update_cmd": "amrfinder_update --force_update --database {path}"
    },
    "card": {
        "name": "CARD",
        "description": "Comprehensive Antibiotic Resistance Database",
        "path": "card_db",
        "check_files": ["card.json", "protein_fasta_protein_homolog_model.fasta"],
        "size_estimate": "~1 GB",
        "update_cmd": "download_card_db"
    },
    "pointfinder": {
        "name": "PointFinder",
        "description": "Mutations de résistance",
        "path": "pointfinder_db",
        "check_files": ["config"],
        "size_estimate": "~3 MB",
        "update_cmd": "git clone https://bitbucket.org/genomicepidemiology/pointfinder_db.git {path}"
    },
    "mlst": {
        "name": "MLST",
        "description": "Multi-Locus Sequence Typing",
        "path": "mlst_db",
        "check_files": ["pubmlst"],
        "size_estimate": "~200 MB",
        "update_cmd": "download_mlst_db"
    },
    "kma": {
        "name": "KMA/ResFinder",
        "description": "Index KMA pour ResFinder",
        "path": "kma_db",
        "check_files": ["resfinder.name"],
        "size_estimate": "~60 MB",
        "update_cmd": "setup_kma_database"
    }
}

# Suivi des téléchargements en cours
db_download_tasks = {}  # {db_key: {active, status, progress, message, ...}}
db_download_lock = threading.Lock()


def _update_download_progress(db_key: str, **kwargs):
    """Met à jour la progression d'un téléchargement"""
    with db_download_lock:
        if db_key in db_download_tasks:
            db_download_tasks[db_key].update(kwargs)


def _run_db_download(db_key: str):
    """Exécute le téléchargement d'une base de données en arrière-plan"""
    config = DATABASES_CONFIG[db_key]
    db_path = DATABASES_DIR / config["path"]
    db_path.mkdir(parents=True, exist_ok=True)

    logger.info(f"[DB Download] Début téléchargement: {db_key}")

    try:
        if db_key == "amrfinder":
            cmd = f"amrfinder_update --force_update --database {db_path}"
            fallback = f"amrfinder --force_update --database {db_path}"
            _download_with_command(db_key, f"bash -c '{cmd}'",
                                   fallback_cmd=f"bash -c '{fallback}'",
                                   timeout=1800)

        elif db_key == "pointfinder":
            _update_download_progress(db_key, message="Suppression ancienne version...", progress=-1)
            if db_path.exists():
                shutil.rmtree(db_path)
            _download_with_command(db_key,
                                   ["git", "clone", "https://bitbucket.org/genomicepidemiology/pointfinder_db.git", str(db_path)],
                                   timeout=600, use_shell=False)

        elif db_key == "card":
            _download_with_wget(db_key, "https://card.mcmaster.ca/latest/data",
                                db_path, "card-data.tar.bz2", extract_cmd="tar -xjf")

        elif db_key == "mlst":
            cmd = "mlst --update 2>&1 || echo 'MLST update done'"
            _download_with_command(db_key, f"bash -c '{cmd}'", timeout=1800)

        elif db_key == "kma":
            _download_kma_database(db_key, db_path)

        # Vérifier résultat final
        new_status = get_db_status(db_key)
        success = new_status["ready"]

        _update_download_progress(
            db_key,
            active=True,
            status="completed" if success else "failed",
            progress=100 if success else 0,
            message=f"{'Terminé avec succès' if success else 'Échec - fichiers manquants'}",
        )
        logger.info(f"[DB Download] {db_key} terminé: {'succès' if success else 'échec'}")

    except Exception as e:
        logger.error(f"[DB Download] Erreur {db_key}: {e}")
        _update_download_progress(
            db_key,
            active=True,
            status="failed",
            progress=0,
            message=f"Erreur: {str(e)[:200]}",
            error=str(e)[:500],
        )

    # Garder le statut final visible pendant 30s puis nettoyer
    time.sleep(30)
    with db_download_lock:
        db_download_tasks.pop(db_key, None)


def _download_with_wget(db_key: str, url: str, db_path: Path, archive_name: str, extract_cmd: str):
    """Téléchargement avec wget et suivi de progression via taille du fichier"""
    archive_path = db_path / archive_name

    # Étape 1: Obtenir la taille totale via HEAD request
    _update_download_progress(db_key, message="Récupération des informations...", progress=0)
    total_bytes = 0
    try:
        import urllib.request
        req = urllib.request.Request(url, method='HEAD')
        with urllib.request.urlopen(req, timeout=30) as resp:
            total_bytes = int(resp.headers.get('Content-Length', 0))
        if total_bytes:
            logger.info(f"[DB Download] {db_key}: taille totale = {format_size(total_bytes)}")
    except Exception as e:
        logger.warning(f"[DB Download] {db_key}: impossible d'obtenir la taille: {e}")

    _update_download_progress(
        db_key,
        status="downloading",
        message="Téléchargement en cours...",
        total_bytes=total_bytes,
        downloaded_bytes=0,
    )

    # Étape 2: Lancer wget
    process = subprocess.Popen(
        ["wget", "-O", archive_name, url],
        cwd=str(db_path), stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )

    # Étape 3: Monitorer la taille du fichier pendant le téléchargement
    last_size = 0
    last_time = time.time()
    while process.poll() is None:
        time.sleep(1)
        try:
            if archive_path.exists():
                current_size = archive_path.stat().st_size
                now = time.time()
                elapsed = now - last_time
                speed = (current_size - last_size) / elapsed if elapsed > 0 else 0
                progress = int((current_size / total_bytes) * 100) if total_bytes > 0 else -1

                _update_download_progress(
                    db_key,
                    progress=min(progress, 99) if progress >= 0 else -1,
                    downloaded_bytes=current_size,
                    speed=format_size(int(speed)) + "/s" if speed > 0 else "",
                    message=f"Téléchargement: {format_size(current_size)}" +
                            (f" / {format_size(total_bytes)}" if total_bytes > 0 else ""),
                )
                last_size = current_size
                last_time = now
        except Exception:
            pass

    # Vérifier le résultat wget
    if process.returncode != 0:
        stderr = process.stderr.read().decode(errors="replace")[-500:]
        raise Exception(f"wget a échoué (code {process.returncode}): {stderr}")

    # Étape 4: Extraction
    _update_download_progress(
        db_key,
        status="extracting",
        progress=-1,
        message="Extraction de l'archive...",
        speed="",
    )
    logger.info(f"[DB Download] {db_key}: extraction en cours...")
    extract_parts = extract_cmd.split() + [archive_name]
    extract_result = subprocess.run(
        extract_parts,
        cwd=str(db_path), capture_output=True, text=True, timeout=1800
    )
    if extract_result.returncode != 0:
        raise Exception(f"Extraction échouée: {extract_result.stderr[:300]}")

    # Étape 5: Nettoyage
    _update_download_progress(db_key, message="Nettoyage...", progress=95)
    try:
        archive_path.unlink(missing_ok=True)
    except Exception:
        pass


def _download_kma_database(db_key: str, db_path: Path):
    """Crée les index KMA à partir des bases abricate (resfinder, card, ncbi)"""
    _update_download_progress(db_key, status="downloading", progress=-1,
                              message="Recherche des bases abricate...", speed="")

    # Trouver le répertoire des bases abricate via mamba run
    abricate_db_dir = None
    try:
        result = subprocess.run(
            ["mamba", "run", "--no-banner", "-n", "abricate_env", "abricate", "--datadir"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            candidate = Path(result.stdout.strip())
            if candidate.is_dir():
                abricate_db_dir = candidate
                logger.info(f"[DB Download] kma: abricate trouvé dans abricate_env")
    except Exception as e:
        logger.warning(f"[DB Download] kma: abricate --datadir failed: {e}")

    if not abricate_db_dir:
        raise Exception("Bases abricate non trouvées dans l'image Docker. Vérifiez que l'env abricate_env est bien installé.")

    logger.info(f"[DB Download] kma: bases abricate trouvées: {abricate_db_dir}")
    db_path.mkdir(parents=True, exist_ok=True)

    # Créer les index KMA pour chaque base
    databases_to_index = ["resfinder", "card", "ncbi"]
    for i, db_name in enumerate(databases_to_index):
        seq_file = abricate_db_dir / db_name / "sequences"
        if not seq_file.exists():
            logger.warning(f"[DB Download] kma: séquences non trouvées: {seq_file}")
            continue

        progress_pct = int((i / len(databases_to_index)) * 80)
        _update_download_progress(db_key, progress=progress_pct,
                                  message=f"Indexation KMA: {db_name}... ({i+1}/{len(databases_to_index)})")

        kma_cmd = f"kma index -i {seq_file} -o {db_path / db_name}"
        result = subprocess.run(
            ["bash", "-c", kma_cmd],
            capture_output=True, text=True, timeout=300
        )
        if result.returncode != 0:
            logger.warning(f"[DB Download] kma index {db_name} failed: {result.stderr[:200]}")
        elif (db_path / f"{db_name}.name").exists():
            logger.info(f"[DB Download] kma: index créé: {db_name}")

    # Vérification finale
    if not (db_path / "resfinder.name").exists():
        raise Exception("Échec création index KMA resfinder")

    _update_download_progress(db_key, progress=90, message="Index KMA créés avec succès")


def _download_with_command(db_key: str, cmd, fallback_cmd=None, timeout: int = 1800, use_shell: bool = True):
    """Exécute une commande de téléchargement avec progression indéterminée.

    Args:
        cmd: Commande (str si use_shell=True, list si use_shell=False)
        fallback_cmd: Commande alternative (même format que cmd)
        timeout: Timeout en secondes
        use_shell: True pour les commandes nécessitant shell, False sinon
    """
    _update_download_progress(
        db_key,
        status="downloading",
        progress=-1,
        message="Installation en cours...",
        speed="",
    )

    process = subprocess.Popen(cmd, shell=use_shell, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    # Monitorer le process avec messages de vie
    start_time = time.time()
    while process.poll() is None:
        time.sleep(2)
        elapsed = int(time.time() - start_time)
        mins, secs = divmod(elapsed, 60)
        _update_download_progress(
            db_key,
            message=f"Installation en cours... ({mins}m{secs:02d}s)",
        )
        if elapsed > timeout:
            process.kill()
            raise Exception(f"Timeout après {timeout}s")

    if process.returncode != 0 and fallback_cmd:
        logger.info(f"[DB Download] {db_key}: commande principale échouée, essai fallback...")
        _update_download_progress(db_key, message="Essai méthode alternative...")
        process = subprocess.Popen(fallback_cmd, shell=use_shell, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        start_time = time.time()
        while process.poll() is None:
            time.sleep(2)
            elapsed = int(time.time() - start_time)
            mins, secs = divmod(elapsed, 60)
            _update_download_progress(
                db_key,
                message=f"Méthode alternative... ({mins}m{secs:02d}s)",
            )
            if elapsed > timeout:
                process.kill()
                raise Exception(f"Timeout après {timeout}s")

    if process.returncode != 0:
        stderr = process.stderr.read().decode(errors="replace")[-500:]
        raise Exception(f"Commande échouée (code {process.returncode}): {stderr}")


def get_db_status(db_key: str) -> dict:
    """Vérifie le statut d'une base de données"""
    config = DATABASES_CONFIG.get(db_key)
    if not config:
        return None

    db_path = DATABASES_DIR / config["path"]

    # Vérifier si le dossier existe
    exists = db_path.exists()

    # Vérifier si les fichiers requis sont présents
    ready = False
    if exists:
        for check_file in config["check_files"]:
            # Chercher le fichier (peut être dans un sous-dossier)
            found = list(db_path.rglob(check_file))
            if found:
                ready = True
                break

    # Calculer la taille
    size = 0
    if exists:
        try:
            for f in db_path.rglob("*"):
                if f.is_file():
                    size += f.stat().st_size
        except OSError:
            pass

    # Date de dernière modification
    last_updated = None
    if exists:
        try:
            last_updated = datetime.fromtimestamp(db_path.stat().st_mtime).isoformat()
        except OSError:
            pass

    return {
        "key": db_key,
        "name": config["name"],
        "description": config["description"],
        "path": str(db_path),
        "exists": exists,
        "ready": ready,
        "size_bytes": size,
        "size_human": format_size(size),
        "size_estimate": config["size_estimate"],
        "last_updated": last_updated
    }


def format_size(size_bytes: int) -> str:
    """Formate une taille en bytes en format lisible"""
    if size_bytes == 0:
        return "0 B"
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


@app.get("/api/databases")
async def list_databases():
    """Liste toutes les bases de données avec leur statut"""
    databases = []
    for db_key in DATABASES_CONFIG:
        status = get_db_status(db_key)
        if status:
            databases.append(status)

    return {
        "databases_dir": str(DATABASES_DIR),
        "databases": databases
    }


@app.get("/api/databases/{db_key}")
async def get_database_status(db_key: str):
    """Récupère le statut d'une base de données spécifique"""
    _validate_db_key(db_key)
    db_status = get_db_status(db_key)
    if not db_status:
        raise HTTPException(
            status_code=404,
            detail=f"Base de données '{db_key}' non trouvée"
        )
    return db_status


@app.post("/api/databases/{db_key}/update")
async def update_database(db_key: str):
    """
    Lance la mise à jour/téléchargement d'une base de données en arrière-plan.
    Retourne immédiatement. Utiliser GET /api/databases/{db_key}/progress pour suivre.
    """
    _validate_db_key(db_key)
    if db_key not in DATABASES_CONFIG:
        raise HTTPException(
            status_code=404,
            detail=f"Base de données '{db_key}' non trouvée"
        )

    # Vérifier si un téléchargement est déjà en cours
    with db_download_lock:
        if db_key in db_download_tasks and db_download_tasks[db_key].get("active"):
            current = db_download_tasks[db_key]
            if current.get("status") not in ("completed", "failed"):
                raise HTTPException(
                    status_code=409,
                    detail=f"Téléchargement déjà en cours pour '{db_key}'"
                )

    config = DATABASES_CONFIG[db_key]

    # Initialiser le tracking
    with db_download_lock:
        db_download_tasks[db_key] = {
            "active": True,
            "status": "starting",
            "progress": 0,
            "message": "Démarrage...",
            "downloaded_bytes": 0,
            "total_bytes": 0,
            "speed": "",
            "started_at": datetime.now().isoformat(),
            "error": None,
        }

    # Lancer en arrière-plan
    thread = threading.Thread(target=_run_db_download, args=(db_key,), daemon=True)
    thread.start()

    logger.info(f"[DB Download] Téléchargement lancé en arrière-plan: {db_key}")

    return {
        "started": True,
        "message": f"Téléchargement de {config['name']} lancé en arrière-plan",
        "db_key": db_key,
    }


@app.get("/api/databases/{db_key}/progress")
async def get_db_download_progress(db_key: str):
    """Retourne la progression du téléchargement d'une base de données"""
    _validate_db_key(db_key)
    with db_download_lock:
        if db_key in db_download_tasks:
            return dict(db_download_tasks[db_key])
    return {"active": False}


# ============================================================================
# SUPPRESSION DES FICHIERS DE JOBS
# ============================================================================

@app.delete("/api/jobs/{job_id}/files")
async def delete_job_files(job_id: str, delete_outputs: bool = True, delete_data: bool = False):
    """
    Supprime les fichiers associés à un job

    Args:
        job_id: ID du job
        delete_outputs: Supprimer les résultats (défaut: True)
        delete_data: Supprimer les données téléchargées SRA/Assembly (défaut: False)
    """
    try:
        job = await db.get_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail=f"Job {job_id} non trouvé")

        deleted = []
        errors = []

        # Supprimer les outputs
        if delete_outputs and job.get('output_dir'):
            output_path = Path(job['output_dir'])
            if output_path.exists():
                try:
                    shutil.rmtree(output_path)
                    deleted.append(f"Outputs: {output_path}")
                    logger.info(f"🗑️ Supprimé outputs: {output_path}")
                except Exception as e:
                    errors.append(f"Erreur suppression outputs: {e}")

        # Supprimer les données téléchargées (SRA/Assembly)
        if delete_data:
            sample_id = job['sample_id']
            data_dir = PIPELINE_DIR / "data"

            # Chercher les fichiers liés à cet échantillon
            patterns = [
                f"{sample_id}*",
                f"*{sample_id}*"
            ]

            for pattern in patterns:
                for f in data_dir.glob(pattern):
                    try:
                        if f.is_dir():
                            shutil.rmtree(f)
                        else:
                            f.unlink()
                        deleted.append(f"Data: {f}")
                        logger.info(f"🗑️ Supprimé data: {f}")
                    except Exception as e:
                        errors.append(f"Erreur suppression {f}: {e}")

        return {
            "message": f"Fichiers du job {job_id} supprimés",
            "deleted": deleted,
            "errors": errors if errors else None
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Erreur suppression fichiers job {job_id}: {e}")
        raise HTTPException(status_code=500, detail="Erreur lors de la suppression des fichiers")


@app.delete("/api/outputs/{sample_id}")
async def delete_sample_outputs(sample_id: str):
    """Supprime tous les outputs d'un échantillon (tous les runs)"""
    outputs_dir = PIPELINE_DIR / "outputs"
    deleted = []

    for d in outputs_dir.glob(f"{sample_id}*"):
        if d.is_dir():
            try:
                shutil.rmtree(d)
                deleted.append(str(d))
                logger.info(f"🗑️ Supprimé: {d}")
            except Exception as e:
                logger.error(f"Erreur suppression {d}: {e}")

    return {
        "message": f"Outputs de {sample_id} supprimés",
        "deleted": deleted
    }


# ============================================================================
# MAIN (pour lancement direct)
# ============================================================================

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )
