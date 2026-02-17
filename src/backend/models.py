"""
Modèles de données pour l'API Pipeline ARG
"""
from pydantic import BaseModel, Field, field_validator
from typing import Optional, List, Dict, Any
from datetime import datetime
from enum import Enum
import re


class JobStatus(str, Enum):
    """Status possibles d'un job"""
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"


class InputType(str, Enum):
    """Types d'entrées acceptés par le pipeline"""
    SRA = "sra"              # SRR*, ERR*, DRR*
    GENBANK = "genbank"      # CP*, NC*, NZ*
    ASSEMBLY = "assembly"    # GCA_*, GCF_*
    LOCAL_FASTA = "local_fasta"  # Fichier local


class ProkkaMode(str, Enum):
    """Modes d'annotation Prokka"""
    AUTO = "auto"
    GENERIC = "generic"
    ECOLI = "ecoli"
    CUSTOM = "custom"


# ============================================================================
# REQUEST MODELS (Input API)
# ============================================================================

class LaunchAnalysisRequest(BaseModel):
    """Requête pour lancer une nouvelle analyse"""
    sample_id: str = Field(..., description="Identifiant échantillon (SRR*, CP*, GCA*, etc.) ou chemin fichier")
    threads: Optional[int] = Field(8, ge=1, le=64, description="Nombre de threads")
    prokka_mode: Optional[ProkkaMode] = Field(ProkkaMode.AUTO, description="Mode annotation Prokka")
    prokka_genus: Optional[str] = Field(None, description="Genre bactérien (requis si prokka_mode=custom)")
    prokka_species: Optional[str] = Field(None, description="Espèce bactérienne (requis si prokka_mode=custom)")
    force: Optional[bool] = Field(False, description="Mode non-interactif (accepte automatiquement)")

    @field_validator('sample_id')
    @classmethod
    def validate_sample_id(cls, v: str) -> str:
        """Valide le format du sample_id"""
        v = v.strip()
        if not v:
            raise ValueError("sample_id ne peut pas être vide")

        if len(v) > 500:
            raise ValueError("sample_id trop long (max 500 caractères)")

        # Patterns stricts avec fin de chaîne
        sra_pattern = r'^[SED]RR\d{6,}$'
        genbank_pattern = r'^(CP|NC_|NZ_)\d+(\.\d+)?$'
        assembly_pattern = r'^GC[AF]_\d+\.\d+$'

        # Caractères shell dangereux interdits dans les chemins de fichiers
        shell_dangerous = set(';$`|&(){}[]!#~')

        # Accepter les patterns connus ou un chemin de fichier
        if re.match(sra_pattern, v):
            return v
        if re.match(genbank_pattern, v):
            return v
        if re.match(assembly_pattern, v):
            return v

        # Fichier local : vérifier extension et interdire caractères dangereux
        if v.endswith(('.fasta', '.fna', '.fa')):
            if shell_dangerous.intersection(v):
                raise ValueError(
                    "sample_id contient des caractères interdits pour un chemin de fichier"
                )
            return v

        raise ValueError(
            "Format sample_id invalide. "
            "Attendu: SRR*/ERR*/DRR* (SRA), CP*/NC*/NZ* (GenBank), "
            "GCA_*/GCF_* (Assembly) ou fichier .fasta/.fna/.fa"
        )

    @field_validator('prokka_genus')
    @classmethod
    def validate_prokka_genus(cls, v: Optional[str], info) -> Optional[str]:
        """Valide que genus est fourni si mode=custom"""
        if info.data.get('prokka_mode') == ProkkaMode.CUSTOM and not v:
            raise ValueError("prokka_genus requis quand prokka_mode=custom")
        if v is not None:
            if len(v) > 100:
                raise ValueError("prokka_genus trop long (max 100 caractères)")
            if not re.match(r'^[A-Za-z][a-z]+$', v):
                raise ValueError("prokka_genus invalide (lettres uniquement, ex: Escherichia)")
        return v

    @field_validator('prokka_species')
    @classmethod
    def validate_prokka_species(cls, v: Optional[str], info) -> Optional[str]:
        """Valide que species est fourni si mode=custom"""
        if info.data.get('prokka_mode') == ProkkaMode.CUSTOM and not v:
            raise ValueError("prokka_species requis quand prokka_mode=custom")
        if v is not None:
            if len(v) > 100:
                raise ValueError("prokka_species trop long (max 100 caractères)")
            if not re.match(r'^[a-z][a-z_]+$', v):
                raise ValueError("prokka_species invalide (lettres minuscules et _ uniquement, ex: coli)")
        return v


# ============================================================================
# RESPONSE MODELS (Output API)
# ============================================================================

class JobResponse(BaseModel):
    """Réponse après création d'un job"""
    job_id: str
    sample_id: str
    status: JobStatus
    created_at: datetime
    message: str


