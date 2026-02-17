"""
Wrapper pour lancer et monitorer le pipeline bash ARG
Version Docker — pas de gestion conda/mamba (géré par l'image Docker)
"""
import asyncio
import os
import signal
import shlex
from typing import Optional, Dict, Any, Callable
from pathlib import Path
import logging

from models import JobStatus, InputType

logger = logging.getLogger(__name__)


class PipelineLauncher:
    """Gestionnaire de lancement et monitoring du pipeline bash"""

    def __init__(
        self,
        pipeline_script: str,
        work_dir: str
    ):
        """
        Args:
            pipeline_script: Chemin vers le script pipeline Docker
            work_dir: Répertoire de travail du pipeline (contient outputs/, data/, etc.)
        """
        self.pipeline_script = Path(pipeline_script)
        self.work_dir = Path(work_dir)

        if not self.pipeline_script.exists():
            raise FileNotFoundError(f"Pipeline script non trouvé: {pipeline_script}")

    def detect_input_type(self, sample_id: str) -> InputType:
        """
        Détecte automatiquement le type d'input basé sur le pattern

        Args:
            sample_id: Identifiant ou chemin fichier

        Returns:
            InputType correspondant
        """
        import re

        # SRA
        if re.match(r'^[SED]RR[0-9]+', sample_id):
            return InputType.SRA

        # GenBank
        if re.match(r'^(CP|NC_|NZ_)[0-9]+', sample_id):
            return InputType.GENBANK

        # NCBI Assembly
        if re.match(r'^GC[AF]_[0-9]+', sample_id):
            return InputType.ASSEMBLY

        # Fichier local
        if sample_id.endswith(('.fasta', '.fna', '.fa')) or '/' in sample_id:
            return InputType.LOCAL_FASTA

        # Par défaut, considérer comme SRA
        return InputType.SRA

    def get_next_run_number(self, sample_id: str) -> int:
        """
        Détermine le prochain numéro de run pour un sample_id

        Scanne le répertoire outputs/ pour trouver les runs existants
        au format exact {sample_id}_{entier} et retourne max+1.
        Les anciens formats (ex: SRR_v3.2_20260128_124016) sont ignorés.

        IMPORTANT: Cet algorithme doit rester synchronisé avec
        get_next_run_number() dans le script bash du pipeline.

        Args:
            sample_id: Identifiant de l'échantillon

        Returns:
            int: Prochain numéro de run (1, 2, 3...)
        """
        import re

        outputs_dir = self.work_dir / "outputs"
        if not outputs_dir.exists():
            return 1

        # Pattern exact: {sample_id}_{entier} (rien d'autre)
        pattern = re.compile(rf'^{re.escape(sample_id)}_(\d+)$')

        existing_runs = []
        for entry in outputs_dir.iterdir():
            if entry.is_dir():
                match = pattern.match(entry.name)
                if match:
                    existing_runs.append(int(match.group(1)))

        # Retourner le numéro suivant
        return max(existing_runs, default=0) + 1

    def build_command(
        self,
        sample_id: str,
        threads: int = 8,
        prokka_mode: str = "auto",
        prokka_genus: Optional[str] = None,
        prokka_species: Optional[str] = None,
        force: bool = True
    ) -> str:
        """
        Construit la commande bash complète pour lancer le pipeline

        Args:
            sample_id: Identifiant échantillon
            threads: Nombre de threads
            prokka_mode: Mode Prokka
            prokka_genus: Genre (si mode custom)
            prokka_species: Espèce (si mode custom)
            force: Mode non-interactif

        Returns:
            str: Commande bash complète
        """
        # Commande de base avec échappement des arguments utilisateur
        cmd_parts = [
            f"bash {shlex.quote(str(self.pipeline_script))}",
            shlex.quote(sample_id),
            f"--threads {int(threads)}",
            f"--prokka-mode {shlex.quote(prokka_mode)}"
        ]

        # Arguments optionnels
        if prokka_mode == "custom":
            if prokka_genus:
                cmd_parts.append(f"--prokka-genus {shlex.quote(prokka_genus)}")
            if prokka_species:
                cmd_parts.append(f"--prokka-species {shlex.quote(prokka_species)}")

        if force:
            cmd_parts.append("--force")

        cmd = " ".join(cmd_parts)

        return cmd

    async def launch(
        self,
        sample_id: str,
        threads: int = 8,
        prokka_mode: str = "auto",
        prokka_genus: Optional[str] = None,
        prokka_species: Optional[str] = None,
        force: bool = True,
        on_complete: Optional[Callable] = None
    ) -> Dict[str, Any]:
        """
        Lance le pipeline de manière asynchrone

        Args:
            sample_id: Identifiant échantillon
            threads: Nombre de threads
            prokka_mode: Mode Prokka
            prokka_genus: Genre (si custom)
            prokka_species: Espèce (si custom)
            force: Mode non-interactif
            on_complete: Callback optionnel appelé à la fin (async function)

        Returns:
            Dict contenant:
                - process: subprocess.Popen object
                - pid: Process ID
                - command: Commande lancée
                - input_type: Type d'input détecté
                - run_number: Numéro de run
        """
        # Détecter type d'input et run number
        input_type = self.detect_input_type(sample_id)
        run_number = self.get_next_run_number(sample_id)

        # Construire commande
        command = self.build_command(
            sample_id=sample_id,
            threads=threads,
            prokka_mode=prokka_mode,
            prokka_genus=prokka_genus,
            prokka_species=prokka_species,
            force=force
        )

        logger.info(f"Lancement pipeline pour {sample_id} (run {run_number})")
        logger.debug(f"Commande: {command}")

        # Lancer le processus avec bash explicitement
        # IMPORTANT: Ne pas capturer stdout/stderr (PIPE) car ça peut bloquer le pipeline
        # Le pipeline écrit déjà ses logs dans des fichiers
        process = await asyncio.create_subprocess_exec(
            "/bin/bash", "-c", command,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            cwd=str(self.work_dir),
            preexec_fn=os.setsid  # Créer un nouveau group pour pouvoir tuer tous les sous-processus
        )

        # Lancer monitoring en arrière-plan si callback fourni
        if on_complete:
            asyncio.create_task(self._monitor_completion(process, on_complete))

        return {
            "process": process,
            "pid": process.pid,
            "command": command,
            "input_type": input_type.value,
            "run_number": run_number,
            "output_dir": str(self.work_dir / "outputs" / f"{sample_id}_{run_number}")
        }

    async def _monitor_completion(
        self,
        process: asyncio.subprocess.Process,
        callback: Callable
    ):
        """
        Monitore la complétion d'un processus et appelle le callback

        Args:
            process: Processus à monitorer
            callback: Fonction async à appeler avec (exit_code, stdout, stderr)
        """
        try:
            # Attendre la fin du processus (pas de stdout/stderr car redirigés vers DEVNULL)
            await process.wait()
            exit_code = process.returncode

            # Appeler le callback
            await callback(
                exit_code=exit_code,
                stdout="",  # Pas de capture stdout (voir logs fichiers)
                stderr=""   # Pas de capture stderr (voir logs fichiers)
            )

        except Exception as e:
            logger.error(f"Erreur monitoring processus: {e}")

    def get_log_file(self, sample_id: str, run_number: int) -> Optional[Path]:
        """
        Trouve le fichier log le plus récent pour un job

        Args:
            sample_id: Identifiant échantillon
            run_number: Numéro de run

        Returns:
            Path vers le fichier log ou None si non trouvé
        """
        output_dir = self.work_dir / "outputs" / f"{sample_id}_{run_number}"
        logs_dir = output_dir / "logs"

        if not logs_dir.exists():
            return None

        # Chercher fichier pipeline_*.log le plus récent
        log_files = list(logs_dir.glob("pipeline_*.log"))
        if not log_files:
            return None

        # Retourner le plus récent
        return max(log_files, key=lambda p: p.stat().st_mtime)

    async def get_log_tail(
        self,
        sample_id: str,
        run_number: int,
        lines: int = 50
    ) -> Optional[str]:
        """
        Récupère les dernières lignes du log

        Args:
            sample_id: Identifiant échantillon
            run_number: Numéro de run
            lines: Nombre de lignes à récupérer

        Returns:
            str: Dernières lignes du log ou None
        """
        log_file = self.get_log_file(sample_id, run_number)
        if not log_file or not log_file.exists():
            return None

        try:
            # Lire les dernières lignes
            proc = await asyncio.create_subprocess_exec(
                "tail", f"-n{lines}", str(log_file),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()
            return stdout.decode('utf-8', errors='ignore')

        except Exception as e:
            logger.error(f"Erreur lecture log: {e}")
            return None

    async def estimate_progress(
        self,
        sample_id: str,
        run_number: int,
        input_type: InputType
    ) -> Optional[int]:
        """
        Estime la progression du pipeline en parsant les logs

        Args:
            sample_id: Identifiant échantillon
            run_number: Numéro de run
            input_type: Type d'input (pour savoir quels modules sont exécutés)

        Returns:
            int: Progression estimée en % (0-100) ou None
        """
        log_file = self.get_log_file(sample_id, run_number)
        if not log_file or not log_file.exists():
            return 0

        try:
            # Lire le log complet
            async with asyncio.Lock():
                content = log_file.read_text(encoding='utf-8', errors='ignore')

            # Modules à détecter (ordre chronologique)
            if input_type == InputType.SRA:
                modules = [
                    ("Téléchargement SRA", 10),
                    ("Contrôle qualité", 20),
                    ("Assemblage", 40),
                    ("Annotation", 60),
                    ("Détection ARG", 80),
                    ("Rapports", 90),
                    ("TERMINÉ AVEC SUCCÈS", 100)
                ]
            else:
                # GenBank/Assembly (skip QC et assemblage)
                modules = [
                    ("Annotation", 30),
                    ("Détection ARG", 60),
                    ("Rapports", 85),
                    ("TERMINÉ AVEC SUCCÈS", 100)
                ]

            # Chercher le dernier module complété
            progress = 0
            for module_name, module_progress in modules:
                if module_name.lower() in content.lower():
                    progress = module_progress

            return progress

        except Exception as e:
            logger.error(f"Erreur estimation progression: {e}")
            return None

    async def kill_job(self, pid: int) -> bool:
        """
        Tue un job en cours d'exécution

        Args:
            pid: Process ID

        Returns:
            bool: True si tué avec succès
        """
        try:
            # Tuer le groupe de processus complet (pipeline lance plein de sous-processus)
            os.killpg(os.getpgid(pid), signal.SIGTERM)
            logger.info(f"Job PID {pid} tué")
            return True

        except ProcessLookupError:
            logger.warning(f"Processus {pid} déjà terminé")
            return False

        except Exception as e:
            logger.error(f"Erreur kill job {pid}: {e}")
            return False
