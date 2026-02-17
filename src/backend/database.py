"""
Gestion de la base de données SQLite pour tracker les jobs
"""
import sqlite3
import aiosqlite
from typing import Optional, List, Dict, Any
from datetime import datetime
from pathlib import Path
import uuid

from models import JobStatus, InputType, ProkkaMode


class Database:
    """Gestionnaire de base de données SQLite"""

    def __init__(self, db_path: str = "jobs.db"):
        self.db_path = db_path
        self._initialized = False

    async def initialize(self):
        """Initialise la base de données (crée tables si nécessaire)"""
        if self._initialized:
            return

        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("""
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    sample_id TEXT NOT NULL,
                    input_type TEXT,
                    status TEXT NOT NULL,
                    run_number INTEGER,
                    output_dir TEXT,
                    pid INTEGER,
                    threads INTEGER DEFAULT 8,
                    prokka_mode TEXT DEFAULT 'auto',
                    prokka_genus TEXT,
                    prokka_species TEXT,
                    created_at TIMESTAMP NOT NULL,
                    started_at TIMESTAMP,
                    completed_at TIMESTAMP,
                    exit_code INTEGER,
                    error_message TEXT
                )
            """)

            # Index pour recherches fréquentes
            await db.execute("""
                CREATE INDEX IF NOT EXISTS idx_sample_id ON jobs(sample_id)
            """)
            await db.execute("""
                CREATE INDEX IF NOT EXISTS idx_status ON jobs(status)
            """)
            await db.execute("""
                CREATE INDEX IF NOT EXISTS idx_created_at ON jobs(created_at DESC)
            """)

            await db.commit()

        self._initialized = True

    async def create_job(
        self,
        sample_id: str,
        threads: int = 8,
        prokka_mode: str = "auto",
        prokka_genus: Optional[str] = None,
        prokka_species: Optional[str] = None
    ) -> str:
        """
        Crée un nouveau job dans la base de données

        Returns:
            job_id (str): UUID du job créé
        """
        job_id = str(uuid.uuid4())
        now = datetime.now()

        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("""
                INSERT INTO jobs (
                    id, sample_id, status, threads, prokka_mode,
                    prokka_genus, prokka_species, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                job_id,
                sample_id,
                JobStatus.PENDING.value,
                threads,
                prokka_mode,
                prokka_genus,
                prokka_species,
                now
            ))
            await db.commit()

        return job_id

    async def get_job(self, job_id: str) -> Optional[Dict[str, Any]]:
        """Récupère un job par son ID"""
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM jobs WHERE id = ?",
                (job_id,)
            ) as cursor:
                row = await cursor.fetchone()
                if row:
                    return dict(row)
                return None

    async def update_job_status(
        self,
        job_id: str,
        status: JobStatus,
        **kwargs
    ) -> bool:
        """
        Met à jour le statut d'un job

        Args:
            job_id: ID du job
            status: Nouveau statut
            **kwargs: Autres champs à mettre à jour (started_at, completed_at, exit_code, etc.)

        Returns:
            bool: True si mise à jour réussie
        """
        # Construire la requête dynamiquement
        fields = ["status = ?"]
        values = [status.value]

        for key, value in kwargs.items():
            if key in ["started_at", "completed_at", "exit_code", "error_message",
                      "pid", "output_dir", "input_type", "run_number"]:
                fields.append(f"{key} = ?")
                values.append(value)

        values.append(job_id)

        query = f"UPDATE jobs SET {', '.join(fields)} WHERE id = ?"

        async with aiosqlite.connect(self.db_path) as db:
            cursor = await db.execute(query, values)
            await db.commit()
            return cursor.rowcount > 0

    async def get_jobs(
        self,
        status: Optional[JobStatus] = None,
        limit: int = 100,
        offset: int = 0
    ) -> List[Dict[str, Any]]:
        """
        Liste les jobs avec filtres optionnels

        Args:
            status: Filtrer par statut (optionnel)
            limit: Nombre maximum de résultats
            offset: Offset pour pagination

        Returns:
            Liste de dictionnaires représentant les jobs
        """
        query = "SELECT * FROM jobs"
        params = []

        if status:
            query += " WHERE status = ?"
            params.append(status.value)

        query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(query, params) as cursor:
                rows = await cursor.fetchall()
                return [dict(row) for row in rows]

    async def count_jobs(self, status: Optional[JobStatus] = None) -> int:
        """Compte le nombre de jobs (avec filtre optionnel)"""
        query = "SELECT COUNT(*) as count FROM jobs"
        params = []

        if status:
            query += " WHERE status = ?"
            params.append(status.value)

        async with aiosqlite.connect(self.db_path) as db:
            async with db.execute(query, params) as cursor:
                row = await cursor.fetchone()
                return row[0] if row else 0

    async def get_max_run_number(self, sample_id: str) -> int:
        """
        Récupère le numéro de run maximum pour un sample_id donné

        Returns:
            int: Numéro de run maximum (0 si aucun run existant)
        """
        async with aiosqlite.connect(self.db_path) as db:
            async with db.execute(
                "SELECT MAX(run_number) as max_run FROM jobs WHERE sample_id = ?",
                (sample_id,)
            ) as cursor:
                row = await cursor.fetchone()
                return row[0] if row and row[0] is not None else 0

    async def get_running_jobs_count(self) -> int:
        """Compte le nombre de jobs en cours d'exécution"""
        return await self.count_jobs(status=JobStatus.RUNNING)

    async def cleanup_stale_jobs(self, max_age_hours: int = 24):
        """
        Marque comme FAILED les jobs RUNNING depuis plus de max_age_hours

        Utile pour nettoyer les jobs "zombies" (serveur crashé, etc.)
        """
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("""
                UPDATE jobs
                SET status = ?, error_message = 'Job timeout - probablement interrompu'
                WHERE status = ?
                AND started_at IS NOT NULL
                AND started_at < datetime('now', '-' || ? || ' hours')
            """, (JobStatus.FAILED.value, JobStatus.RUNNING.value, max_age_hours))
            await db.commit()

    async def delete_job(self, job_id: str):
        """
        Supprime un job spécifique

        Args:
            job_id: ID du job à supprimer
        """
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("DELETE FROM jobs WHERE id = ?", (job_id,))
            await db.commit()

    async def delete_all_jobs(self) -> int:
        """
        Supprime TOUS les jobs

        Returns:
            int: Nombre de jobs supprimés
        """
        async with aiosqlite.connect(self.db_path) as db:
            # Compter d'abord
            async with db.execute("SELECT COUNT(*) FROM jobs") as cursor:
                row = await cursor.fetchone()
                count = row[0] if row else 0

            # Supprimer tout
            await db.execute("DELETE FROM jobs")
            await db.commit()

            return count


# Instance globale (singleton)
db = Database()