class JobStatusResponse(BaseModel):
    """Réponse pour le statut d'un job"""
    job_id: str
    sample_id: str
    status: JobStatus
    input_type: Optional[InputType]
    run_number: Optional[int]
    progress: Optional[int] = Field(None, ge=0, le=100, description="Progression estimée (%)")
    current_step: Optional[str] = Field(None, description="Étape actuelle du pipeline")
    created_at: datetime
    started_at: Optional[datetime]
    completed_at: Optional[datetime]
    exit_code: Optional[int]
    error_message: Optional[str]
    logs_preview: Optional[str] = Field(None, description="Aperçu des dernières lignes de log")


class JobListItem(BaseModel):
    """Item de la liste des jobs"""
    job_id: str
    sample_id: str
    status: JobStatus
    input_type: Optional[InputType]
    created_at: datetime
    completed_at: Optional[datetime]


class JobListResponse(BaseModel):
    """Réponse pour la liste des jobs"""
    total: int
    jobs: List[JobListItem]


# ============================================================================
# RESULTS MODELS (Résultats pipeline)
# ============================================================================

class ARGGene(BaseModel):
    """Gène de résistance antimicrobienne ou facteur de virulence détecté"""
    gene: str
    sequence: str
    start: int
    end: int
    strand: str
    coverage: float
    identity: float
    database: str
    accession: str
    product: Optional[str] = None
    resistance: Optional[str] = None
    subclass: Optional[str] = Field(None, description="Sous-classe d'antibiotique (ex: CARBAPENEM)")
    element_type: Optional[str] = Field(None, description="Type: AMR, VIRULENCE, STRESS")
    element_subtype: Optional[str] = Field(None, description="Sous-type de l'élément")
    priority: Optional[str] = Field(None, description="Priorité calculée: CRITICAL, HIGH, MEDIUM")


class AssemblyStats(BaseModel):
    """Statistiques d'assemblage (QUAST)"""
    num_contigs: Optional[int]
    total_length: Optional[int]
    largest_contig: Optional[int]
    n50: Optional[int]
    l50: Optional[int]
    gc_percent: Optional[float]


class DetectionResults(BaseModel):
    """Résultats de détection ARG par outil"""
    tool: str
    num_genes: int
    genes: List[ARGGene]


class DeduplicatedGene(BaseModel):
    """Gène dédupliqué avec sources multiples"""
    gene: str
    sequence: str
    start: int
    end: int
    strand: str
    coverage: float
    identity: float
    database: str
    accession: str
    product: Optional[str] = None
    resistance: Optional[str] = None
    subclass: Optional[str] = Field(None, description="Sous-classe d'antibiotique (ex: CARBAPENEM)")
    element_type: Optional[str] = Field(None, description="Type: AMR, VIRULENCE, STRESS")
    element_subtype: Optional[str] = None
    source: str = Field(..., description="Source principale")
    sources: List[str] = Field(default_factory=list, description="Toutes les sources qui ont détecté ce gène")
    priority: Optional[str] = Field(None, description="Priorité calculée: CRITICAL, HIGH, MEDIUM")


class DeduplicationStats(BaseModel):
    """Statistiques de déduplication"""
    total_raw: int = Field(..., description="Nombre total de gènes avant déduplication")
    total_deduplicated: int = Field(..., description="Nombre de gènes après déduplication")
    duplicates_removed: int = Field(..., description="Nombre de doublons retirés")
    by_type: Dict[str, int] = Field(default_factory=dict, description="Comptage par type (AMR, VIRULENCE, STRESS)")


class AnalysisResults(BaseModel):
    """Résultats complets d'une analyse"""
    job_id: str
    sample_id: str
    run_number: int
    input_type: InputType

    # Statistiques assemblage
    assembly_stats: Optional[AssemblyStats]

    # Résultats détection ARG (bruts par outil)
    arg_detection: Dict[str, DetectionResults] = Field(
        default_factory=dict,
        description="Résultats par outil (resfinder, amrfinderplus, card, etc.)"
    )

    # Résultats dédupliqués (comme le rapport HTML)
    deduplicated_genes: List[DeduplicatedGene] = Field(
        default_factory=list,
        description="Gènes dédupliqués (fusionnés entre outils)"
    )
    deduplication_stats: Optional[DeduplicationStats] = Field(
        None,
        description="Statistiques de déduplication"
    )

    # Résumé
    total_arg_genes: int = Field(0, description="Nombre total de gènes ARG détectés (brut)")
    total_unique_genes: int = Field(0, description="Nombre de gènes uniques (dédupliqués)")
    unique_resistance_types: List[str] = Field(default_factory=list)

    # Informations taxonomiques
    taxonomy: Optional[Dict[str, Any]] = Field(
        None,
        description="Classification taxonomique (espèce, genre, confiance)"
    )
    mlst: Optional[Dict[str, Any]] = Field(
        None,
        description="Typage MLST (schéma, ST, profil allélique)"
    )

    # Fichiers disponibles
    report_html_path: Optional[str] = Field(None, description="Chemin rapport HTML")
    output_directory: str

    # Métadonnées
    completed_at: datetime


class ErrorResponse(BaseModel):
    """Réponse d'erreur standard"""
    detail: str
    error_type: Optional[str]
    timestamp: datetime = Field(default_factory=datetime.now)
