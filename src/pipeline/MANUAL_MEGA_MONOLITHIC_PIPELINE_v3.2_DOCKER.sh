#!/bin/bash
#===============================================================================
#
#   ███╗   ███╗███████╗ ██████╗  █████╗ ███╗   ███╗
#   ████╗ ████║██╔════╝██╔════╝ ██╔══██╗████╗ ████║
#   ██╔████╔██║█████╗  ██║  ███╗███████║██╔████╔██║
#   ██║╚██╔╝██║██╔══╝  ██║   ██║██╔══██║██║╚██╔╝██║
#   ██║ ╚═╝ ██║███████╗╚██████╔╝██║  ██║██║ ╚═╝ ██║
#   ╚═╝     ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝
#
#            ARG DETECTION PIPELINE v3.2
#
#   Antimicrobial Resistance Genes Detection & Analysis
#   Multi-Input Support (SRA, GenBank, Assemblies, Local FASTA)
#
#===============================================================================
#
#   Auteur    : Rachid Merah
#   Email     : rachid.merah77@gmail.com
#   Version   : 3.2
#   Date      : 2026-01-28
#   Licence   : MIT
#
#===============================================================================
#
#   DESCRIPTION:
#   Pipeline complet pour la détection et l'analyse des gènes de résistance
#   aux antimicrobiens (ARG) à partir de données génomiques.
#
#   FONCTIONNALITÉS v3.2:
#   ✅ Support multi-entrées : SRA (SRR*), GenBank (CP*, NC*, NZ_*),
#      Assemblages (GCA_*), fichiers FASTA locaux
#   ✅ Argument CLI : bash script.sh <SAMPLE_ID ou chemin FASTA>
#   ✅ Mode interactif si aucun argument fourni
#   ✅ Vérification/création automatique de l'architecture
#   ✅ Système de gestion des versions (timestamp)
#   ✅ Détection automatique des bases de données
#   ✅ Téléchargement automatique des bases manquantes
#   ✅ Menu interactif de gestion
#   ✅ Archivage automatique
#   ✅ Nettoyage des anciens résultats
#
#   USAGE:
#     bash script.sh SRR28083254      # Données SRA (FASTQ)
#     bash script.sh CP133916.1       # Séquence GenBank (FASTA)
#     bash script.sh GCA_000005845.2  # Assemblage NCBI (FASTA)
#     bash script.sh /chemin/vers/assembly.fasta  # Fichier local
#     bash script.sh                  # Mode interactif
#
#   MODULES:
#     0. Téléchargement/Préparation des données
#     1. Contrôle qualité (FastQC, fastp, MultiQC)
#     2. Assemblage (SPAdes, QUAST)
#     3. Annotation (Prokka)
#     4. Détection ARG (AMRFinderPlus, ResFinder, CARD, etc.)
#     5. Variant Calling (Snippy)
#     6. Analyse et rapports
#
#===============================================================================
#
#   VERSION DOCKER - Les outils bioinformatiques sont pré-installés dans
#   3 environnements mamba :
#     - megam_arg     : env principal (activé par entrypoint.sh)
#     - snippy_prokka : prokka et snippy (conflits avec spades/quast)
#     - abricate_env  : abricate (conflits Perl)
#   Les commandes conda activate/deactivate sont remplacées par des appels
#   directs ou par "mamba run --no-banner -n <env>" selon l'outil.
#
#===============================================================================

#===============================================================================
# SECTION 1 : INITIALISATION ET CONFIGURATION CRITIQUE
#===============================================================================

# Arrêter immédiatement en cas d'erreur
set -euo pipefail

# Trap pour afficher les erreurs
trap 'echo "❌ ERREUR: Script échoué à la ligne $LINENO"; exit 1' ERR

#===============================================================================
# SECTION 2 : PARSING DES ARGUMENTS ET MODE INTERACTIF
#===============================================================================

# Fonction d'aide
show_help() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "PIPELINE ARG v3.2 - AIDE"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "USAGE:"
    echo "  bash $0 <SAMPLE_ID ou chemin_fichier> [OPTIONS]"
    echo ""
    echo "TYPES D'ENTRÉES SUPPORTÉS:"
    echo "  SRR*, ERR*, DRR*     → Données SRA (reads FASTQ)"
    echo "  CP*, NC*, NZ_*       → Séquence GenBank (FASTA assemblé)"
    echo "  GCA_*, GCF_*         → Assemblage NCBI (FASTA assemblé)"
    echo "  /chemin/fichier.fasta → Fichier FASTA local"
    echo "  (aucun argument)     → Mode interactif"
    echo ""
    echo "EXEMPLES:"
    echo "  bash $0 SRR28083254"
    echo "  bash $0 CP133916.1"
    echo "  bash $0 GCA_000005845.2"
    echo "  bash $0 /home/user/my_assembly.fasta"
    echo ""
    echo "COMMANDES:"
    echo "  update               Mettre à jour toutes les bases de données"
    echo "  update amrfinder     Mettre à jour uniquement AMRFinder"
    echo "  update card          Mettre à jour uniquement CARD (RGI)"
    echo "  update mlst          Mettre à jour uniquement MLST"
    echo "  update pointfinder   Mettre à jour uniquement PointFinder"
    echo "  update kma           Mettre à jour uniquement KMA/ResFinder"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help           Afficher cette aide"
    echo "  -t, --threads N      Nombre de threads (défaut: 8)"
    echo "  -w, --workdir PATH   Répertoire de travail"
    echo "  -f, --force, -y      Mode non-interactif (accepte automatiquement)"
    echo ""
    echo "OPTIONS PROKKA (annotation):"
    echo "  --prokka-mode MODE   Mode d'annotation Prokka:"
    echo "                         auto    → Détecte l'espèce via l'API NCBI (défaut)"
    echo "                         generic → Mode universel (toutes bactéries)"
    echo "                         ecoli   → Escherichia coli K-12 (legacy)"
    echo "                         custom  → Utilise --prokka-genus/species"
    echo "  --prokka-genus STR   Genre bactérien (avec --prokka-mode custom)"
    echo "  --prokka-species STR Espèce bactérienne (avec --prokka-mode custom)"
    echo ""
    echo "EXEMPLES AVANCÉS:"
    echo "  bash $0 SRR28083254 --prokka-mode auto"
    echo "  bash $0 CP133916.1 --prokka-mode generic"
    echo "  bash $0 GCA_000005845.2 --prokka-mode custom --prokka-genus Salmonella --prokka-species enterica"
    echo ""
    exit 0
}

# Parsing des arguments
INPUT_ARG=""
INPUT_ARG2=""
THREADS="${THREADS:-8}"
# Répertoire du script (permet l'exécution portable depuis n'importe où)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR}"
# Répertoire contenant les scripts Python
PYTHON_DIR="$(dirname "$SCRIPT_DIR")/python"
FORCE_MODE=true  # Default true for web interface
# Mode Prokka : "auto" (détection NCBI), "generic" (universel), "ecoli" (E. coli par défaut)
PROKKA_MODE="${PROKKA_MODE:-auto}"
# Variables pour Prokka (peuvent être définies par l'utilisateur)
PROKKA_GENUS=""
PROKKA_SPECIES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -t|--threads)
            THREADS="$2"
            shift 2
            ;;
        -w|--workdir)
            WORK_DIR="$2"
            shift 2
            ;;
        -f|--force|-y|--yes)
            FORCE_MODE=true
            shift
            ;;
        --prokka-mode)
            PROKKA_MODE="$2"
            if [[ ! "$PROKKA_MODE" =~ ^(auto|generic|ecoli|custom)$ ]]; then
                echo "❌ Mode Prokka invalide: $PROKKA_MODE"
                echo "   Valeurs acceptées: auto, generic, ecoli, custom"
                exit 1
            fi
            shift 2
            ;;
        --prokka-genus)
            PROKKA_GENUS="$2"
            shift 2
            ;;
        --prokka-species)
            PROKKA_SPECIES="$2"
            shift 2
            ;;
        -*)
            echo "Option inconnue: $1"
            show_help
            ;;
        *)
            if [[ -z "$INPUT_ARG" ]]; then
                INPUT_ARG="$1"
            else
                INPUT_ARG2="$1"
            fi
            shift
            ;;
    esac
done

# Variable pour stocker la commande update (sera traitée après définition des fonctions)
UPDATE_MODE=false
if [[ "$INPUT_ARG" == "update" ]]; then
    UPDATE_MODE=true
    # Sourcer les fonctions nécessaires et traiter la commande update immédiatement
    # (Le reste du script sera ignoré via la gestion plus loin)
fi

# Si mode update, on skip le mode interactif et la détection de type
if [[ "$UPDATE_MODE" == true ]]; then
    # Continuer vers les définitions de fonctions, le traitement se fera là-bas
    :
# Si aucun argument, mode interactif
elif [[ -z "$INPUT_ARG" ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "PIPELINE ARG v3.2 - MODE INTERACTIF"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Types d'entrées supportés:"
    echo "  1) SRR*, ERR*, DRR*     → Données SRA (reads FASTQ)"
    echo "  2) CP*, NC*, NZ_*       → Séquence GenBank (FASTA)"
    echo "  3) GCA_*, GCF_*         → Assemblage NCBI (FASTA)"
    echo "  4) /chemin/fichier.fasta → Fichier FASTA local"
    echo ""
    read -p "Entrez le SAMPLE_ID ou le chemin du fichier FASTA: " INPUT_ARG

    if [[ -z "$INPUT_ARG" ]]; then
        echo "❌ ERREUR: Aucune entrée fournie"
        exit 1
    fi

    # Choix du mode Prokka en mode interactif
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "MODE D'ANNOTATION PROKKA"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Choisissez le mode d'annotation pour Prokka:"
    echo "  1) auto    → Détection automatique de l'espèce via l'API NCBI (recommandé)"
    echo "  2) generic → Mode universel (toutes bactéries, sans spécifier l'espèce)"
    echo "  3) ecoli   → Escherichia coli K-12 (mode legacy)"
    echo "  4) custom  → Spécifier manuellement le genre et l'espèce"
    echo ""
    read -p "Votre choix (1-4) [défaut: 1]: " prokka_choice

    case "${prokka_choice:-1}" in
        1)
            PROKKA_MODE="auto"
            echo "✅ Mode Prokka: auto (détection NCBI)"
            ;;
        2)
            PROKKA_MODE="generic"
            echo "✅ Mode Prokka: generic (universel)"
            ;;
        3)
            PROKKA_MODE="ecoli"
            echo "✅ Mode Prokka: ecoli (E. coli K-12)"
            ;;
        4)
            PROKKA_MODE="custom"
            read -p "Genre bactérien (ex: Salmonella): " PROKKA_GENUS
            read -p "Espèce bactérienne (ex: enterica): " PROKKA_SPECIES
            if [[ -z "$PROKKA_GENUS" ]]; then
                echo "⚠️  Genre non spécifié, passage en mode generic"
                PROKKA_MODE="generic"
            else
                echo "✅ Mode Prokka: custom ($PROKKA_GENUS $PROKKA_SPECIES)"
            fi
            ;;
        *)
            PROKKA_MODE="auto"
            echo "✅ Mode Prokka: auto (défaut)"
            ;;
    esac
fi

#===============================================================================
# SECTION 3 : DÉTECTION DU TYPE D'ENTRÉE
#===============================================================================

detect_input_type() {
    local input="$1"

    # Fichier local existant
    if [[ -f "$input" ]]; then
        echo "local_fasta"
        return 0
    fi

    # SRA (SRR, ERR, DRR)
    if [[ "$input" =~ ^[SED]RR[0-9]+ ]]; then
        echo "sra"
        return 0
    fi

    # GenBank sequence (CP, NC, NZ_)
    if [[ "$input" =~ ^(CP|NC_|NZ_)[0-9]+ ]]; then
        echo "genbank"
        return 0
    fi

    # NCBI Assembly (GCA_, GCF_)
    if [[ "$input" =~ ^GC[AF]_[0-9]+ ]]; then
        echo "assembly"
        return 0
    fi

    # Chemin de fichier qui n'existe pas encore
    if [[ "$input" == *"/"* ]] || [[ "$input" == *".fasta"* ]] || [[ "$input" == *".fna"* ]]; then
        echo "local_fasta"
        return 0
    fi

    # Type inconnu
    echo "unknown"
    return 1
}

# Skip la détection de type si on est en mode update
if [[ "$UPDATE_MODE" == true ]]; then
    INPUT_TYPE="update"
else
    INPUT_TYPE=$(detect_input_type "$INPUT_ARG")

    if [[ "$INPUT_TYPE" == "unknown" ]]; then
        echo "❌ ERREUR: Type d'entrée non reconnu: $INPUT_ARG"
        echo "   Types supportés: SRR*, CP*, NC*, NZ_*, GCA_*, GCF_*, ou fichier FASTA"
        exit 1
    fi
fi

# Définir SAMPLE_ID selon le type (skip si mode update)
if [[ "$UPDATE_MODE" == true ]]; then
    SAMPLE_ID="update"
else
    case "$INPUT_TYPE" in
        local_fasta)
            # Extraire le nom du fichier sans extension
            SAMPLE_ID=$(basename "$INPUT_ARG" | sed 's/\.\(fasta\|fna\|fa\)$//')
            LOCAL_FASTA_PATH="$INPUT_ARG"
            ;;
        *)
            SAMPLE_ID="$INPUT_ARG"
            ;;
    esac

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "DÉTECTION DU TYPE D'ENTRÉE"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Entrée: $INPUT_ARG"
    echo "  Type détecté: $INPUT_TYPE"
    echo "  Sample ID: $SAMPLE_ID"
    echo ""
fi

#===============================================================================
# SECTION 4 : VARIABLES DE CONFIGURATION
#===============================================================================

# VERSIONING - Système simplifié avec compteur d'essais
# Fonction pour trouver le prochain numéro d'essai
get_next_run_number() {
    local sample_id="$1"
    local outputs_dir="$WORK_DIR/outputs"

    # Si le dossier outputs n'existe pas encore
    if [[ ! -d "$outputs_dir" ]]; then
        echo "1"
        return
    fi

    # Trouver le plus grand numéro de run existant au format exact SAMPLE_N
    # Les anciens formats (ex: SAMPLE_v3.2_20260128_124016) sont ignorés
    # IMPORTANT: Cet algorithme doit rester synchronisé avec
    # get_next_run_number() dans backend/pipeline_launcher.py
    local max_run=0
    for dir in "$outputs_dir"/${sample_id}_*/; do
        [[ -d "$dir" ]] || continue
        local dirname
        dirname=$(basename "$dir")
        local suffix="${dirname#${sample_id}_}"
        # Vérifier que le suffixe est uniquement un entier
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            if (( suffix > max_run )); then
                max_run=$suffix
            fi
        fi
    done

    echo "$((max_run + 1))"
}

# Déterminer le numéro d'essai
RUN_NUMBER=$(get_next_run_number "$SAMPLE_ID")
RESULTS_VERSION="${RESULTS_VERSION:-${RUN_NUMBER}}"

# Timestamp pour les logs (conservé pour traçabilité interne)
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Répertoires principaux (nomenclature simplifiée)
DATA_DIR="$WORK_DIR/data"
RESULTS_DIR="$WORK_DIR/outputs/${SAMPLE_ID}_${RESULTS_VERSION}"
DB_DIR="$WORK_DIR/databases"
REFERENCE_DIR="$WORK_DIR/references"
ARCHIVE_DIR="$WORK_DIR/archives"
LOG_DIR="$RESULTS_DIR/logs"

# Bases de données (seront configurées par interactive_database_setup)
AMRFINDER_DB=""
CARD_DB=""
POINTFINDER_DB=""
MLST_DB=""
REFERENCE_GENOME="$REFERENCE_DIR/ecoli_k12.fasta"

# Fichiers de log
LOG_FILE="$LOG_DIR/pipeline_${TIMESTAMP}.log"
ERROR_LOG="$LOG_DIR/pipeline_errors.log"

# Variable pour indiquer si on utilise un FASTA pré-assemblé
IS_ASSEMBLED_INPUT=false
if [[ "$INPUT_TYPE" == "genbank" ]] || [[ "$INPUT_TYPE" == "assembly" ]] || [[ "$INPUT_TYPE" == "local_fasta" ]]; then
    IS_ASSEMBLED_INPUT=true
fi

# Variable pour l'espèce détectée par NCBI API (initialisée vide)
DETECTED_SPECIES=""

#===============================================================================
# SECTION 5 : VÉRIFICATION ET CRÉATION DE L'ARCHITECTURE
#===============================================================================

# Si mode update, on saute directement vers le traitement (après définition des fonctions)
# Le code qui suit est pour le pipeline normal uniquement
if [[ "$UPDATE_MODE" == true ]]; then
    # Les variables essentielles sont définies, on peut continuer
    # Le traitement se fera après la définition des fonctions de mise à jour
    :
else
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "VÉRIFICATION ET CRÉATION DE L'ARCHITECTURE"
    echo "═══════════════════════════════════════════════════════════════════"
fi

# Fonction pour vérifier et créer l'architecture
setup_directory_structure() {
    local missing_dirs=0
    local created_dirs=0

    # Liste des répertoires requis
    local required_dirs=(
        "$WORK_DIR"
        "$DATA_DIR"
        "$DB_DIR"
        "$REFERENCE_DIR"
        "$ARCHIVE_DIR"
        "$RESULTS_DIR"
        "$LOG_DIR"
        "$RESULTS_DIR/01_qc/fastqc_raw"
        "$RESULTS_DIR/01_qc/fastqc_clean"
        "$RESULTS_DIR/01_qc/fastp"
        "$RESULTS_DIR/01_qc/multiqc"
        "$RESULTS_DIR/02_assembly/spades"
        "$RESULTS_DIR/02_assembly/filtered"
        "$RESULTS_DIR/02_assembly/quast"
        "$RESULTS_DIR/03_annotation/prokka"
        "$RESULTS_DIR/03_annotation/stats"
        "$RESULTS_DIR/04_arg_detection/amrfinderplus"
        "$RESULTS_DIR/04_arg_detection/resfinder"
        "$RESULTS_DIR/04_arg_detection/plasmidfinder"
        "$RESULTS_DIR/04_arg_detection/card"
        "$RESULTS_DIR/04_arg_detection/ncbi"
        "$RESULTS_DIR/04_arg_detection/synthesis"
        "$RESULTS_DIR/05_variant_calling/snippy"
        "$RESULTS_DIR/05_variant_calling/stats"
        "$RESULTS_DIR/06_analysis/reports"
        "$RESULTS_DIR/06_analysis/figures"
        "$RESULTS_DIR/06_analysis/statistics"
        "$RESULTS_DIR/07_rag_ready/structured"
        "$RESULTS_DIR/07_rag_ready/chunks"
        "$RESULTS_DIR/07_rag_ready/metadata"
        "$RESULTS_DIR/08_rag_export"
    )

    echo ""
    echo "Vérification de l'architecture des répertoires..."
    echo ""

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs=$((missing_dirs + 1))
            mkdir -p "$dir"
            created_dirs=$((created_dirs + 1))
            echo "  ✅ Créé: $dir"
        fi
    done

    if [[ $created_dirs -eq 0 ]]; then
        echo "  ✅ Architecture complète - Aucun répertoire manquant"
    else
        echo ""
        echo "  📁 $created_dirs répertoire(s) créé(s)"
    fi

    echo ""
}

# Exécuter la vérification/création de l'architecture (sauf en mode update)
if [[ "$UPDATE_MODE" != true ]]; then
    setup_directory_structure

    # Maintenant que LOG_DIR existe, on peut créer les fichiers de log
    touch "$LOG_FILE" 2>/dev/null || true
    touch "$ERROR_LOG" 2>/dev/null || true
fi

#===============================================================================
# SECTION 6 : FONCTIONS UTILITAIRES
#===============================================================================

# Fonction de logging
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    log_message "INFO" "$@"
}

log_warn() {
    log_message "WARN" "$@"
}

log_error() {
    log_message "ERROR" "$@"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $@" >> "$ERROR_LOG"
}

log_success() {
    log_message "SUCCESS" "$@"
}

# Fonction utilitaire pour encoder les URLs (utilisée pour les requêtes NCBI)
urlencode() {
    local raw="$1"
    local encoded=""
    local i c
    for (( i=0; i<${#raw}; i++ )); do
        c=${raw:i:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            ' ') encoded+='+' ;;
            *) printf -v hex '%%%02X' "'$c"; encoded+="$hex" ;;
        esac
    done
    echo "$encoded"
}

# Fonction pour ouvrir les fichiers (GUI-safe)
open_file_safe() {
    local file_path=$1
    local description="${2:-Fichier}"
    
    if [[ ! -f "$file_path" ]]; then
        log_warn "Fichier introuvable: $file_path"
        return 1
    fi
    
    if command -v xdg-open > /dev/null 2>&1; then
        log_info "Ouverture de: $description"
        # xdg-open (disabled for web) "$file_path" 2>/dev/null || log_warn "Impossible d'ouvrir avec xdg-open"
    else
        log_info "Rapport disponible (xdg-open non disponible): $file_path"
    fi
}

fetch_species_from_ncbi() {
    local sample_id="$1"
    local input_type="$2"

    log_info "Interrogation de l'API NCBI pour identifier l'organisme..."

    # Fichiers locaux : pas d'appel NCBI possible
    if [[ "$input_type" == "local" ]] || [[ "$input_type" == "local_fasta" ]]; then
        log_warn "Entrée locale: impossible de déterminer l'espèce via NCBI"
        DETECTED_SPECIES=""
        PROKKA_GENUS=""
        PROKKA_SPECIES=""
        return 1
    fi

    local entrez_base="https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
    local organism=""
    local taxid=""

    case "$input_type" in
        sra)
            # SRA (SRR/ERR/DRR) : esearch -> esummary
            local search_result=$(curl -s "${entrez_base}/esearch.fcgi?db=sra&term=${sample_id}&retmode=json" 2>/dev/null)
            local uid=$(echo "$search_result" | grep -o '"IdList":\["[0-9]*"' | grep -o '[0-9]*' | head -1)
            if [[ -n "$uid" ]]; then
                local summary=$(curl -s "${entrez_base}/esummary.fcgi?db=sra&id=${uid}&retmode=json" 2>/dev/null)
                organism=$(echo "$summary" | grep -o 'ScientificName="[^"]*"' | head -1 | sed 's/ScientificName="//;s/"//')
                taxid=$(echo "$summary" | grep -o 'taxid="[0-9]*"' | head -1 | sed 's/taxid="//;s/"//')
            fi
            ;;
        genbank)
            # GenBank (CP/NC_/NZ_) : esummary
            local summary=$(curl -s "${entrez_base}/esummary.fcgi?db=nuccore&id=${sample_id}&retmode=json" 2>/dev/null)
            local uid=$(echo "$summary" | grep -o '"uids":\["[0-9]*"' | grep -o '[0-9]*' | head -1)
            if [[ -n "$uid" ]]; then
                organism=$(echo "$summary" | python3 -c "
import sys, json
data = json.load(sys.stdin)
doc = data.get('result', {}).get('$uid', {})
print(doc.get('organism', ''))
" 2>/dev/null || echo "")
            fi
            ;;
        assembly)
            # Assembly (GCF_/GCA_) : esearch -> esummary
            local search_result=$(curl -s "${entrez_base}/esearch.fcgi?db=assembly&term=${sample_id}&retmode=json" 2>/dev/null)
            local uid=$(echo "$search_result" | grep -o '"IdList":\["[0-9]*"' | grep -o '[0-9]*' | head -1)
            if [[ -n "$uid" ]]; then
                local summary=$(curl -s "${entrez_base}/esummary.fcgi?db=assembly&id=${uid}&retmode=json" 2>/dev/null)
                organism=$(echo "$summary" | python3 -c "
import sys, json
data = json.load(sys.stdin)
doc = data.get('result', {}).get('$uid', {})
print(doc.get('organism', '').split('(')[0].strip())
" 2>/dev/null || echo "")
            fi
            ;;
    esac

    if [[ -n "$organism" ]]; then
        DETECTED_SPECIES="$organism"
        PROKKA_GENUS=$(echo "$organism" | awk '{print $1}')
        PROKKA_SPECIES=$(echo "$organism" | awk '{print $2}')
        PROKKA_GENUS="${PROKKA_GENUS:-Bacteria}"
        PROKKA_SPECIES="${PROKKA_SPECIES:-sp.}"

        # Exporter pour les scripts Python
        export NCBI_DETECTED_SPECIES="$DETECTED_SPECIES"

        log_success "Espèce détectée via NCBI: $DETECTED_SPECIES"
        log_info "  → Genre: $PROKKA_GENUS"
        log_info "  → Espèce: $PROKKA_SPECIES"
        return 0
    fi

    log_warn "Impossible de déterminer l'espèce via NCBI pour $sample_id"
    DETECTED_SPECIES=""
    PROKKA_GENUS=""
    PROKKA_SPECIES=""
    return 1
}

#===============================================================================
# SECTION 6.4 : TÉLÉCHARGEMENT AUTOMATIQUE DES RÉFÉRENCES
#===============================================================================

# Fonction pour télécharger le génome de référence d'une espèce
# Utilise NCBI Assembly pour trouver un génome de référence ou représentatif
# Met à jour la variable globale REFERENCE_GENOME
#===============================================================================
# SECTION 6.4 : TÉLÉCHARGEMENT AUTOMATIQUE DES RÉFÉRENCES (CORRIGÉE)
#===============================================================================

# Fonction pour télécharger le génome de référence d'une espèce
# Utilise NCBI Assembly pour trouver un génome de référence ou représentatif
# Met à jour la variable globale REFERENCE_GENOME
download_reference_genome() {
    local genus="$1"
    local species="$2"
    local output_dir="${3:-$REFERENCE_DIR}"

    # Normaliser les noms (minuscules, sans espaces multiples)
    genus=$(echo "$genus" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    species=$(echo "$species" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Nom du fichier de référence
    local ref_filename="${genus}_${species}.fasta"
    local ref_path="$output_dir/$ref_filename"

    log_info "Recherche de référence pour: $genus $species"

    # Vérifier si la référence existe déjà
    if [[ -f "$ref_path" ]] && [[ -s "$ref_path" ]]; then
        log_success "Référence existante trouvée: $ref_path"
        REFERENCE_GENOME="$ref_path"
        return 0
    fi

    # Vérifier aussi avec d'autres extensions possibles
    for ext in fasta fna fa; do
        local alt_path="$output_dir/${genus}_${species}.$ext"
        if [[ -f "$alt_path" ]] && [[ -s "$alt_path" ]]; then
            log_success "Référence existante trouvée: $alt_path"
            REFERENCE_GENOME="$alt_path"
            return 0
        fi
    done

    log_info "Référence non trouvée localement, téléchargement depuis NCBI..."
    mkdir -p "$output_dir"

    # Méthode 1: Recherche via NCBI Datasets API (si disponible)
    if command -v datasets > /dev/null 2>&1; then
        log_info "  Utilisation de NCBI datasets CLI..."

        local temp_dir=$(mktemp -d)
        if datasets download genome taxon "${genus} ${species}" \
            --reference \
            --include genome \
            --filename "$temp_dir/genome.zip" 2>> "$LOG_FILE"; then

            if [[ -f "$temp_dir/genome.zip" ]]; then
                unzip -q -o "$temp_dir/genome.zip" -d "$temp_dir" 2>> "$LOG_FILE"
                local fna_file=$(find "$temp_dir" -name "*.fna" -type f 2>/dev/null | head -1)

                if [[ -n "$fna_file" ]] && [[ -s "$fna_file" ]]; then
                    cp "$fna_file" "$ref_path"
                    rm -rf "$temp_dir"
                    log_success "Référence téléchargée via datasets: $ref_path"
                    REFERENCE_GENOME="$ref_path"
                    return 0
                fi
            fi
        fi
        rm -rf "$temp_dir"
    fi

    # Méthode 2: Recherche via NCBI E-utilities
    log_info "  Recherche via NCBI E-utilities..."

    local esearch_url="https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"

    # Termes de recherche encodés (utilise la fonction globale urlencode)
    local term_rep=$(urlencode "${genus} ${species}[Organism] AND representative genome[Filter]")
    local term_ref=$(urlencode "${genus} ${species}[Organism] AND reference genome[Filter]")
    local term_any=$(urlencode "${genus} ${species}[Organism] AND complete genome[Title]")

    # --- 1️⃣ Recherche 'Representative genome' ---
    # Ajout de || true pour éviter le crash du mode set -e si aucune correspondance n'est trouvée
    local search_result=$(wget -q --timeout=30 -O - "${esearch_url}?db=assembly&term=${term_rep}&retmax=1" 2>>"$LOG_FILE" || echo "")
    local assembly_id=$(echo "$search_result" | grep -oP '(?<=<Id>)[^<]+' | head -1 || true)

    # --- 2️⃣ Recherche 'Reference genome' (si 1 échoue) ---
    if [[ -z "$assembly_id" ]]; then
        search_result=$(wget -q --timeout=30 -O - "${esearch_url}?db=assembly&term=${term_ref}&retmax=1" 2>>"$LOG_FILE" || echo "")
        assembly_id=$(echo "$search_result" | grep -oP '(?<=<Id>)[^<]+' | head -1 || true)
    fi

    # --- 3️⃣ Recherche 'Any complete genome' (si 1 et 2 échouent) ---
    if [[ -z "$assembly_id" ]]; then
        search_result=$(wget -q --timeout=30 -O - "${esearch_url}?db=assembly&term=${term_any}&retmax=1" 2>>"$LOG_FILE" || echo "")
        assembly_id=$(echo "$search_result" | grep -oP '(?<=<Id>)[^<]+' | head -1 || true)
    fi

    # --- Validation finale et téléchargement de l'ID trouvé ---
    if [[ -n "$assembly_id" ]]; then
        log_info "  Assembly ID trouvé: $assembly_id"

        local esummary_url="https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
        local summary=$(wget -q --timeout=30 -O - "${esummary_url}?db=assembly&id=${assembly_id}" 2>>"$LOG_FILE" || echo "")
        
        # Sécurisation de l'extraction de l'accession
        local accession=$(echo "$summary" | grep -oP 'GC[AF]_[0-9]+\.[0-9]+' | head -1 || true)

        if [[ -n "$accession" ]]; then
            log_info "  Accession trouvée: $accession"
            download_ncbi_assembly "$accession" "$output_dir"

            if [[ -n "$DOWNLOADED_FILE" && -f "$DOWNLOADED_FILE" ]]; then
                mv "$DOWNLOADED_FILE" "$ref_path" 2>/dev/null || cp "$DOWNLOADED_FILE" "$ref_path"
                log_success "Référence téléchargée: $ref_path"
                REFERENCE_GENOME="$ref_path"
                return 0
            fi
        fi
    fi

    # Méthode 3: Recherche directe dans nuccore pour un génome complet (Dernier recours)
    log_info "  Recherche alternative dans nuccore..."
    local nuccore_search=$(urlencode "${genus} ${species}[Organism] AND complete genome[Title]")
    search_result=$(wget -q --timeout=30 -O - "${esearch_url}?db=nuccore&term=${nuccore_search}&retmax=1" 2>> "$LOG_FILE" || echo "")
    local nuccore_id=$(echo "$search_result" | grep -oP '(?<=<Id>)[^<]+' | head -1 || true)

    if [[ -n "$nuccore_id" ]]; then
        log_info "  Nuccore ID trouvé: $nuccore_id"
        local efetch_url="https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${nuccore_id}&rettype=fasta&retmode=text"
        wget -q --timeout=60 -O "$ref_path" "$efetch_url" 2>> "$LOG_FILE"

        if [[ -f "$ref_path" ]] && [[ -s "$ref_path" ]]; then
            if head -1 "$ref_path" | grep -q "^>"; then
                log_success "Référence téléchargée depuis nuccore: $ref_path"
                REFERENCE_GENOME="$ref_path"
                return 0
            fi
        fi
    fi

    log_warn "Impossible de télécharger la référence pour $genus $species"
    log_warn "Le pipeline continuera sans référence spécifique (comparaison limitée)"
    REFERENCE_GENOME=""
    return 1
}

# Fonction pour obtenir ou télécharger la référence appropriée
# Retourne le chemin via REFERENCE_GENOME
get_or_download_reference() {
    local genus="${1:-}"
    local species="${2:-}"

    # Si genre/espèce non fournis, vérifier les variables globales
    if [[ -z "$genus" ]]; then
        genus="$PROKKA_GENUS"
    fi
    if [[ -z "$species" ]]; then
        species="$PROKKA_SPECIES"
    fi

    # Si toujours pas d'espèce détectée
    if [[ -z "$genus" ]] || [[ "$genus" == "Bacteria" ]]; then
        log_warn "Aucune espèce détectée, impossible de télécharger une référence spécifique"

        # Fallback sur E. coli si disponible
        if [[ -f "$REFERENCE_DIR/ecoli_k12.fasta" ]]; then
            log_info "Utilisation de la référence par défaut: E. coli K-12"
            REFERENCE_GENOME="$REFERENCE_DIR/ecoli_k12.fasta"
            return 0
        fi

        REFERENCE_GENOME=""
        return 1
    fi

    # Cas spécial: E. coli (référence déjà présente)
    if [[ "$genus" == "Escherichia" ]] && [[ "$species" == "coli" ]]; then
        if [[ -f "$REFERENCE_DIR/ecoli_k12.fasta" ]]; then
            log_info "Utilisation de la référence E. coli K-12 existante"
            REFERENCE_GENOME="$REFERENCE_DIR/ecoli_k12.fasta"
            return 0
        fi
    fi

    # Télécharger la référence pour l'espèce détectée
    download_reference_genome "$genus" "$species" "$REFERENCE_DIR"
    return $?
}

# Fonction pour créer/vérifier la base de données KMA
# Utilise les séquences d'abricate pour créer l'index KMA
setup_kma_database() {
    local kma_db_dir="$DB_DIR/kma_db"

    # Vérifier si KMA est installé
    if ! command -v kma > /dev/null 2>&1; then
        log_warn "KMA non installé, base de données non créée"
        return 1
    fi

    # Vérifier si la base existe déjà
    if [[ -f "$kma_db_dir/resfinder.name" ]]; then
        log_info "Base KMA existante trouvée: $kma_db_dir/resfinder"
        return 0
    fi

    log_info "Création de la base de données KMA..."
    mkdir -p "$kma_db_dir"

    # Récupérer le chemin des bases abricate (abricate est dans abricate_env)
    local abricate_db=""

    # Méthode 1: Extraire depuis --help via abricate_env
    abricate_db=$(mamba run --no-banner -n abricate_env abricate --help 2>&1 | grep -oP '\-\-datadir.*\[\K[^\]]+' | head -1)

    # Méthode 2: Si échec, chercher dans le prefix de abricate_env
    if [[ -z "$abricate_db" ]] || [[ ! -d "$abricate_db" ]]; then
        local abricate_prefix=$(mamba run --no-banner -n abricate_env bash -c 'echo $CONDA_PREFIX' 2>/dev/null)
        if [[ -n "$abricate_prefix" ]] && [[ -d "$abricate_prefix/share/abricate/db" ]]; then
            abricate_db="$abricate_prefix/share/abricate/db"
        fi
    fi

    # Méthode 3: Chemins connus (portables)
    if [[ -z "$abricate_db" ]] || [[ ! -d "$abricate_db" ]]; then
        for path in "$HOME/abricate/db" "/usr/local/share/abricate/db" "/opt/abricate/db" "${CONDA_PREFIX:-}/share/abricate/db"; do
            if [[ -d "$path" ]]; then
                abricate_db="$path"
                break
            fi
        done
    fi

    if [[ -z "$abricate_db" ]] || [[ ! -d "$abricate_db" ]]; then
        log_warn "Bases abricate non trouvées, impossible de créer la base KMA"
        log_warn "  Vérifiez l'installation abricate avec: abricate --list"
        return 1
    fi

    log_info "  Bases abricate trouvées: $abricate_db"

    # Créer les index KMA pour chaque base
    for db_name in resfinder card ncbi; do
        local seq_file="$abricate_db/$db_name/sequences"

        if [[ -f "$seq_file" ]]; then
            log_info "  Indexation KMA: $db_name..."
            kma index -i "$seq_file" -o "$kma_db_dir/$db_name" 2>> "$LOG_FILE"

            if [[ -f "$kma_db_dir/${db_name}.name" ]]; then
                log_success "  Base KMA créée: $db_name"
            else
                log_warn "  Échec création base KMA: $db_name"
            fi
        else
            log_warn "  Séquences non trouvées: $db_name"
        fi
    done

    return 0
}

#===============================================================================
# SECTION 6.5 : FONCTIONS DE TÉLÉCHARGEMENT MULTI-SOURCES
#===============================================================================

# Fonction pour télécharger une séquence GenBank (CP*, NC*, NZ_*)
# Retourne le chemin du fichier téléchargé via la variable globale DOWNLOADED_FILE
download_genbank_sequence() {
    local accession="$1"
    local output_dir="$2"
    DOWNLOADED_FILE="$output_dir/${accession}.fasta"

    log_info "Téléchargement de la séquence GenBank: $accession"

    # Méthode 1: API eutils (méthode la plus fiable)
    log_info "  Téléchargement via API NCBI eutils..."
    local eutils_url="https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${accession}&rettype=fasta&retmode=text"
    wget -q --timeout=60 -O "$DOWNLOADED_FILE" "$eutils_url" 2>> "$LOG_FILE"

    # Vérifier si le téléchargement a réussi
    if [[ -f "$DOWNLOADED_FILE" ]] && [[ -s "$DOWNLOADED_FILE" ]]; then
        # Vérifier que c'est bien un fichier FASTA (commence par >)
        if head -1 "$DOWNLOADED_FILE" | grep -q "^>"; then
            log_success "Séquence GenBank téléchargée: $DOWNLOADED_FILE"
            return 0
        fi
    fi

    # Méthode 2: Fallback avec efetch CLI si disponible
    if command -v efetch > /dev/null 2>&1; then
        log_info "  Fallback: Utilisation de efetch (E-utilities CLI)..."
        efetch -db nuccore -id "$accession" -format fasta > "$DOWNLOADED_FILE" 2>> "$LOG_FILE"

        if [[ -f "$DOWNLOADED_FILE" ]] && [[ -s "$DOWNLOADED_FILE" ]]; then
            if head -1 "$DOWNLOADED_FILE" | grep -q "^>"; then
                log_success "Séquence GenBank téléchargée via efetch CLI: $DOWNLOADED_FILE"
                return 0
            fi
        fi
    fi

    # Méthode 3: Fallback avec curl si wget échoue
    log_info "  Fallback: Utilisation de curl..."
    curl -s -o "$DOWNLOADED_FILE" "$eutils_url" 2>> "$LOG_FILE"

    if [[ -f "$DOWNLOADED_FILE" ]] && [[ -s "$DOWNLOADED_FILE" ]]; then
        if head -1 "$DOWNLOADED_FILE" | grep -q "^>"; then
            log_success "Séquence GenBank téléchargée via curl: $DOWNLOADED_FILE"
            return 0
        fi
    fi

    log_error "Échec du téléchargement de $accession (toutes les méthodes ont échoué)"
    DOWNLOADED_FILE=""
    return 1
}

# Fonction pour télécharger un assemblage NCBI (GCA_*, GCF_*)
# Retourne le chemin du fichier téléchargé via la variable globale DOWNLOADED_FILE
download_ncbi_assembly() {
    local accession="$1"
    local output_dir="$2"
    DOWNLOADED_FILE="$output_dir/${accession}_genomic.fna"

    log_info "Téléchargement de l'assemblage NCBI: $accession"

    # Construire l'URL de l'assemblage
    # Format: GCA_000005845.2 -> GCA/000/005/845/GCA_000005845.2
    local acc_prefix="${accession:0:3}"  # GCA ou GCF
    local acc_number="${accession:4}"     # 000005845.2
    acc_number="${acc_number%%.*}"        # 000005845 (sans version)

    # Créer le chemin FTP
    local part1="${acc_number:0:3}"
    local part2="${acc_number:3:3}"
    local part3="${acc_number:6:3}"

    local ftp_path="https://ftp.ncbi.nlm.nih.gov/genomes/all/${acc_prefix}/${part1}/${part2}/${part3}"

    log_info "  Recherche de l'assemblage sur NCBI FTP..."

    # Essayer de trouver le répertoire exact
    local assembly_dir=$(wget -q --timeout=30 -O - "$ftp_path/" 2>/dev/null | grep -oP "href=\"${accession}[^\"]*\"" | head -1 | tr -d '"' | sed 's/href=//')

    # Nettoyer le nom du répertoire (enlever le / à la fin s'il existe)
    assembly_dir="${assembly_dir%/}"

    if [[ -z "$assembly_dir" ]]; then
        # Essayer sans version
        assembly_dir=$(wget -q --timeout=30 -O - "$ftp_path/" 2>/dev/null | grep -oP "href=\"${acc_prefix}_${acc_number}[^\"]*\"" | head -1 | tr -d '"' | sed 's/href=//')
        assembly_dir="${assembly_dir%/}"
    fi

    if [[ -n "$assembly_dir" ]]; then
        local full_url="${ftp_path}/${assembly_dir}/${assembly_dir}_genomic.fna.gz"
        log_info "  Téléchargement depuis: $full_url"

        # Utiliser || true pour éviter que set -e arrête le script si wget échoue (404, timeout, etc.)
        wget -q --timeout=120 -O "${DOWNLOADED_FILE}.gz" "$full_url" 2>> "$LOG_FILE" || {
            log_warn "  Téléchargement wget échoué (URL peut-être invalide)"
            rm -f "${DOWNLOADED_FILE}.gz" 2>/dev/null
        }

        if [[ -f "${DOWNLOADED_FILE}.gz" ]] && [[ -s "${DOWNLOADED_FILE}.gz" ]]; then
            gunzip -f "${DOWNLOADED_FILE}.gz" 2>> "$LOG_FILE"
            if [[ -f "$DOWNLOADED_FILE" ]] && [[ -s "$DOWNLOADED_FILE" ]]; then
                log_success "Assemblage téléchargé: $DOWNLOADED_FILE"
                return 0
            fi
        fi
    fi

    # Fallback: utiliser datasets CLI de NCBI si disponible
    if command -v datasets > /dev/null 2>&1; then
        log_info "  Fallback: Utilisation de NCBI datasets CLI..."
        datasets download genome accession "$accession" --filename "${output_dir}/${accession}.zip" 2>> "$LOG_FILE"

        if [[ -f "${output_dir}/${accession}.zip" ]]; then
            unzip -q -o "${output_dir}/${accession}.zip" -d "${output_dir}/temp_${accession}" 2>> "$LOG_FILE"
            find "${output_dir}/temp_${accession}" -name "*.fna" -exec cp {} "$DOWNLOADED_FILE" \;
            rm -rf "${output_dir}/temp_${accession}" "${output_dir}/${accession}.zip"

            if [[ -f "$DOWNLOADED_FILE" ]] && [[ -s "$DOWNLOADED_FILE" ]]; then
                log_success "Assemblage téléchargé via datasets: $DOWNLOADED_FILE"
                return 0
            fi
        fi
    fi

    log_error "Échec du téléchargement de l'assemblage $accession"
    DOWNLOADED_FILE=""
    return 1
}

# Fonction pour copier un fichier FASTA local
# Retourne le chemin du fichier via la variable globale DOWNLOADED_FILE
setup_local_fasta() {
    local source_file="$1"
    local output_dir="$2"
    local sample_id="$3"
    DOWNLOADED_FILE="$output_dir/${sample_id}.fasta"

    log_info "Configuration du fichier FASTA local: $source_file"

    if [[ ! -f "$source_file" ]]; then
        log_error "Fichier FASTA introuvable: $source_file"
        DOWNLOADED_FILE=""
        return 1
    fi

    # Copier le fichier
    cp "$source_file" "$DOWNLOADED_FILE" 2>> "$LOG_FILE"

    if [[ -f "$DOWNLOADED_FILE" ]]; then
        log_success "Fichier FASTA configuré: $DOWNLOADED_FILE"
        return 0
    else
        log_error "Échec de la copie du fichier FASTA"
        DOWNLOADED_FILE=""
        return 1
    fi
}

#===============================================================================
# SECTION 6.8 : GESTION DES BASES DE DONNÉES (AMRFINDER, CARD, etc.)
#===============================================================================

# Emplacements possibles pour les bases de données (ordre de priorité)
# 1. Variables d'environnement (pour utilisateurs avancés/serveurs)
# 2. Dans l'architecture du pipeline (portable)
# 3. Dans HOME partagé (économie d'espace multi-projets)

DB_SHARED_DIR="$HOME/.local/share/pipeline_arg_databases"

# Fonction pour trouver la base AMRFinder
find_amrfinder_db() {
    local found_path=""

    # 1. Variable d'environnement
    if [[ -n "${AMRFINDER_DB_PATH:-}" ]] && [[ -d "$AMRFINDER_DB_PATH" ]]; then
        if [[ -f "$AMRFINDER_DB_PATH/AMRProt" ]] || [[ -f "$AMRFINDER_DB_PATH/AMRProt.fa" ]] || [[ -f "$AMRFINDER_DB_PATH/AMR.LIB" ]]; then
            found_path="$AMRFINDER_DB_PATH"
        fi
    fi

    # 2. Emplacement par défaut d'AMRFinder (géré par amrfinder --force_update)
    if [[ -z "$found_path" ]]; then
        local default_amr="$HOME/.local/share/amrfinder/latest"
        if [[ -d "$default_amr" ]]; then
            found_path="$default_amr"
        fi
    fi

    # 3. Dans l'architecture du pipeline (fichiers au niveau racine ou dans latest/)
    if [[ -z "$found_path" ]] && [[ -d "$DB_DIR/amrfinder_db" ]]; then
        if [[ -f "$DB_DIR/amrfinder_db/AMRProt" ]] || [[ -f "$DB_DIR/amrfinder_db/AMRProt.fa" ]] || [[ -f "$DB_DIR/amrfinder_db/AMR.LIB" ]]; then
            found_path="$DB_DIR/amrfinder_db"
        elif [[ -f "$DB_DIR/amrfinder_db/latest/AMRProt" ]] || [[ -f "$DB_DIR/amrfinder_db/latest/AMRProt.fa" ]] || [[ -f "$DB_DIR/amrfinder_db/latest/AMR.LIB" ]]; then
            found_path="$DB_DIR/amrfinder_db/latest"
        fi
    fi

    # 4. Dans HOME partagé
    if [[ -z "$found_path" ]] && [[ -d "$DB_SHARED_DIR/amrfinder_db" ]]; then
        if [[ -f "$DB_SHARED_DIR/amrfinder_db/AMRProt" ]] || [[ -f "$DB_SHARED_DIR/amrfinder_db/AMRProt.fa" ]] || [[ -f "$DB_SHARED_DIR/amrfinder_db/AMR.LIB" ]]; then
            found_path="$DB_SHARED_DIR/amrfinder_db"
        fi
    fi

    echo "$found_path"
}

# Fonction pour télécharger/mettre à jour AMRFinder DB
download_amrfinder_db() {
    local target_dir="$1"
    local download_success=false

    echo ""
    echo "Téléchargement/Mise à jour de la base AMRFinder..."
    echo ""

    # AMRFinder est disponible dans l'env megam_arg (activé par défaut dans Docker)

    # AMRFinder gère son propre téléchargement via --force_update
    if [[ -n "$target_dir" ]]; then
        mkdir -p "$target_dir"
        # Utiliser le répertoire spécifié avec l'option --database
        echo "Téléchargement dans: $target_dir"
        if amrfinder_update --force_update --database "$target_dir" 2>&1; then
            download_success=true
        elif amrfinder --force_update --database "$target_dir" 2>&1; then
            download_success=true
        fi
    fi

    # Si échec avec répertoire personnalisé, essayer l'emplacement par défaut
    if [[ "$download_success" == false ]]; then
        echo "Utilisation de l'emplacement par défaut AMRFinder..."
        if amrfinder --force_update 2>&1; then
            download_success=true
            # Copier vers le répertoire cible si spécifié
            if [[ -n "$target_dir" ]] && [[ -d "$HOME/.local/share/amrfinder/latest" ]]; then
                echo "Copie des fichiers vers $target_dir..."
                cp -r "$HOME/.local/share/amrfinder/latest/"* "$target_dir/" 2>/dev/null || true
            fi
        fi
    fi

    if [[ "$download_success" == true ]]; then
        echo "✅ Base AMRFinder installée"
        return 0
    else
        echo "❌ Échec de la mise à jour AMRFinder"
        return 1
    fi
}

# Téléchargement de la base CARD pour RGI
download_card_db() {
    local target_dir="$1"
    local download_success=false

    echo ""
    echo "Téléchargement de la base CARD pour RGI..."
    echo ""

    mkdir -p "$target_dir"
    cd "$target_dir" || return 1

    # MÉTHODE 1: Téléchargement direct depuis card.mcmaster.ca
    # URLs des fichiers CARD
    local CARD_URL="https://card.mcmaster.ca/latest/data"
    local CARD_VARIANTS_URL="https://card.mcmaster.ca/latest/variants"

    echo "  [Méthode 1] Téléchargement direct depuis card.mcmaster.ca..."
    if wget -q --show-progress -O card.tar.bz2 "$CARD_URL" 2>&1; then
        tar -xjf card.tar.bz2 2>/dev/null
        rm -f card.tar.bz2
        download_success=true
        echo "  ✅ Téléchargement réussi"
    else
        echo "  ❌ Échec du téléchargement direct"
    fi

    # MÉTHODE 2: Alternative via RGI
    if [[ "$download_success" == false ]]; then
        echo ""
        echo "  [Méthode 2] Tentative via RGI auto_load..."

        if command -v rgi &> /dev/null; then
            # Utiliser rgi auto_load qui télécharge automatiquement les données
            if rgi auto_load 2>&1; then
                # Copier les fichiers depuis le répertoire RGI vers target_dir
                local rgi_data_dir=$(python -c "import pkg_resources; print(pkg_resources.resource_filename('app', 'data'))" 2>/dev/null)
                if [[ -d "$rgi_data_dir" ]] && [[ -f "$rgi_data_dir/card.json" ]]; then
                    cp -r "$rgi_data_dir"/* "$target_dir/"
                    download_success=true
                    echo "  ✅ Base téléchargée via RGI"
                fi
            fi
        fi
    fi

    # MÉTHODE 3: Alternative via abricate
    if [[ "$download_success" == false ]]; then
        echo ""
        echo "  [Méthode 3] Tentative via abricate..."

        # Utiliser abricate via mamba run (env séparé dans Docker)
        if mamba run --no-banner -n abricate_env abricate --version &> /dev/null; then
            echo "  abricate trouvé, vérification de la base CARD..."

                # Vérifier si CARD est disponible dans abricate
                if mamba run --no-banner -n abricate_env abricate --list 2>/dev/null | grep -q "card"; then
                    echo "  Base CARD trouvée dans abricate"

                    # Chercher le répertoire de la base CARD
                    local abricate_card_dir=""
                    for path in "${CONDA_PREFIX:-}/db/card" "$HOME/abricate/db/card" "/usr/local/share/abricate/db/card" "/opt/abricate/db/card"; do
                        if [[ -d "$path" ]] && [[ -f "$path/sequences" ]]; then
                            abricate_card_dir="$path"
                            echo "  Trouvée dans: $abricate_card_dir"
                            break
                        fi
                    done

                    if [[ -n "$abricate_card_dir" ]] && [[ -f "$abricate_card_dir/sequences" ]]; then
                        # Copier les séquences CARD d'abricate
                        echo "  Copie des séquences CARD d'abricate..."
                        cp "$abricate_card_dir/sequences" "$target_dir/card_sequences.fasta"

                        # Copier aussi les index BLAST si disponibles
                        if ls "$abricate_card_dir"/sequences.n* &> /dev/null; then
                            cp "$abricate_card_dir"/sequences.n* "$target_dir/" 2>/dev/null || true
                        fi

                        echo ""
                        echo "  ✅ Base CARD d'abricate installée"
                        echo "  ⚠️  Note: Utilisation des séquences CARD d'abricate (solution de secours)"
                        echo "  ℹ️  Pour les fonctionnalités complètes de RGI, le fichier card.json est nécessaire"
                        echo "  ℹ️  Le pipeline continuera avec les analyses disponibles"
                        download_success=true
                    else
                        echo "  ❌ Impossible de localiser le répertoire CARD d'abricate"
                    fi
                else
                    echo "  Base CARD non trouvée dans abricate, tentative de mise à jour..."
                    if mamba run --no-banner -n abricate_env abricate --setupdb 2>&1 | grep -i "card"; then
                        echo "  Base CARD mise à jour, nouvelle tentative..."
                        # Réessayer après mise à jour
                        for path in "${CONDA_PREFIX:-}/db/card" "$HOME/abricate/db/card"; do
                            if [[ -d "$path" ]] && [[ -f "$path/sequences" ]]; then
                                cp "$path/sequences" "$target_dir/card_sequences.fasta"
                                download_success=true
                                echo "  ✅ Base CARD d'abricate installée"
                                break
                            fi
                        done
                    fi
                fi
        else
            echo "  abricate non disponible dans l'image Docker"
        fi
    fi

    # Si téléchargement réussi avec la méthode 1, télécharger aussi les variants
    if [[ "$download_success" == true ]] && [[ -f "$target_dir/card.json" ]]; then
        echo ""
        echo "  Téléchargement des variants CARD..."
        if wget -q --show-progress -O variants.tar.bz2 "$CARD_VARIANTS_URL" 2>&1; then
            tar -xjf variants.tar.bz2 2>/dev/null
            rm -f variants.tar.bz2
            echo "  ✅ Variants téléchargés"
        else
            echo "  ⚠️  Variants non téléchargés (optionnel)"
        fi
    fi

    # Charger la base avec RGI si card.json existe
    if [[ -f "$target_dir/card.json" ]]; then
        echo ""
        echo "  Chargement de la base dans RGI..."

        # RGI est dans l'env megam_arg (activé par défaut dans Docker)
        # Charger card.json
        rgi load --card_json "$target_dir/card.json" \
                 --local \
                 --data_path "$target_dir" 2>&1 || true

        # Charger les variants si disponibles
        if [[ -d "$target_dir/wildcard" ]] || [[ -f "$target_dir/wildcard_database_v"*.fasta ]]; then
            local wildcard_fasta=$(ls "$target_dir"/wildcard_database_v*.fasta 2>/dev/null | head -1)
            local wildcard_index=$(ls "$target_dir"/wildcard/index-for-model-sequences.txt 2>/dev/null | head -1)

            if [[ -n "$wildcard_fasta" ]]; then
                rgi load --wildcard_annotation "$wildcard_fasta" \
                         --wildcard_index "$wildcard_index" \
                         --card_annotation "$target_dir/card_database_v"*.fasta \
                         --local \
                         --data_path "$target_dir" 2>&1 || true
            fi
        fi

        # Créer l'index DIAMOND
        echo "  Création de l'index DIAMOND..."
        if command -v diamond &> /dev/null; then
            rgi card_annotation --local --data_path "$target_dir" 2>&1 || true
            rgi load --card_annotation "$target_dir"/card_database_v*.fasta \
                     --local \
                     --data_path "$target_dir" 2>&1 || true
        fi
    fi

    cd - > /dev/null

    if [[ "$download_success" == true ]]; then
        if [[ -f "$target_dir/card.json" ]] || [[ -f "$target_dir/card_sequences.fasta" ]]; then
            echo ""
            echo "✅ Base CARD installée dans $target_dir"
            return 0
        fi
    fi

    echo ""
    echo "❌ ERREUR CRITIQUE: Échec de l'installation CARD avec toutes les méthodes"
    echo "   La base CARD est essentielle pour ce pipeline."
    echo "   Veuillez vérifier votre connexion internet et réessayer."
    return 1
}

# Téléchargement de la base PointFinder
download_pointfinder_db() {
    local target_dir="$1"

    echo ""
    echo "Téléchargement de la base PointFinder..."
    echo ""

    mkdir -p "$target_dir"

    # Cloner le repository PointFinder
    if [[ -d "$target_dir/pointfinder_db" ]] && [[ -f "$target_dir/pointfinder_db/config" ]]; then
        echo "  Base PointFinder déjà présente, mise à jour..."
        cd "$target_dir/pointfinder_db" && git pull 2>&1 || true
        cd - > /dev/null
    else
        echo "  Clonage du repository PointFinder..."
        rm -rf "$target_dir/pointfinder_db" 2>/dev/null
        if git clone https://bitbucket.org/genomicepidemiology/pointfinder_db.git "$target_dir/pointfinder_db" 2>&1; then
            echo "✅ Base PointFinder installée"
            return 0
        else
            echo "❌ Échec du clonage PointFinder"
            return 1
        fi
    fi

    return 0
}

# Fonction pour trouver la base CARD
find_card_db() {
    local found_path=""

    # Chercher dans DB_DIR
    if [[ -d "$DB_DIR/card_db" ]] && [[ -f "$DB_DIR/card_db/card.json" ]]; then
        found_path="$DB_DIR/card_db"
    # Chercher dans localDB (ancien emplacement)
    elif [[ -d "$WORK_DIR/localDB" ]] && [[ -f "$WORK_DIR/localDB/card.json" ]]; then
        found_path="$WORK_DIR/localDB"
    # Chercher dans home
    elif [[ -d "$HOME/.local/share/rgi" ]] && [[ -f "$HOME/.local/share/rgi/card.json" ]]; then
        found_path="$HOME/.local/share/rgi"
    fi

    echo "$found_path"
}

# Fonction pour trouver la base PointFinder
find_pointfinder_db() {
    local found_path=""

    # Chercher dans DB_DIR
    if [[ -d "$DB_DIR/pointfinder_db" ]] && [[ -f "$DB_DIR/pointfinder_db/config" ]]; then
        found_path="$DB_DIR/pointfinder_db"
    # Chercher dans home
    elif [[ -d "$HOME/databases/pointfinder_db" ]] && [[ -f "$HOME/databases/pointfinder_db/config" ]]; then
        found_path="$HOME/databases/pointfinder_db"
    fi

    echo "$found_path"
}

# Fonction pour trouver la base MLST
find_mlst_db() {
    local found_path=""

    # Chercher dans DB_DIR
    if [[ -d "$DB_DIR/mlst_db/db" ]] && [[ -d "$DB_DIR/mlst_db/db/pubmlst" ]]; then
        found_path="$DB_DIR/mlst_db"
    # Chercher dans l'env mamba activé
    elif [[ -d "${CONDA_PREFIX:-}/share/mlst/db" ]]; then
        found_path="${CONDA_PREFIX:-}/share/mlst"
    fi

    echo "$found_path"
}

# Téléchargement de la base MLST
download_mlst_db() {
    local target_dir="$1"

    echo ""
    echo "Téléchargement de la base MLST..."
    echo ""

    mkdir -p "$target_dir"

    # mlst est dans l'env megam_arg (activé par défaut dans Docker)
    # Copier la base depuis l'environnement mamba
    if [[ -d "${CONDA_PREFIX:-}/share/mlst" ]]; then
        cp -r "${CONDA_PREFIX:-}/share/mlst/"* "$target_dir/"
        echo "✅ Base MLST copiée depuis l'environnement mamba"
    else
        # Télécharger via mlst-download_pub_mlst
        echo "  Téléchargement des schémas MLST..."
        mkdir -p "$target_dir/db/pubmlst" "$target_dir/db/blast"
        # mlst télécharge automatiquement les schémas au premier usage
        echo "⚠️  La base MLST sera téléchargée automatiquement au premier usage"
    fi

    return 0
}

# Vérification des bases de données abricate
find_abricate_dbs() {
    local abricate_found=false
    local abricate_env=""

    # Vérifier abricate dans l'env abricate_env via mamba run (Docker)
    if mamba run --no-banner -n abricate_env abricate --version &> /dev/null; then
        abricate_found=true
        abricate_env="abricate_env"
    elif command -v abricate &> /dev/null; then
        abricate_found=true
    else
        echo ""
        return
    fi

    # Vérifier si les bases abricate sont installées
    local abricate_list=""
    if [[ -n "$abricate_env" ]]; then
        abricate_list=$(mamba run --no-banner -n abricate_env abricate --list 2>/dev/null)
    else
        abricate_list=$(abricate --list 2>/dev/null)
    fi

    if [[ -z "$abricate_list" ]]; then
        echo ""
        return
    fi

    # Vérifier que les bases essentielles sont présentes
    local has_resfinder=$(echo "$abricate_list" | grep -w "resfinder" | wc -l)
    local has_card=$(echo "$abricate_list" | grep -w "card" | wc -l)
    local has_ncbi=$(echo "$abricate_list" | grep -w "ncbi" | wc -l)
    local has_plasmidfinder=$(echo "$abricate_list" | grep -w "plasmidfinder" | wc -l)

    # Si toutes les bases essentielles sont présentes
    if [[ $has_resfinder -gt 0 ]] && [[ $has_card -gt 0 ]] && [[ $has_ncbi -gt 0 ]] && [[ $has_plasmidfinder -gt 0 ]]; then
        echo "found"
    else
        echo ""
    fi
}

# Installation/mise à jour des bases de données abricate
setup_abricate_dbs() {
    echo ""
    echo "Installation des bases de données abricate..."
    echo ""

    # Vérifier abricate dans l'env abricate_env (Docker)
    local abricate_found=false

    echo "  Recherche d'abricate dans l'environnement abricate_env..."
    if mamba run --no-banner -n abricate_env abricate --version &> /dev/null; then
        abricate_found=true
        echo "  ✅ abricate trouvé dans l'environnement abricate_env"
    elif command -v abricate &> /dev/null; then
        echo "  ✅ abricate trouvé dans l'environnement actuel"
        abricate_found=true
    fi

    # Si abricate n'est pas trouvé du tout
    if [[ "$abricate_found" == false ]]; then
        echo ""
        echo "❌ abricate n'est pas installé ou accessible"
        echo "   Outil non disponible dans l'image Docker"
        echo ""
        return 1
    fi

    echo "  Téléchargement et indexation des bases abricate..."
    echo "  Cela peut prendre quelques minutes..."
    echo ""

    # Exécuter abricate --setupdb via mamba run
    if mamba run --no-banner -n abricate_env abricate --setupdb 2>&1 | tee /tmp/abricate_setup.log; then
        echo ""

        # Vérifier que les bases sont bien installées
        local installed_dbs=$(mamba run --no-banner -n abricate_env abricate --list 2>/dev/null | tail -n +2 | awk '{print $1}')

        if [[ -n "$installed_dbs" ]]; then
            echo "✅ Bases abricate installées:"
            mamba run --no-banner -n abricate_env abricate --list 2>/dev/null | grep -E "resfinder|card|ncbi|plasmidfinder|vfdb|argannot|megares" | while read line; do
                local db_name=$(echo "$line" | awk '{print $1}')
                local db_seqs=$(echo "$line" | awk '{print $2}')
                echo "   - $db_name ($db_seqs séquences)"
            done
            echo ""

            return 0
        else
            echo "⚠️  Les bases semblent installées mais ne sont pas listées"
            return 1
        fi
    else
        echo ""
        echo "❌ Échec de l'installation des bases abricate"
        echo "   Consultez /tmp/abricate_setup.log pour plus de détails"

        return 1
    fi
}

#===============================================================================
# FONCTIONS DE MISE À JOUR DES BASES DE DONNÉES
#===============================================================================

# Mise à jour de la base AMRFinder
update_amrfinder_db() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "MISE À JOUR DE LA BASE AMRFINDER"
    echo "═══════════════════════════════════════════════════════════════════"

    local amr_path=$(find_amrfinder_db)
    if [[ -z "$amr_path" ]]; then
        amr_path="$DB_DIR/amrfinder_db"
        mkdir -p "$amr_path"
    fi

    echo "Chemin: $amr_path"

    # AMRFinder est dans l'env megam_arg (activé par défaut dans Docker)
    echo "Téléchargement de la dernière version..."
    if amrfinder_update --force_update --database "$amr_path" 2>&1; then
        echo "✅ Base AMRFinder mise à jour"
    elif amrfinder --force_update --database "$amr_path" 2>&1; then
        echo "✅ Base AMRFinder mise à jour"
    else
        echo "❌ Échec de la mise à jour AMRFinder"
    fi
}

# Mise à jour de la base CARD (RGI)
update_card_db() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "MISE À JOUR DE LA BASE CARD (RGI)"
    echo "═══════════════════════════════════════════════════════════════════"

    local card_path=$(find_card_db)
    if [[ -z "$card_path" ]]; then
        card_path="$DB_DIR/card_db"
    fi

    echo "Chemin: $card_path"
    echo "Téléchargement de la dernière version depuis card.mcmaster.ca..."

    # Sauvegarder l'ancienne version
    if [[ -d "$card_path" ]] && [[ -f "$card_path/card.json" ]]; then
        local backup_dir="${card_path}_backup_$(date +%Y%m%d)"
        echo "Sauvegarde de l'ancienne version dans: $backup_dir"
        mv "$card_path" "$backup_dir"
    fi

    mkdir -p "$card_path"
    download_card_db "$card_path"

    if [[ -f "$card_path/card.json" ]]; then
        echo "✅ Base CARD mise à jour"
        # Supprimer la sauvegarde si succès
        rm -rf "${card_path}_backup_"* 2>/dev/null || true
    else
        echo "❌ Échec - restauration de l'ancienne version"
        rm -rf "$card_path"
        mv "${card_path}_backup_"* "$card_path" 2>/dev/null || true
    fi
}

# Mise à jour de la base MLST
update_mlst_db() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "MISE À JOUR DE LA BASE MLST"
    echo "═══════════════════════════════════════════════════════════════════"

    local mlst_path=$(find_mlst_db)
    if [[ -z "$mlst_path" ]]; then
        mlst_path="$DB_DIR/mlst_db"
    fi

    echo "Chemin: $mlst_path"

    # mlst est dans l'env megam_arg (activé par défaut dans Docker)
    # Copier la base mise à jour depuis l'environnement mamba
    if [[ -d "${CONDA_PREFIX:-}/share/mlst" ]]; then
        echo "Copie depuis l'environnement mamba..."
        rm -rf "$mlst_path"/*
        cp -r "${CONDA_PREFIX:-}/share/mlst/"* "$mlst_path/"
        echo "✅ Base MLST mise à jour"
    else
        echo "❌ Base MLST non trouvée dans l'environnement mamba"
    fi
}

# Mise à jour de la base PointFinder
update_pointfinder_db() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "MISE À JOUR DE LA BASE POINTFINDER"
    echo "═══════════════════════════════════════════════════════════════════"

    local pf_path=$(find_pointfinder_db)
    if [[ -z "$pf_path" ]]; then
        pf_path="$DB_DIR/pointfinder_db"
    fi

    echo "Chemin: $pf_path"

    if [[ -d "$pf_path/.git" ]]; then
        echo "Mise à jour via git pull..."
        cd "$pf_path"
        git pull origin master 2>&1
        cd - > /dev/null
        echo "✅ Base PointFinder mise à jour"
    else
        echo "Re-clonage du repository..."
        rm -rf "$pf_path"
        git clone https://bitbucket.org/genomicepidemiology/pointfinder_db.git "$pf_path" 2>&1
        echo "✅ Base PointFinder mise à jour"
    fi
}

# Mise à jour de la base KMA/ResFinder
update_kma_db() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "MISE À JOUR DE LA BASE KMA/RESFINDER"
    echo "═══════════════════════════════════════════════════════════════════"

    local kma_path="$DB_DIR/kma_db"
    mkdir -p "$kma_path"

    echo "Chemin: $kma_path"
    echo "Téléchargement depuis CGE..."

    # Télécharger ResFinder database
    local resfinder_url="https://bitbucket.org/genomicepidemiology/resfinder_db/get/master.zip"

    cd "$kma_path"
    if wget -q --show-progress -O resfinder_db.zip "$resfinder_url" 2>&1; then
        unzip -o resfinder_db.zip 2>/dev/null
        rm -f resfinder_db.zip

        # Indexer avec KMA si disponible
        if command -v kma_index &> /dev/null; then
            echo "Indexation avec KMA..."
            local db_dir=$(find . -name "*.fsa" -type f -exec dirname {} \; | head -1)
            if [[ -n "$db_dir" ]]; then
                cat "$db_dir"/*.fsa > resfinder_all.fsa
                kma_index -i resfinder_all.fsa -o resfinder 2>&1
                rm -f resfinder_all.fsa
            fi
        fi
        echo "✅ Base KMA/ResFinder mise à jour"
    else
        echo "❌ Échec du téléchargement"
    fi
    cd - > /dev/null
}

# Mise à jour de toutes les bases
update_all_databases() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║         MISE À JOUR DE TOUTES LES BASES DE DONNÉES            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Bases à mettre à jour:"
    echo "  1. AMRFinder"
    echo "  2. CARD (RGI)"
    echo "  3. MLST"
    echo "  4. PointFinder"
    echo "  5. KMA/ResFinder"
    echo ""
    read -p "Continuer avec la mise à jour? (o/n): " confirm

    if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
        echo "Mise à jour annulée"
        exit 0
    fi

    # Mettre à jour chaque base
    update_amrfinder_db
    update_card_db
    update_mlst_db
    update_pointfinder_db
    update_kma_db

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "✅ MISE À JOUR TERMINÉE"
    echo "═══════════════════════════════════════════════════════════════════"

    exit 0
}

# Traitement de la commande "update" (après définition des fonctions)
if [[ "$UPDATE_MODE" == true ]]; then
    UPDATE_TARGET="${INPUT_ARG2:-all}"

    case "$UPDATE_TARGET" in
        amrfinder|amr)
            update_amrfinder_db
            exit 0
            ;;
        card|rgi)
            update_card_db
            exit 0
            ;;
        mlst)
            update_mlst_db
            exit 0
            ;;
        pointfinder|point)
            update_pointfinder_db
            exit 0
            ;;
        kma|resfinder)
            update_kma_db
            exit 0
            ;;
        all|"")
            update_all_databases
            exit 0
            ;;
        *)
            echo "❌ Base inconnue: $UPDATE_TARGET"
            echo ""
            echo "Bases disponibles:"
            echo "  amrfinder, card, mlst, pointfinder, kma"
            echo ""
            echo "Exemple: $0 update card"
            exit 1
            ;;
    esac
fi

# Menu interactif pour la gestion des bases de données
interactive_database_setup() {
    local amrfinder_found=$(find_amrfinder_db)
    local card_found=$(find_card_db)
    local pointfinder_found=$(find_pointfinder_db)
    local mlst_found=$(find_mlst_db)
    local abricate_found=$(find_abricate_dbs)
    local need_setup=false

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "VÉRIFICATION DES BASES DE DONNÉES"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Vérifier AMRFinder
    if [[ -n "$amrfinder_found" ]]; then
        echo "✅ Base AMRFinder trouvée: $amrfinder_found"
        AMRFINDER_DB="$amrfinder_found"
    else
        echo "⚠️  Base AMRFinder NON TROUVÉE"
        need_setup=true
    fi

    # Vérifier CARD (RGI)
    if [[ -n "$card_found" ]]; then
        echo "✅ Base CARD trouvée: $card_found"
        CARD_DB="$card_found"
    else
        echo "⚠️  Base CARD (RGI) NON TROUVÉE"
        need_setup=true
    fi

    # Vérifier PointFinder
    if [[ -n "$pointfinder_found" ]]; then
        echo "✅ Base PointFinder trouvée: $pointfinder_found"
        POINTFINDER_DB="$pointfinder_found"
    else
        echo "⚠️  Base PointFinder NON TROUVÉE"
        need_setup=true
    fi

    # Vérifier MLST
    if [[ -n "$mlst_found" ]]; then
        echo "✅ Base MLST trouvée: $mlst_found"
        MLST_DB="$mlst_found"
    else
        echo "⚠️  Base MLST NON TROUVÉE"
        need_setup=true
    fi

    # Vérifier Abricate (ResFinder, PlasmidFinder, CARD, NCBI, VFDB)
    if [[ -n "$abricate_found" ]]; then
        echo "✅ Bases Abricate trouvées (ResFinder, PlasmidFinder, CARD, NCBI, VFDB)"
    else
        echo "⚠️  Bases Abricate NON TROUVÉES"
        echo "   (ResFinder, PlasmidFinder, CARD, NCBI, VFDB via abricate)"
        need_setup=true
    fi

    echo ""

    # Si mode force, on continue sans demander
    if [[ "$FORCE_MODE" == true ]]; then
        if [[ "$need_setup" == true ]]; then
            echo "Mode --force: Téléchargement automatique des bases manquantes..."
            echo ""

            if [[ -z "$amrfinder_found" ]]; then
                echo "Installation d'AMRFinder dans l'architecture du pipeline..."
                mkdir -p "$DB_DIR/amrfinder_db"
                download_amrfinder_db "$DB_DIR/amrfinder_db" || echo "⚠️  AMRFinder non installée - le pipeline continuera sans"
                AMRFINDER_DB="$DB_DIR/amrfinder_db"
            fi

            if [[ -z "$card_found" ]]; then
                echo "Installation de CARD (RGI) dans l'architecture du pipeline..."
                mkdir -p "$DB_DIR/card_db"
                download_card_db "$DB_DIR/card_db" || echo "⚠️  CARD non installée - le pipeline continuera sans"
                CARD_DB="$DB_DIR/card_db"
            fi

            if [[ -z "$pointfinder_found" ]]; then
                echo "Installation de PointFinder dans l'architecture du pipeline..."
                download_pointfinder_db "$DB_DIR" || echo "⚠️  PointFinder non installée - le pipeline continuera sans"
                POINTFINDER_DB="$DB_DIR/pointfinder_db"
            fi

            if [[ -z "$mlst_found" ]]; then
                echo "Installation de MLST dans l'architecture du pipeline..."
                mkdir -p "$DB_DIR/mlst_db"
                download_mlst_db "$DB_DIR/mlst_db" || echo "⚠️  MLST non installée - le pipeline continuera sans"
                MLST_DB="$DB_DIR/mlst_db"
            fi

            if [[ -z "$abricate_found" ]]; then
                echo "Installation des bases abricate..."
                setup_abricate_dbs || echo "⚠️  Bases abricate non installées - le pipeline continuera sans"
            fi
        fi
        return 0
    fi

    # Mode interactif si des bases manquent
    if [[ "$need_setup" == true ]]; then
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║     INSTALLATION DES BASES DE DONNÉES REQUISES                 ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Les bases de données sont nécessaires pour l'analyse."
        echo ""
        echo "Options d'installation:"
        echo ""
        echo "  1) Télécharger dans le PIPELINE (portable - recommandé)"
        echo "     → $DB_DIR/"
        echo ""
        echo "  2) Télécharger dans HOME PARTAGÉ (économie d'espace)"
        echo "     → $DB_SHARED_DIR/"
        echo ""
        echo "  3) J'ai déjà les bases ailleurs (spécifier les chemins)"
        echo ""
        echo "  4) Continuer SANS les bases (certaines analyses échoueront)"
        echo ""
        echo "  5) Quitter"
        echo ""

        read -p "Votre choix (1-5): " db_choice

        case $db_choice in
            1)
                # Télécharger dans le pipeline (PORTABLE)
                if [[ -z "$amrfinder_found" ]]; then
                    echo ""
                    echo "Installation d'AMRFinder dans le pipeline..."
                    mkdir -p "$DB_DIR/amrfinder_db"
                    download_amrfinder_db "$DB_DIR/amrfinder_db"
                    AMRFINDER_DB="$DB_DIR/amrfinder_db"
                fi

                if [[ -z "$card_found" ]]; then
                    echo ""
                    echo "Installation de CARD (RGI) dans le pipeline..."
                    mkdir -p "$DB_DIR/card_db"
                    download_card_db "$DB_DIR/card_db"
                    CARD_DB="$DB_DIR/card_db"
                fi

                if [[ -z "$pointfinder_found" ]]; then
                    echo ""
                    echo "Installation de PointFinder dans le pipeline..."
                    download_pointfinder_db "$DB_DIR"
                    POINTFINDER_DB="$DB_DIR/pointfinder_db"
                fi

                if [[ -z "$mlst_found" ]]; then
                    echo ""
                    echo "Installation de MLST dans le pipeline..."
                    mkdir -p "$DB_DIR/mlst_db"
                    download_mlst_db "$DB_DIR/mlst_db"
                    MLST_DB="$DB_DIR/mlst_db"
                fi

                if [[ -z "$abricate_found" ]]; then
                    echo ""
                    echo "Installation des bases abricate (ResFinder, PlasmidFinder, etc.)..."
                    setup_abricate_dbs
                fi
                ;;
            2)
                # Télécharger dans HOME partagé
                mkdir -p "$DB_SHARED_DIR"

                if [[ -z "$amrfinder_found" ]]; then
                    echo ""
                    echo "Installation d'AMRFinder dans HOME partagé..."
                    mkdir -p "$DB_SHARED_DIR/amrfinder_db"
                    download_amrfinder_db "$DB_SHARED_DIR/amrfinder_db"
                    AMRFINDER_DB="$DB_SHARED_DIR/amrfinder_db"
                fi

                if [[ -z "$card_found" ]]; then
                    echo ""
                    echo "Installation de CARD (RGI) dans HOME partagé..."
                    mkdir -p "$DB_SHARED_DIR/card_db"
                    download_card_db "$DB_SHARED_DIR/card_db"
                    CARD_DB="$DB_SHARED_DIR/card_db"
                fi

                if [[ -z "$pointfinder_found" ]]; then
                    echo ""
                    echo "Installation de PointFinder dans HOME partagé..."
                    download_pointfinder_db "$DB_SHARED_DIR"
                    POINTFINDER_DB="$DB_SHARED_DIR/pointfinder_db"
                fi

                if [[ -z "$mlst_found" ]]; then
                    echo ""
                    echo "Installation de MLST dans HOME partagé..."
                    mkdir -p "$DB_SHARED_DIR/mlst_db"
                    download_mlst_db "$DB_SHARED_DIR/mlst_db"
                    MLST_DB="$DB_SHARED_DIR/mlst_db"
                fi

                if [[ -z "$abricate_found" ]]; then
                    echo ""
                    echo "Installation des bases abricate (ResFinder, PlasmidFinder, etc.)..."
                    setup_abricate_dbs
                fi
                ;;
            3)
                # Chemins personnalisés
                if [[ -z "$amrfinder_found" ]]; then
                    echo ""
                    read -p "Chemin vers la base AMRFinder: " custom_amr
                    if [[ -d "$custom_amr" ]]; then
                        AMRFINDER_DB="$custom_amr"
                        echo "✅ Base AMRFinder configurée: $AMRFINDER_DB"
                    else
                        echo "❌ Chemin AMRFinder invalide"
                    fi
                fi
                ;;
            4)
                # Continuer sans bases
                echo ""
                echo "⚠️  Attention: Certaines analyses échoueront sans les bases de données."
                echo "   - AMRFinder sera ignoré"
                echo ""
                AMRFINDER_DB=""
                ;;
            5)
                echo "Exécution annulée."
                exit 0
                ;;
            *)
                echo "Option invalide. Utilisation de l'option 1 par défaut."
                # Fallback to option 1 (portable)
                if [[ -z "$amrfinder_found" ]]; then
                    mkdir -p "$DB_DIR/amrfinder_db"
                    download_amrfinder_db "$DB_DIR/amrfinder_db"
                    AMRFINDER_DB="$DB_DIR/amrfinder_db"
                fi
                ;;
        esac
    fi

    echo ""
    echo "Configuration des bases de données:"
    echo "  AMRFINDER_DB: ${AMRFINDER_DB:-NON CONFIGURÉ}"
    echo "  CARD_DB: ${CARD_DB:-NON CONFIGURÉ}"
    echo "  POINTFINDER_DB: ${POINTFINDER_DB:-NON CONFIGURÉ}"
    echo "  MLST_DB: ${MLST_DB:-NON CONFIGURÉ}"
    if [[ -n "$abricate_found" ]]; then
        echo "  ABRICATE_DBs: ✅ Installées (ResFinder, PlasmidFinder, CARD, NCBI, VFDB)"
    else
        echo "  ABRICATE_DBs: ⚠️  NON INSTALLÉES"
    fi
    echo ""
}

#===============================================================================
# SECTION 7 : GESTION DES VERSIONS ET RÉSULTATS
#===============================================================================

# Fonction pour vérifier les anciens résultats
check_old_results() {
    log_info "═══════════════════════════════════════════════════════════════════"
    log_info "VÉRIFICATION DES ANCIENS RÉSULTATS"
    log_info "═══════════════════════════════════════════════════════════════════"
    
    local old_results=$(find "$WORK_DIR/outputs" -maxdepth 1 -type d -name "${SAMPLE_ID}_*" 2>/dev/null | sort -r)
    
    if [[ -z "$old_results" ]]; then
        log_info "Aucun résultat antérieur trouvé pour $SAMPLE_ID"
        return 0
    fi
    
    log_warn "Résultats antérieurs détectés:"
    echo "$old_results" | while read -r dir; do
        local size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        local last_modified=$(stat -f %Sm -t '%Y-%m-%d %H:%M:%S' "$dir" 2>/dev/null || stat -c %y "$dir" 2>/dev/null | cut -d' ' -f1-2)
        log_warn "  - $(basename "$dir") (${size})"
    done
    
    return 1  # Indique qu'il y a des anciens résultats
}

# Fonction pour archiver les résultats
archive_old_results() {
    local source_dir=$1
    local archive_name="${ARCHIVE_DIR}/$(basename "$source_dir")_archive_$(date '+%Y%m%d_%H%M%S').tar.gz"
    
    mkdir -p "$ARCHIVE_DIR"
    
    log_info "Archivage en cours: $source_dir"
    log_info "Destination: $archive_name"
    
    if tar -czf "$archive_name" -C "$(dirname "$source_dir")" "$(basename "$source_dir")" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Archivage réussi"
        log_info "Taille de l'archive: $(du -sh "$archive_name" | cut -f1)"
        return 0
    else
        log_error "Erreur lors de l'archivage"
        return 1
    fi
}

# Fonction pour nettoyer les anciens résultats
cleanup_old_results() {
    local source_dir=$1
    
    log_info "Nettoyage de: $source_dir"
    
    if rm -rf "$source_dir" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Nettoyage réussi"
        return 0
    else
        log_error "Erreur lors du nettoyage"
        return 1
    fi
}

# Fonction pour afficher les options de gestion interactives
interactive_result_management() {
    local old_results=$(find "$WORK_DIR/outputs" -maxdepth 1 -type d -name "${SAMPLE_ID}_*" 2>/dev/null | sort -r)

    if [[ -z "$old_results" ]]; then
        return 0  # Pas de résultats antérieurs
    fi

    # Mode force : continuer automatiquement sans demander
    if [[ "$FORCE_MODE" == true ]]; then
        log_info "Mode --force actif : création d'une nouvelle version sans confirmation"
        log_info "Les anciens résultats resteront dans: $WORK_DIR/outputs/"
        return 0
    fi

    log_info ""
    log_info "╔════════════════════════════════════════════════════════════════╗"
    log_info "║         GESTION DES RÉSULTATS ANTÉRIEURS                       ║"
    log_info "╚════════════════════════════════════════════════════════════════╝"
    log_info ""
    log_warn "⚠️  Des résultats antérieurs ont été détectés pour $SAMPLE_ID"
    log_info ""
    log_info "Options:"
    log_info "  1) Continuer (créer une nouvelle version)"
    log_info "  2) Archiver les anciens résultats PUIS créer une nouvelle version"
    log_info "  3) Nettoyer les anciens résultats PUIS créer une nouvelle version"
    log_info "  4) Archiver ET nettoyer PUIS créer une nouvelle version"
    log_info "  5) Quitter sans rien faire"
    log_info ""

    read -p "Choisissez une option (1-5): " choice
    
    case $choice in
        1)
            log_info "✅ Nouvelle version créée: $RESULTS_VERSION"
            log_info "Les anciens résultats resteront dans: $WORK_DIR/outputs/"
            ;;
        2)
            log_info "Archivage en cours des anciens résultats..."
            echo "$old_results" | while read -r dir; do
                archive_old_results "$dir"
            done
            log_success "✅ Anciens résultats archivés dans: $ARCHIVE_DIR"
            ;;
        3)
            log_warn "⚠️  ATTENTION: Les anciens résultats vont être SUPPRIMÉS"
            read -p "Êtes-vous sûr? (oui/non): " confirm
            if [[ "$confirm" == "oui" ]]; then
                echo "$old_results" | while read -r dir; do
                    cleanup_old_results "$dir"
                done
                log_success "✅ Anciens résultats supprimés"
            else
                log_info "Opération annulée"
            fi
            ;;
        4)
            log_info "Archivage et nettoyage en cours..."
            echo "$old_results" | while read -r dir; do
                archive_old_results "$dir" && cleanup_old_results "$dir"
            done
            log_success "✅ Anciens résultats archivés et supprimés"
            ;;
        5)
            log_error "Exécution annulée par l'utilisateur"
            exit 0
            ;;
        *)
            log_error "Option invalide"
            exit 1
            ;;
    esac
    
    log_info ""
}

# Fonction pour vérifier les prérequis
check_prerequisites() {
    log_info "Vérification des prérequis..."

    # Vérifier les fichiers input
    if [[ ! -f "$READ1" ]] && [[ ! -f "${READ1}.gz" ]]; then
        log_error "Fichier READ1 introuvable: $READ1"
        return 1
    fi

    # Vérifier READ2 seulement en mode paired-end
    if [[ "$IS_SINGLE_END" != true ]]; then
        if [[ ! -f "$READ2" ]] && [[ ! -f "${READ2}.gz" ]]; then
            log_error "Fichier READ2 introuvable: $READ2"
            return 1
        fi
    fi

    log_success "Tous les prérequis sont satisfaits"
    return 0
}

# [Docker] Les environnements mamba sont pré-installés dans l'image Docker.
# La fonction create_env_if_needed() n'est pas nécessaire.

#===============================================================================
# SECTION 8 : AFFICHAGE DU DÉMARRAGE
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "PIPELINE ARG v3.2 - DÉMARRAGE"
log_info "═══════════════════════════════════════════════════════════════════"
log_info ""
log_info "Configuration:"
log_info "  Échantillon: $SAMPLE_ID"
log_info "  Type d'entrée: $INPUT_TYPE"
log_info "  FASTA pré-assemblé: $IS_ASSEMBLED_INPUT"
log_info "  Mode Prokka: $PROKKA_MODE"
if [[ "$PROKKA_MODE" == "custom" ]] && [[ -n "$PROKKA_GENUS" ]]; then
    log_info "    → Genre: $PROKKA_GENUS"
    log_info "    → Espèce: ${PROKKA_SPECIES:-non spécifiée}"
fi
log_info "  Version: $RESULTS_VERSION"
log_info "  Répertoire: $RESULTS_DIR"
log_info "  Threads: $THREADS"
log_info "  Archive: $ARCHIVE_DIR"
log_info ""

if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_warn "Mode FASTA assemblé détecté:"
    log_warn "  - Module 1 (QC) sera IGNORÉ"
    log_warn "  - Module 2 (Assemblage) sera IGNORÉ"
    log_warn "  - Module 5 (Variant Calling) sera IGNORÉ"
    log_info ""
fi

#===============================================================================
# SECTION 9 : GESTION DES ANCIENS RÉSULTATS
#===============================================================================

if check_old_results; then
    log_info "Aucun ancien résultat à gérer"
else
    # Il y a des anciens résultats
    interactive_result_management
fi

#===============================================================================
# SECTION 9.5 : CONFIGURATION DES BASES DE DONNÉES
#===============================================================================

# Appeler la fonction de configuration des bases de données
# Cette fonction vérifie si les DB existent et propose de les télécharger si nécessaire
interactive_database_setup

#===============================================================================
# SECTION 10 : TÉLÉCHARGEMENT/PRÉPARATION DES DONNÉES
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "ÉTAPE 0 : TÉLÉCHARGEMENT/PRÉPARATION DES DONNÉES"
log_info "═══════════════════════════════════════════════════════════════════"

# [Docker] Les outils SRA (prefetch, fasterq-dump) sont dans l'env megam_arg déjà activé

mkdir -p "$DATA_DIR"

# Variables pour stocker les chemins des fichiers
READ1=""
READ2=""
ASSEMBLY_FASTA=""
IS_SINGLE_END=false

case "$INPUT_TYPE" in
    sra)
        # ============ MODE SRA (FASTQ) ============
        log_info "Mode SRA détecté - Téléchargement des reads FASTQ..."

        # Vérifier si les fichiers existent déjà localement (paired-end)
        if [[ -f "$DATA_DIR/${SAMPLE_ID}_1.fastq" ]]; then
            log_success "Fichiers FASTQ paired-end trouvés localement"
            READ1="$DATA_DIR/${SAMPLE_ID}_1.fastq"
            READ2="$DATA_DIR/${SAMPLE_ID}_2.fastq"
            IS_SINGLE_END=false
        elif [[ -f "$DATA_DIR/${SAMPLE_ID}_1.fastq.gz" ]]; then
            log_success "Fichiers FASTQ paired-end (.gz) trouvés localement"
            READ1="$DATA_DIR/${SAMPLE_ID}_1.fastq.gz"
            READ2="$DATA_DIR/${SAMPLE_ID}_2.fastq.gz"
            IS_SINGLE_END=false
        # Vérifier si fichier single-end existe
        elif [[ -f "$DATA_DIR/${SAMPLE_ID}.fastq" ]]; then
            log_success "Fichier FASTQ single-end trouvé localement"
            READ1="$DATA_DIR/${SAMPLE_ID}.fastq"
            READ2=""
            IS_SINGLE_END=true
        elif [[ -f "$DATA_DIR/${SAMPLE_ID}.fastq.gz" ]]; then
            log_success "Fichier FASTQ single-end (.gz) trouvé localement"
            READ1="$DATA_DIR/${SAMPLE_ID}.fastq.gz"
            READ2=""
            IS_SINGLE_END=true
        else
            # Télécharger avec prefetch dans un répertoire temporaire
            TEMP_DOWNLOAD_DIR=$(mktemp -d)
            log_info "Téléchargement de l'échantillon $SAMPLE_ID dans $TEMP_DOWNLOAD_DIR..."

            # Utiliser pushd/popd pour la gestion correcte des répertoires
            pushd "$TEMP_DOWNLOAD_DIR" > /dev/null || { log_error "Impossible d'accéder à $TEMP_DOWNLOAD_DIR"; exit 1; }

            # Tentative 1: prefetch HTTPS (défaut)
            PREFETCH_OK=false
            log_info "Tentative 1/3 : prefetch (HTTPS)..."
            prefetch "$SAMPLE_ID" --output-directory . --max-size 50G 2>&1 | tee -a "$LOG_FILE"
            if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
                PREFETCH_OK=true
            else
                # Tentative 2: prefetch avec transport HTTP (contourne les erreurs HTTPS/TLS)
                log_warn "Échec HTTPS, tentative 2/3 : prefetch (HTTP)..."
                prefetch "$SAMPLE_ID" --output-directory . --max-size 50G --transport http 2>&1 | tee -a "$LOG_FILE"
                if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
                    PREFETCH_OK=true
                else
                    log_warn "Échec prefetch, tentative 3/3 : fasterq-dump direct (sans prefetch)..."
                fi
            fi

            # Convertir en FASTQ (fasterq-dump peut aussi télécharger directement si prefetch a échoué)
            log_info "Conversion en FASTQ..."
            fasterq-dump "$SAMPLE_ID" --split-files --outdir . --threads "${THREADS:-4}" 2>&1 | tee -a "$LOG_FILE"
            if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
                log_error "Échec de la conversion FASTQ (fasterq-dump) pour $SAMPLE_ID"
                popd > /dev/null
                rm -rf "$TEMP_DOWNLOAD_DIR"
                exit 1
            fi

            # Détecter automatiquement single-end vs paired-end
            if [[ -f "${SAMPLE_ID}_1.fastq" ]] && [[ -f "${SAMPLE_ID}_2.fastq" ]]; then
                # Mode paired-end
                log_info "Données paired-end détectées"
                mv "${SAMPLE_ID}_1.fastq" "$DATA_DIR/${SAMPLE_ID}_1.fastq"
                mv "${SAMPLE_ID}_2.fastq" "$DATA_DIR/${SAMPLE_ID}_2.fastq"
                READ1="$DATA_DIR/${SAMPLE_ID}_1.fastq"
                READ2="$DATA_DIR/${SAMPLE_ID}_2.fastq"
                IS_SINGLE_END=false
            elif [[ -f "${SAMPLE_ID}.fastq" ]]; then
                # Mode single-end (fichier sans suffixe)
                log_info "Données single-end détectées"
                mv "${SAMPLE_ID}.fastq" "$DATA_DIR/${SAMPLE_ID}.fastq"
                READ1="$DATA_DIR/${SAMPLE_ID}.fastq"
                READ2=""
                IS_SINGLE_END=true
            elif [[ -f "${SAMPLE_ID}_1.fastq" ]]; then
                # Mode single-end (fichier avec _1 mais pas de _2)
                log_info "Données single-end détectées (format _1)"
                mv "${SAMPLE_ID}_1.fastq" "$DATA_DIR/${SAMPLE_ID}.fastq"
                READ1="$DATA_DIR/${SAMPLE_ID}.fastq"
                READ2=""
                IS_SINGLE_END=true
            else
                log_error "Aucun fichier FASTQ trouvé après conversion"
                ls -la . | tee -a "$LOG_FILE"
                popd > /dev/null
                rm -rf "$TEMP_DOWNLOAD_DIR"
                exit 1
            fi

            # Revenir au répertoire original
            popd > /dev/null

            # Nettoyer le répertoire temporaire
            rm -rf "$TEMP_DOWNLOAD_DIR"
        fi
        ;;

    genbank)
        # ============ MODE GENBANK (FASTA) ============
        log_info "Mode GenBank détecté - Téléchargement de la séquence..."

        # Vérifier si le fichier existe déjà
        if [[ -f "$DATA_DIR/${SAMPLE_ID}.fasta" ]]; then
            log_success "Fichier FASTA trouvé localement"
            ASSEMBLY_FASTA="$DATA_DIR/${SAMPLE_ID}.fasta"
        else
            download_genbank_sequence "$SAMPLE_ID" "$DATA_DIR"
            if [[ $? -ne 0 ]] || [[ -z "$DOWNLOADED_FILE" ]]; then
                log_error "Échec du téléchargement de la séquence GenBank"
                exit 1
            fi
            ASSEMBLY_FASTA="$DOWNLOADED_FILE"
        fi
        ;;

    assembly)
        # ============ MODE ASSEMBLAGE NCBI (FASTA) ============
        log_info "Mode Assemblage NCBI détecté - Téléchargement de l'assemblage..."

        # Vérifier si le fichier existe déjà
        if [[ -f "$DATA_DIR/${SAMPLE_ID}_genomic.fna" ]]; then
            log_success "Fichier assemblage trouvé localement"
            ASSEMBLY_FASTA="$DATA_DIR/${SAMPLE_ID}_genomic.fna"
        elif [[ -f "$DATA_DIR/${SAMPLE_ID}.fasta" ]]; then
            log_success "Fichier FASTA trouvé localement"
            ASSEMBLY_FASTA="$DATA_DIR/${SAMPLE_ID}.fasta"
        else
            download_ncbi_assembly "$SAMPLE_ID" "$DATA_DIR"
            if [[ $? -ne 0 ]] || [[ -z "$DOWNLOADED_FILE" ]]; then
                log_error "Échec du téléchargement de l'assemblage NCBI"
                exit 1
            fi
            ASSEMBLY_FASTA="$DOWNLOADED_FILE"
        fi
        ;;

    local_fasta)
        # ============ MODE FICHIER LOCAL (FASTA) ============
        log_info "Mode fichier local détecté - Configuration du fichier FASTA..."

        if [[ -f "$LOCAL_FASTA_PATH" ]]; then
            setup_local_fasta "$LOCAL_FASTA_PATH" "$DATA_DIR" "$SAMPLE_ID"
            if [[ $? -ne 0 ]] || [[ -z "$DOWNLOADED_FILE" ]]; then
                log_error "Échec de la configuration du fichier FASTA local"
                exit 1
            fi
            ASSEMBLY_FASTA="$DOWNLOADED_FILE"
        else
            log_error "Fichier FASTA introuvable: $LOCAL_FASTA_PATH"
            exit 1
        fi
        ;;

    *)
        log_error "Type d'entrée non supporté: $INPUT_TYPE"
        exit 1
        ;;
esac

# Afficher les fichiers disponibles
log_info ""
log_info "Fichiers disponibles:"
if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_info "  FASTA assemblé: $ASSEMBLY_FASTA"
    ls -lh "$ASSEMBLY_FASTA" 2>/dev/null | tee -a "$LOG_FILE" || true
elif [[ "$IS_SINGLE_END" == true ]]; then
    log_info "  Mode: Single-end"
    log_info "  Read: $READ1"
    ls -lh "$READ1" 2>/dev/null | tee -a "$LOG_FILE" || true
else
    log_info "  Mode: Paired-end"
    log_info "  Read 1: $READ1"
    log_info "  Read 2: $READ2"
    ls -lh "$READ1" "$READ2" 2>/dev/null | tee -a "$LOG_FILE" || true
fi

log_success "Données prêtes"

#===============================================================================
# SECTION 11 : VÉRIFICATION DES ENVIRONNEMENTS DOCKER
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "VÉRIFICATION DES ENVIRONNEMENTS DOCKER"
log_info "═══════════════════════════════════════════════════════════════════"

# [Docker] Les environnements sont pré-installés dans l'image Docker :
#   - megam_arg     : env principal (fastqc, fastp, spades, quast, amrfinder, kma, blast, mlst, etc.)
#   - snippy_prokka : prokka et snippy
#   - abricate_env  : abricate
log_info "Environnement principal megam_arg : activé"
log_info "Environnement snippy_prokka : $(mamba run --no-banner -n snippy_prokka prokka --version 2>/dev/null || echo 'non disponible')"
log_info "Environnement abricate_env : $(mamba run --no-banner -n abricate_env abricate --version 2>/dev/null || echo 'non disponible')"

log_success "Vérification des environnements Docker terminée"

#===============================================================================
# MODULE 1 : CONTRÔLE QUALITÉ (QC) - IGNORÉ SI FASTA ASSEMBLÉ
#===============================================================================

if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_info "═══════════════════════════════════════════════════════════════════"
    log_warn "MODULE 1 : CONTRÔLE QUALITÉ (QC) - IGNORÉ (entrée FASTA assemblée)"
    log_info "═══════════════════════════════════════════════════════════════════"
else
    log_info "═══════════════════════════════════════════════════════════════════"
    log_info "MODULE 1 : CONTRÔLE QUALITÉ (QC)"
    log_info "═══════════════════════════════════════════════════════════════════"

    # Vérifier les prérequis
    check_prerequisites || { log_error "Prérequis non satisfaits"; exit 1; }

# [Docker] Les outils QC (fastqc, fastp, multiqc) sont dans l'env megam_arg déjà activé

#------- 1.1 FastQC sur reads bruts -------
log_info "1.1 FastQC sur reads bruts..."

if [[ "$IS_SINGLE_END" == true ]]; then
    fastqc \
        --outdir "$RESULTS_DIR"/01_qc/fastqc_raw \
        --threads "$THREADS" \
        "$READ1" 2>&1 | tee -a "$LOG_FILE"
    open_file_safe "$RESULTS_DIR/01_qc/fastqc_raw/${SAMPLE_ID}_fastqc.html" "FastQC Report"
else
    fastqc \
        --outdir "$RESULTS_DIR"/01_qc/fastqc_raw \
        --threads "$THREADS" \
        "$READ1" \
        "$READ2" 2>&1 | tee -a "$LOG_FILE"
    open_file_safe "$RESULTS_DIR/01_qc/fastqc_raw/${SAMPLE_ID}_1_fastqc.html" "FastQC Read 1 Report"
    open_file_safe "$RESULTS_DIR/01_qc/fastqc_raw/${SAMPLE_ID}_2_fastqc.html" "FastQC Read 2 Report"
fi

log_success "FastQC brut terminé"

#------- 1.2 Nettoyage avec Fastp -------
log_info "1.2 Nettoyage avec Fastp..."

if [[ "$IS_SINGLE_END" == true ]]; then
    # Mode single-end
    fastp \
        --in1 "$READ1" \
        --out1 "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_clean.fastq.gz \
        --json "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_fastp.json \
        --html "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_fastp.html \
        --thread "$THREADS" \
        --qualified_quality_phred 20 \
        --unqualified_percent_limit 40 \
        --length_required 30 \
        --dedup \
        --cut_front \
        --cut_tail \
        --cut_window_size 4 \
        --cut_mean_quality 20 2>&1 | tee -a "$LOG_FILE"

    # Variable pour le read nettoyé
    CLEAN_R1="$RESULTS_DIR/01_qc/fastp/${SAMPLE_ID}_clean.fastq.gz"
    CLEAN_R2=""
else
    # Mode paired-end
    fastp \
        --in1 "$READ1" \
        --in2 "$READ2" \
        --out1 "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_clean_R1.fastq.gz \
        --out2 "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_clean_R2.fastq.gz \
        --json "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_fastp.json \
        --html "$RESULTS_DIR"/01_qc/fastp/"${SAMPLE_ID}"_fastp.html \
        --thread "$THREADS" \
        --qualified_quality_phred 20 \
        --unqualified_percent_limit 40 \
        --length_required 30 \
        --detect_adapter_for_pe \
        --dedup \
        --correction \
        --cut_front \
        --cut_tail \
        --cut_window_size 4 \
        --cut_mean_quality 20 2>&1 | tee -a "$LOG_FILE"

    # Variables pour les reads nettoyés
    CLEAN_R1="$RESULTS_DIR/01_qc/fastp/${SAMPLE_ID}_clean_R1.fastq.gz"
    CLEAN_R2="$RESULTS_DIR/01_qc/fastp/${SAMPLE_ID}_clean_R2.fastq.gz"
fi

log_success "Nettoyage Fastp terminé"

# Vérifier que fastp a produit des reads nettoyés (fichier non vide)
if [[ ! -s "$CLEAN_R1" ]]; then
    log_error "Fastp a filtré 100% des reads : le fichier nettoyé est vide ($CLEAN_R1)"
    log_error "Les scores de qualité sont trop bas pour le seuil configuré (--qualified_quality_phred 20)"
    log_error "Solutions possibles :"
    log_error "  1. Vérifiez la qualité brute des reads (voir le rapport FastQC ci-dessus)"
    log_error "  2. Ce jeu de données n'est peut-être pas compatible avec ce pipeline (ex: données ONT/PacBio)"
    log_error "  3. Le téléchargement SRA a peut-être produit des données corrompues"
    exit 1
fi

open_file_safe "$RESULTS_DIR/01_qc/fastp/${SAMPLE_ID}_fastp.html" "Fastp QC Report"

#------- 1.3 Classification taxonomique via NCBI API -------
if [[ "$PROKKA_MODE" == "auto" ]]; then
    log_info "1.3 Détection de l'espèce via l'API NCBI..."
    fetch_species_from_ncbi "$SAMPLE_ID" "$INPUT_TYPE" || true
fi

#------- 1.4 FastQC sur reads nettoyés -------
log_info "1.4 FastQC sur reads nettoyés..."

if [[ "$IS_SINGLE_END" == true ]]; then
    fastqc \
        --outdir "$RESULTS_DIR"/01_qc/fastqc_clean \
        --threads "$THREADS" \
        "$CLEAN_R1" 2>&1 | tee -a "$LOG_FILE"
else
    fastqc \
        --outdir "$RESULTS_DIR"/01_qc/fastqc_clean \
        --threads "$THREADS" \
        "$CLEAN_R1" \
        "$CLEAN_R2" 2>&1 | tee -a "$LOG_FILE"
fi

log_success "FastQC nettoyé terminé"

#------- 1.5 Rapport MultiQC -------
log_info "1.5 Génération du rapport MultiQC..."

multiqc \
    "$RESULTS_DIR"/01_qc/fastqc_raw \
    "$RESULTS_DIR"/01_qc/fastqc_clean \
    "$RESULTS_DIR"/01_qc/fastp \
    --outdir "$RESULTS_DIR"/01_qc/multiqc \
    --filename "${SAMPLE_ID}"_multiqc_report \
    --title "QC Report - $SAMPLE_ID" \
    --force 2>&1 | tee -a "$LOG_FILE"

log_success "Rapport MultiQC: $RESULTS_DIR/01_qc/multiqc/${SAMPLE_ID}_multiqc_report.html"

open_file_safe "$RESULTS_DIR/01_qc/multiqc/${SAMPLE_ID}_multiqc_report.html" "MultiQC Report"

    log_success "MODULE 1 TERMINÉ"
fi  # Fin du bloc conditionnel Module 1

#===============================================================================
# MODULE 2 : ASSEMBLAGE DU GÉNOME - IGNORÉ SI FASTA ASSEMBLÉ
#===============================================================================

if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_info "═══════════════════════════════════════════════════════════════════"
    log_warn "MODULE 2 : ASSEMBLAGE DU GÉNOME - IGNORÉ (entrée FASTA assemblée)"
    log_info "═══════════════════════════════════════════════════════════════════"

    # Copier le FASTA assemblé vers le répertoire d'assemblage filtré
    log_info "Copie du FASTA assemblé vers le répertoire de travail..."
    cp "$ASSEMBLY_FASTA" "$RESULTS_DIR/02_assembly/filtered/${SAMPLE_ID}_filtered.fasta"
    log_success "FASTA assemblé prêt pour l'annotation"
    
    #------- Classification taxonomique via NCBI API -------
    if [[ "$PROKKA_MODE" == "auto" ]]; then
        log_info "Détection de l'espèce via l'API NCBI..."
        fetch_species_from_ncbi "$SAMPLE_ID" "$INPUT_TYPE" || true
    fi
else
    log_info "═══════════════════════════════════════════════════════════════════"
    log_info "MODULE 2 : ASSEMBLAGE DU GÉNOME"
    log_info "═══════════════════════════════════════════════════════════════════"

    # [Docker] Les outils assemblage (spades, quast, seqkit, megahit) sont dans l'env megam_arg déjà activé

#------- 2.1 Assemblage avec SPAdes (AVEC --isolate) -------
log_info "2.1 Assemblage SPAdes (mode isolate pour culture pure)..."

if [[ "$IS_SINGLE_END" == true ]]; then
    # Mode single-end
    log_info "  Mode single-end détecté"
    spades.py \
        -s "$CLEAN_R1" \
        -o "$RESULTS_DIR"/02_assembly/spades \
        --threads "$THREADS" \
        --memory 16 \
        --isolate \
        --cov-cutoff auto 2>&1 | tee -a "$LOG_FILE"
else
    # Mode paired-end
    spades.py \
        -1 "$CLEAN_R1" \
        -2 "$CLEAN_R2" \
        -o "$RESULTS_DIR"/02_assembly/spades \
        --threads "$THREADS" \
        --memory 16 \
        --isolate \
        --cov-cutoff auto 2>&1 | tee -a "$LOG_FILE"
fi

# Vérifier que SPAdes a produit des fichiers
if [[ ! -f "$RESULTS_DIR/02_assembly/spades/contigs.fasta" ]]; then
    log_error "ÉCHEC SPAdes: Fichier contigs.fasta non créé"
    log_error "  Consultez le log SPAdes: $RESULTS_DIR/02_assembly/spades/spades.log"
    exit 1
fi

# Copier les fichiers principaux
cp "$RESULTS_DIR"/02_assembly/spades/contigs.fasta \
   "$RESULTS_DIR"/02_assembly/spades/"${SAMPLE_ID}"_contigs.fasta

if [[ -f "$RESULTS_DIR/02_assembly/spades/scaffolds.fasta" ]]; then
    cp "$RESULTS_DIR"/02_assembly/spades/scaffolds.fasta \
       "$RESULTS_DIR"/02_assembly/spades/"${SAMPLE_ID}"_scaffolds.fasta
fi

log_success "Assemblage SPAdes terminé"

#------- 2.2 Filtrage des contigs (>= 500 bp) -------
log_info "2.2 Filtrage des contigs (>= 500 bp)..."

seqkit seq \
    -m 500 \
    "$RESULTS_DIR"/02_assembly/spades/"${SAMPLE_ID}"_contigs.fasta \
    > "$RESULTS_DIR"/02_assembly/filtered/"${SAMPLE_ID}"_filtered.fasta

# Vérification critique : le fichier filtré contient-il des séquences ?
FILTERED_CONTIGS_COUNT=$(grep -c "^>" "$RESULTS_DIR"/02_assembly/filtered/"${SAMPLE_ID}"_filtered.fasta 2>/dev/null || echo "0")

if [[ "$FILTERED_CONTIGS_COUNT" -eq 0 ]]; then
    log_error "ÉCHEC ASSEMBLAGE: Aucun contig >= 500 bp produit"
    log_error "  Les données d'entrée sont probablement insuffisantes ou de mauvaise qualité"
    log_error "  Vérifiez:"
    log_error "    - La qualité des reads (FastQC)"
    log_error "    - Le nombre de reads (minimum ~100k pour bactéries)"
    log_error "    - Le type de données (WGS vs amplicon)"
    log_error ""
    log_error "Pipeline arrêté. Consultez le log SPAdes pour plus de détails:"
    log_error "  $RESULTS_DIR/02_assembly/spades/spades.log"
    exit 1
fi

log_success "Filtrage des contigs terminé ($FILTERED_CONTIGS_COUNT contigs >= 500 bp)"

#------- 2.3 Statistiques d'assemblage avec QUAST -------
log_info "2.3 Statistiques d'assemblage avec QUAST..."

quast.py \
    "$RESULTS_DIR"/02_assembly/filtered/"${SAMPLE_ID}"_filtered.fasta \
    -o "$RESULTS_DIR"/02_assembly/quast \
    --threads "$THREADS" 2>&1 | tee -a "$LOG_FILE"

log_success "Statistiques QUAST générées"

    log_success "MODULE 2 TERMINÉ"
fi  # Fin du bloc conditionnel Module 2

#===============================================================================
# MODULE 3 : ANNOTATION DU GÉNOME
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "MODULE 3 : ANNOTATION DU GÉNOME"
log_info "═══════════════════════════════════════════════════════════════════"

# [Docker] Prokka est dans l'env snippy_prokka, appelé via mamba run

#------- 3.1 Annotation avec Prokka -------
log_info "3.1 Annotation avec Prokka..."
log_info "  Mode Prokka: $PROKKA_MODE"

# Construction des arguments Prokka selon le mode choisi
PROKKA_ARGS="--outdir $RESULTS_DIR/03_annotation/prokka"
PROKKA_ARGS="$PROKKA_ARGS --prefix $SAMPLE_ID"
PROKKA_ARGS="$PROKKA_ARGS --cpu $THREADS"
PROKKA_ARGS="$PROKKA_ARGS --locustag ARG"
PROKKA_ARGS="$PROKKA_ARGS --force"

case "$PROKKA_MODE" in
    auto)
        # Utiliser les valeurs détectées par l'API NCBI
        if [[ -n "$PROKKA_GENUS" ]]; then
            log_info "  Genre détecté: $PROKKA_GENUS"
            PROKKA_ARGS="$PROKKA_ARGS --genus $PROKKA_GENUS"
            if [[ -n "$PROKKA_SPECIES" ]] && [[ "$PROKKA_SPECIES" != "sp." ]]; then
                log_info "  Espèce détectée: $PROKKA_SPECIES"
                PROKKA_ARGS="$PROKKA_ARGS --species $PROKKA_SPECIES"
            fi
        else
            log_warn "  Aucune espèce détectée via NCBI, mode générique utilisé"
        fi
        ;;
    generic)
        # Mode universel - pas de --genus/--species
        log_info "  Mode générique (toutes bactéries)"
        ;;
    ecoli)
        # Mode legacy E. coli K-12
        log_info "  Mode Escherichia coli K-12"
        PROKKA_ARGS="$PROKKA_ARGS --genus Escherichia --species coli --strain K-12"
        ;;
    custom)
        # Mode personnalisé avec genus/species fournis par l'utilisateur
        if [[ -n "$PROKKA_GENUS" ]]; then
            log_info "  Genre personnalisé: $PROKKA_GENUS"
            PROKKA_ARGS="$PROKKA_ARGS --genus $PROKKA_GENUS"
            if [[ -n "$PROKKA_SPECIES" ]]; then
                log_info "  Espèce personnalisée: $PROKKA_SPECIES"
                PROKKA_ARGS="$PROKKA_ARGS --species $PROKKA_SPECIES"
            fi
        else
            log_warn "  Mode custom sans genre spécifié, utilisation du mode générique"
        fi
        ;;
    *)
        log_warn "  Mode Prokka inconnu: $PROKKA_MODE, utilisation du mode générique"
        ;;
esac

# Exécution de Prokka avec les arguments construits (via mamba run dans snippy_prokka)
log_info "  Commande: mamba run -n snippy_prokka prokka $PROKKA_ARGS <fasta>"
mamba run --no-banner -n snippy_prokka prokka $PROKKA_ARGS "$RESULTS_DIR"/02_assembly/filtered/"${SAMPLE_ID}"_filtered.fasta 2>&1 | tee -a "$LOG_FILE"

log_success "Annotation Prokka terminée"

#------- 3.2 Statistiques d'annotation -------
log_info "3.2 Statistiques d'annotation..."

log_success "Statistiques d'annotation disponibles"

log_success "MODULE 3 TERMINÉ"

#===============================================================================
# MODULE 3.3 : TYPAGE MLST (Sequence Type)
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "MODULE 3.3 : TYPAGE MLST (Multi-Locus Sequence Typing)"
log_info "═══════════════════════════════════════════════════════════════════"

# Créer le répertoire de sortie MLST
mkdir -p "$RESULTS_DIR/03_annotation/mlst"

# Variables pour stocker les résultats MLST
MLST_SCHEME=""
MLST_ST=""
MLST_ALLELES=""

# [Docker] mlst est dans l'env megam_arg déjà activé

# Configurer PERL5LIB pour mlst (nécessaire dans l'env mamba)
export PERL5LIB="${PERL5LIB:-}:${CONDA_PREFIX:-}/lib/perl5/site_perl:${CONDA_PREFIX:-}/lib/perl5"

# Vérifier si mlst est disponible
if command -v mlst &> /dev/null; then
    log_info "3.3.1 Exécution du typage MLST..."

    # Fichier d'entrée (contigs filtrés ou assemblage fourni)
    if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
        MLST_INPUT="$RESULTS_DIR/03_annotation/prokka/${SAMPLE_ID}.fna"
    else
        MLST_INPUT="$RESULTS_DIR/02_assembly/filtered/${SAMPLE_ID}_filtered.fasta"
    fi

    # Exécution de mlst
    MLST_OUTPUT="$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst.tsv"

    # Définir le chemin de la base MLST si non défini
    if [[ -z "${MLST_DB:-}" ]]; then
        MLST_DB=$(find_mlst_db)
    fi

    if [[ -f "$MLST_INPUT" ]]; then
        # Utiliser --datadir si une base personnalisée est définie
        if [[ -n "$MLST_DB" ]] && [[ -d "$MLST_DB/db" ]]; then
            mlst --threads "$THREADS" --datadir "$MLST_DB/db/pubmlst" --blastdb "$MLST_DB/db/blast/mlst.fa" "$MLST_INPUT" > "$MLST_OUTPUT" 2>> "$LOG_FILE"
        else
            mlst --threads "$THREADS" "$MLST_INPUT" > "$MLST_OUTPUT" 2>> "$LOG_FILE"
        fi

        if [[ -s "$MLST_OUTPUT" ]]; then
            # Parser les résultats
            MLST_SCHEME=$(cut -f2 "$MLST_OUTPUT" | head -1)
            MLST_ST=$(cut -f3 "$MLST_OUTPUT" | head -1)
            MLST_ALLELES=$(cut -f4- "$MLST_OUTPUT" | head -1)

            log_success "Typage MLST terminé"
            log_info "  → Schéma: $MLST_SCHEME"
            log_info "  → Sequence Type: ST$MLST_ST"
            log_info "  → Allèles: $MLST_ALLELES"

            # Créer un fichier de résumé lisible
            cat > "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" << EOF
=== RÉSULTATS MLST ===
Échantillon: $SAMPLE_ID
Schéma: $MLST_SCHEME
Sequence Type: ST$MLST_ST
Allèles: $MLST_ALLELES

Interprétation:
EOF

            # Ajouter des informations contextuelles selon le ST
            case "$MLST_SCHEME" in
                saureus)
                    case "$MLST_ST" in
                        8) echo "  ST8 = Clone USA300 (CA-MRSA épidémique)" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        5) echo "  ST5 = Clone pandémique HA-MRSA" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        22) echo "  ST22 = Clone EMRSA-15" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        36) echo "  ST36 = Clone USA200" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        239) echo "  ST239 = Clone Brésilien/Hongrois" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        398) echo "  ST398 = Clone LA-MRSA (animaux)" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        *) echo "  ST$MLST_ST = Voir PubMLST pour plus d'informations" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                    esac
                    ;;
                klebsiella|kpneumoniae)
                    case "$MLST_ST" in
                        258) echo "  ST258 = Clone KPC épidémique mondial" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        11) echo "  ST11 = Clone KPC asiatique" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        15) echo "  ST15 = Clone ESBL répandu" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        147) echo "  ST147 = Clone NDM émergent" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        307) echo "  ST307 = Clone KPC émergent" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        *) echo "  ST$MLST_ST = Voir PubMLST pour plus d'informations" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                    esac
                    ;;
                ecoli)
                    case "$MLST_ST" in
                        131) echo "  ST131 = Clone ESBL/FQ-R pandémique" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        410) echo "  ST410 = Clone carbapénémase émergent" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        69) echo "  ST69 = Clone MDR" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        10) echo "  ST10 = Clone commun, souvent ESBL" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        167) echo "  ST167 = Clone NDM émergent" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                        *) echo "  ST$MLST_ST = Voir PubMLST pour plus d'informations" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt" ;;
                    esac
                    ;;
                *)
                    echo "  ST$MLST_ST = Consulter PubMLST (https://pubmlst.org)" >> "$RESULTS_DIR/03_annotation/mlst/${SAMPLE_ID}_mlst_summary.txt"
                    ;;
            esac

        else
            log_warn "Aucun résultat MLST généré (schéma non reconnu ou données insuffisantes)"
            MLST_ST="-"
            MLST_SCHEME="-"
        fi
    else
        log_error "Fichier d'entrée MLST non trouvé: $MLST_INPUT"
        MLST_ST="-"
        MLST_SCHEME="-"
    fi
else
    log_warn "mlst non installé - typage ignoré"
    log_info "  Outil non disponible dans l'image Docker"
    MLST_ST="-"
    MLST_SCHEME="-"
fi

log_success "MODULE 3.3 TERMINÉ"

#===============================================================================
# MODULE 3.5 : DÉTECTION ARG SUR READS BRUTS (HAUTE SENSIBILITÉ)
#===============================================================================

# Cette étape détecte les ARG directement sur les reads bruts pour capturer
# les gènes à faible couverture qui pourraient être perdus lors de l'assemblage

if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_info "═══════════════════════════════════════════════════════════════════"
    log_warn "MODULE 3.5 : DÉTECTION ARG SUR READS - IGNORÉ (entrée FASTA)"
    log_info "═══════════════════════════════════════════════════════════════════"
else
    log_info "═══════════════════════════════════════════════════════════════════"
    log_info "MODULE 3.5 : DÉTECTION ARG SUR READS BRUTS (HAUTE SENSIBILITÉ)"
    log_info "═══════════════════════════════════════════════════════════════════"

    mkdir -p "$RESULTS_DIR/04_arg_detection/reads_based"

    # [Docker] Les outils ARG (amrfinder, kma, blast) sont dans l'env megam_arg déjà activé

    #------- 3.5.1 Détection ARG sur reads avec KMA (si disponible) -------
    if command -v kma > /dev/null 2>&1; then
        log_info "3.5.1 Détection ARG sur reads avec KMA..."

        # Vérifier/créer les bases KMA
        KMA_DB_DIR="$DB_DIR/kma_db"

        # Si la base n'existe pas, la créer automatiquement
        if [[ ! -f "$KMA_DB_DIR/resfinder.name" ]]; then
            log_info "  Base KMA non trouvée, création automatique..."
            setup_kma_database
        fi

        if [[ -f "$KMA_DB_DIR/resfinder.name" ]]; then
            log_info "  Base KMA prête: $KMA_DB_DIR"

            if [[ "$IS_SINGLE_END" == true ]]; then
                kma -i "$CLEAN_R1" \
                    -o "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_kma" \
                    -t_db "$KMA_DB_DIR/resfinder" \
                    -t "$THREADS" \
                    -1t1 \
                    -mem_mode \
                    -and 2>&1 | tee -a "$LOG_FILE"
            else
                kma -ipe "$CLEAN_R1" "$CLEAN_R2" \
                    -o "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_kma" \
                    -t_db "$KMA_DB_DIR/resfinder" \
                    -t "$THREADS" \
                    -1t1 \
                    -mem_mode \
                    -and 2>&1 | tee -a "$LOG_FILE"
            fi

            if [[ -f "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_kma.res" ]]; then
                log_success "Détection KMA terminée"
                log_info "Résultats KMA:"
                head -20 "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_kma.res" 2>&1 | tee -a "$LOG_FILE"
            fi
        else
            log_warn "  Impossible de créer la base KMA (bases abricate manquantes?)"
            log_warn "  Exécutez d'abord: abricate --setupdb"
        fi
    else
        log_info "KMA non disponible, étape ignorée"
        log_info "  Outil non disponible dans l'image Docker"
    fi

    #------- 3.5.2 Mapping BLAST des reads contre bases ARG -------
    log_info "3.5.2 Recherche BLAST des reads contre bases ARG..."

    # Créer un échantillon de reads pour BLAST rapide
    SAMPLE_SIZE=50000
    log_info "  Échantillonnage de $SAMPLE_SIZE reads pour analyse BLAST..."

    READS_SAMPLE="$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_sample.fasta"

    # Note: On désactive temporairement pipefail car zcat + head cause SIGPIPE
    set +o pipefail
    if [[ "$IS_SINGLE_END" == true ]]; then
        if [[ "$CLEAN_R1" == *.gz ]]; then
            zcat "$CLEAN_R1" 2>/dev/null | head -$((SAMPLE_SIZE * 4)) | \
                awk 'NR%4==1{print ">"substr($0,2)} NR%4==2{print}' > "$READS_SAMPLE"
        else
            head -$((SAMPLE_SIZE * 4)) "$CLEAN_R1" | \
                awk 'NR%4==1{print ">"substr($0,2)} NR%4==2{print}' > "$READS_SAMPLE"
        fi
    else
        if [[ "$CLEAN_R1" == *.gz ]]; then
            zcat "$CLEAN_R1" 2>/dev/null | head -$((SAMPLE_SIZE * 4)) | \
                awk 'NR%4==1{print ">"substr($0,2)} NR%4==2{print}' > "$READS_SAMPLE"
        else
            head -$((SAMPLE_SIZE * 4)) "$CLEAN_R1" | \
                awk 'NR%4==1{print ">"substr($0,2)} NR%4==2{print}' > "$READS_SAMPLE"
        fi
    fi
    set -o pipefail

    READS_COUNT=$(grep -c "^>" "$READS_SAMPLE" 2>/dev/null || echo "0")
    log_info "  Reads échantillonnés: $READS_COUNT"

    # BLAST contre les séquences ARG connues (utiliser la base abricate)
    # Récupérer le chemin des bases abricate (abricate est dans abricate_env)
    ABRICATE_DB_PATH=$(mamba run --no-banner -n abricate_env abricate --help 2>&1 | grep -oP '\-\-datadir.*\[\K[^\]]+' | head -1)
    if [[ -z "$ABRICATE_DB_PATH" ]] || [[ ! -d "$ABRICATE_DB_PATH" ]]; then
        # Fallback sur chemins portables
        local abricate_prefix=$(mamba run --no-banner -n abricate_env bash -c 'echo $CONDA_PREFIX' 2>/dev/null)
        for path in "${abricate_prefix:-}/share/abricate/db" "$HOME/abricate/db" "${CONDA_PREFIX:-}/share/abricate/db" "/usr/local/share/abricate/db"; do
            if [[ -d "$path" ]]; then
                ABRICATE_DB_PATH="$path"
                break
            fi
        done
    fi

    if [[ -n "$ABRICATE_DB_PATH" ]] && [[ -d "$ABRICATE_DB_PATH/resfinder" ]]; then
        log_info "  BLAST contre ResFinder database..."

        # Créer une base BLAST temporaire
        RESFINDER_SEQS="$ABRICATE_DB_PATH/resfinder/sequences"

        if [[ -f "$RESFINDER_SEQS" ]]; then
            makeblastdb -in "$RESFINDER_SEQS" -dbtype nucl -out /tmp/resfinder_blast_db 2>/dev/null

            blastn -query "$READS_SAMPLE" \
                -db /tmp/resfinder_blast_db \
                -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore stitle" \
                -max_target_seqs 1 \
                -evalue 1e-10 \
                -num_threads "$THREADS" \
                -out "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_blast.tsv" 2>&1 | tee -a "$LOG_FILE"

            # Résumer les hits
            if [[ -f "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_blast.tsv" ]]; then
                BLAST_HITS=$(wc -l < "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_blast.tsv")
                log_info "  Hits BLAST trouvés: $BLAST_HITS"

                if [[ $BLAST_HITS -gt 0 ]]; then
                    log_info "  Gènes ARG détectés dans les reads (par fréquence):"
                    cut -f2 "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_blast.tsv" | \
                        sort | uniq -c | sort -rn | head -10 | \
                        while read count gene; do
                            log_info "    $gene: $count reads"
                        done

                    # Créer un résumé
                    echo "# Résumé détection ARG sur reads - $SAMPLE_ID" > "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_summary.tsv"
                    echo "# Date: $(date)" >> "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_summary.tsv"
                    echo "# Reads analysés: $READS_COUNT" >> "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_summary.tsv"
                    echo "#" >> "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_summary.tsv"
                    echo "Gene	Read_Count	Estimated_Coverage" >> "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_summary.tsv"

                    cut -f2 "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_blast.tsv" | \
                        sort | uniq -c | sort -rn | \
                        awk -v total="$READS_COUNT" '{
                            gene=$2;
                            count=$1;
                            est_cov=(count * 150 / 1000);
                            printf "%s\t%d\t%.1fx\n", gene, count, est_cov
                        }' >> "$RESULTS_DIR/04_arg_detection/reads_based/${SAMPLE_ID}_reads_summary.tsv"

                    log_success "Résumé sauvegardé: ${SAMPLE_ID}_reads_summary.tsv"
                fi
            fi

            # Nettoyage
            rm -f /tmp/resfinder_blast_db.* 2>/dev/null
        else
            log_warn "  Séquences ResFinder non trouvées"
        fi
    else
        log_warn "  Base abricate non trouvée pour BLAST"
    fi

    # Nettoyage
    rm -f "$READS_SAMPLE" 2>/dev/null

    log_success "MODULE 3.5 TERMINÉ"
fi

#===============================================================================
# MODULE 4 : DÉTECTION DES GÈNES DE RÉSISTANCE AUX ANTIBIOTIQUES (ARG)
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "MODULE 4 : DÉTECTION DES GÈNES ARG"
log_info "═══════════════════════════════════════════════════════════════════"

# [Docker] Les outils ARG (amrfinder, kma, blast) sont dans l'env megam_arg déjà activé

#------- 4.1 AMRFinderPlus -------
log_info "4.1 AMRFinderPlus (v4.2) avec virulence et stress..."

if [[ -n "$AMRFINDER_DB" ]]; then
    mkdir -p "$RESULTS_DIR"/04_arg_detection/amrfinderplus

    # Vérifier que la base de données existe (sans mise à jour automatique)
    if [[ -d "$AMRFINDER_DB" ]] && [[ -n "$(ls -A "$AMRFINDER_DB" 2>/dev/null)" ]]; then
        log_info "  Base AMRFinder trouvée: $AMRFINDER_DB"
    else
        log_warn "  Base AMRFinder vide ou introuvable"
        log_warn "  Pour installer/mettre à jour: amrfinder --force_update"
    fi

    # Détecter l'organisme à partir de l'API NCBI pour les détections spécifiques
    # Organismes supportés par AMRFinder: Escherichia, Salmonella, Klebsiella, Staphylococcus_aureus, etc.
    AMRFINDER_ORGANISM=""
    if [[ -n "$DETECTED_SPECIES" ]]; then
        case "$DETECTED_SPECIES" in
            *"Escherichia"*|*"E. coli"*|*"E.coli"*)
                AMRFINDER_ORGANISM="Escherichia" ;;
            *"Salmonella"*)
                AMRFINDER_ORGANISM="Salmonella" ;;
            *"Klebsiella pneumoniae"*)
                AMRFINDER_ORGANISM="Klebsiella_pneumoniae" ;;
            *"Klebsiella oxytoca"*)
                AMRFINDER_ORGANISM="Klebsiella_oxytoca" ;;
            *"Staphylococcus aureus"*)
                AMRFINDER_ORGANISM="Staphylococcus_aureus" ;;
            *"Pseudomonas aeruginosa"*)
                AMRFINDER_ORGANISM="Pseudomonas_aeruginosa" ;;
            *"Acinetobacter baumannii"*)
                AMRFINDER_ORGANISM="Acinetobacter_baumannii" ;;
            *"Enterococcus faecalis"*)
                AMRFINDER_ORGANISM="Enterococcus_faecalis" ;;
            *"Enterococcus faecium"*)
                AMRFINDER_ORGANISM="Enterococcus_faecium" ;;
            *"Campylobacter"*)
                AMRFINDER_ORGANISM="Campylobacter" ;;
            *"Neisseria gonorrhoeae"*)
                AMRFINDER_ORGANISM="Neisseria_gonorrhoeae" ;;
            *"Neisseria meningitidis"*)
                AMRFINDER_ORGANISM="Neisseria_meningitidis" ;;
            *"Streptococcus pneumoniae"*)
                AMRFINDER_ORGANISM="Streptococcus_pneumoniae" ;;
            *"Streptococcus pyogenes"*)
                AMRFINDER_ORGANISM="Streptococcus_pyogenes" ;;
            *"Streptococcus agalactiae"*)
                AMRFINDER_ORGANISM="Streptococcus_agalactiae" ;;
            *"Vibrio cholerae"*)
                AMRFINDER_ORGANISM="Vibrio_cholerae" ;;
            *"Clostridioides difficile"*|*"Clostridium difficile"*)
                AMRFINDER_ORGANISM="Clostridioides_difficile" ;;
        esac
    fi

    # Construire la commande AMRFinder avec options avancées
    AMRFINDER_OPTS="--plus"  # Active virulence, stress, et autres gènes

    if [[ -n "$AMRFINDER_ORGANISM" ]]; then
        AMRFINDER_OPTS+=" --organism $AMRFINDER_ORGANISM"
        log_info "  Organisme détecté: $AMRFINDER_ORGANISM (mutations spécifiques activées)"
    else
        log_info "  Organisme non reconnu - détection générique"
    fi

    log_info "  Exécution d'AMRFinder avec --plus (AMR + virulence + stress)..."
    amrfinder \
        --nucleotide "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
        --database "$AMRFINDER_DB" \
        --output "$RESULTS_DIR"/04_arg_detection/amrfinderplus/"${SAMPLE_ID}"_amrfinderplus.tsv \
        --threads "$THREADS" \
        $AMRFINDER_OPTS 2>&1 | tee -a "$LOG_FILE"

    # Compter les résultats par type
    if [[ -f "$RESULTS_DIR/04_arg_detection/amrfinderplus/${SAMPLE_ID}_amrfinderplus.tsv" ]]; then
        AMRF_TOTAL=$(tail -n +2 "$RESULTS_DIR/04_arg_detection/amrfinderplus/${SAMPLE_ID}_amrfinderplus.tsv" | wc -l)
        AMRF_VIR=$(grep -c "VIRULENCE" "$RESULTS_DIR/04_arg_detection/amrfinderplus/${SAMPLE_ID}_amrfinderplus.tsv" 2>/dev/null || echo "0")
        AMRF_STRESS=$(grep -c "STRESS" "$RESULTS_DIR/04_arg_detection/amrfinderplus/${SAMPLE_ID}_amrfinderplus.tsv" 2>/dev/null || echo "0")
        AMRF_AMR=$((AMRF_TOTAL - AMRF_VIR - AMRF_STRESS))
        log_success "AMRFinderPlus terminé: $AMRF_TOTAL gènes ($AMRF_AMR AMR, $AMRF_VIR virulence, $AMRF_STRESS stress)"
    else
        log_success "AMRFinderPlus terminé"
    fi
else
    log_warn "AMRFinderPlus IGNORÉ (base de données non configurée)"
    log_warn "  Pour configurer: définir AMRFINDER_DB ou exécuter amrfinder --force_update"
fi

#------- 4.2 ABRicate ResFinder -------
# [Docker] ABRicate est dans l'env abricate_env, appelé via mamba run

log_info "4.2 ABRicate ResFinder..."

mamba run --no-banner -n abricate_env abricate \
    --db resfinder \
    "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
    > "$RESULTS_DIR"/04_arg_detection/resfinder/"${SAMPLE_ID}"_resfinder.tsv 2>&1 | tee -a "$LOG_FILE"

log_success "ResFinder terminé"

#------- 4.3 ABRicate PlasmidFinder -------
log_info "4.3 ABRicate PlasmidFinder..."

mamba run --no-banner -n abricate_env abricate \
    --db plasmidfinder \
    "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
    > "$RESULTS_DIR"/04_arg_detection/plasmidfinder/"${SAMPLE_ID}"_plasmidfinder.tsv 2>&1 | tee -a "$LOG_FILE"

log_success "PlasmidFinder terminé"

#------- 4.4 ABRicate CARD -------
log_info "4.4 ABRicate CARD..."

mamba run --no-banner -n abricate_env abricate \
    --db card \
    "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
    > "$RESULTS_DIR"/04_arg_detection/card/"${SAMPLE_ID}"_card.tsv 2>&1 | tee -a "$LOG_FILE"

log_success "CARD terminé"

#------- 4.5 ABRicate NCBI -------
log_info "4.5 ABRicate NCBI..."

mamba run --no-banner -n abricate_env abricate \
    --db ncbi \
    "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
    > "$RESULTS_DIR"/04_arg_detection/ncbi/"${SAMPLE_ID}"_ncbi.tsv 2>&1 | tee -a "$LOG_FILE"

log_success "NCBI terminé"

#------- 4.6 ABRicate VFDB (Virulence Factor Database) -------
log_info "4.6 ABRicate VFDB (facteurs de virulence)..."

mkdir -p "$RESULTS_DIR"/04_arg_detection/vfdb

mamba run --no-banner -n abricate_env abricate \
    --db vfdb \
    "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
    > "$RESULTS_DIR"/04_arg_detection/vfdb/"${SAMPLE_ID}"_vfdb.tsv 2>&1 | tee -a "$LOG_FILE"

# Compter les gènes de virulence trouvés
if [[ -f "$RESULTS_DIR/04_arg_detection/vfdb/${SAMPLE_ID}_vfdb.tsv" ]]; then
    VFDB_COUNT=$(grep -v "^#" "$RESULTS_DIR/04_arg_detection/vfdb/${SAMPLE_ID}_vfdb.tsv" | tail -n +2 | wc -l)
    log_success "VFDB terminé: $VFDB_COUNT facteurs de virulence détectés"
else
    log_success "VFDB terminé"
fi

#------- 4.7 RGI (Resistance Gene Identifier) avec CARD -------
log_info "4.7 RGI/CARD (détection avancée avec modèles homologue/variant/overexpression)..."

mkdir -p "$RESULTS_DIR"/04_arg_detection/rgi

# Vérifier si RGI est disponible
if command -v rgi &> /dev/null; then
    # Définir le chemin de la base CARD
    if [[ -z "${CARD_DB:-}" ]]; then
        CARD_DB=$(find_card_db)
    fi

    # Si toujours pas de base, proposer le téléchargement
    if [[ -z "$CARD_DB" ]] || [[ ! -f "$CARD_DB/card.json" ]]; then
        log_warn "  Base CARD non trouvée - téléchargement automatique..."
        mkdir -p "$DB_DIR/card_db"
        download_card_db "$DB_DIR/card_db"
        CARD_DB="$DB_DIR/card_db"
    fi

    # Vérifier si la base CARD est valide
    if [[ -f "$CARD_DB/card.json" ]]; then
        # Obtenir la version depuis loaded_databases.json si disponible
        if [[ -f "$CARD_DB/loaded_databases.json" ]]; then
            RGI_DB_VERSION=$(grep -o '"data_version": "[^"]*"' "$CARD_DB/loaded_databases.json" | head -1 | cut -d'"' -f4)
        else
            RGI_DB_VERSION="inconnue"
        fi
        log_info "  Base CARD v$RGI_DB_VERSION détectée: $CARD_DB"

        # Exécuter RGI main
        rgi main \
            --input_sequence "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
            --output_file "$RESULTS_DIR"/04_arg_detection/rgi/"${SAMPLE_ID}"_rgi \
            --local \
            --clean \
            -n "$THREADS" \
            --alignment_tool DIAMOND \
            --include_nudge 2>> "$LOG_FILE" || log_warn "  RGI a rencontré des avertissements"

        if [[ -f "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_rgi.txt" ]]; then
            RGI_COUNT=$(tail -n +2 "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_rgi.txt" | wc -l)
            log_success "RGI terminé - $RGI_COUNT gènes détectés"

            # Extraire les gènes intrinsèques (efflux pumps, etc.)
            log_info "  Analyse des mécanismes de résistance..."
            grep -i "efflux\|overexpression\|intrinsic" "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_rgi.txt" > "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_intrinsic.txt" 2>/dev/null || true
            INTRINSIC_COUNT=$(wc -l < "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_intrinsic.txt" 2>/dev/null || echo "0")
            log_info "  → Gènes intrinsèques/efflux: $INTRINSIC_COUNT"
        else
            log_warn "  Fichier de sortie RGI non généré"
        fi
    else
        log_warn "  Base CARD non chargée - exécuter: rgi auto_load --clean --local"
    fi
else
    log_warn "RGI non installé - pour installer: pip install rgi && rgi auto_load --clean --local"
fi

#------- 4.7 PointFinder (mutations chromosomiques) -------
log_info "4.7 PointFinder (mutations chromosomiques SNP)..."

mkdir -p "$RESULTS_DIR"/04_arg_detection/pointfinder

# Déterminer l'espèce pour PointFinder
POINTFINDER_SPECIES=""
# Utiliser ${VAR:-} pour éviter unbound variable avec set -u
if [[ -n "${DETECTED_SPECIES:-}" ]]; then
    # Mapper l'espèce détectée vers les espèces PointFinder supportées
    case "$DETECTED_SPECIES" in
        *"Escherichia coli"*|*"E. coli"*)
            POINTFINDER_SPECIES="escherichia_coli"
            ;;
        *"Salmonella"*)
            POINTFINDER_SPECIES="salmonella"
            ;;
        *"Staphylococcus aureus"*|*"S. aureus"*)
            POINTFINDER_SPECIES="staphylococcus_aureus"
            ;;
        *"Campylobacter"*)
            POINTFINDER_SPECIES="campylobacter"
            ;;
        *"Klebsiella"*)
            POINTFINDER_SPECIES="klebsiella"
            ;;
        *"Enterococcus faecalis"*)
            POINTFINDER_SPECIES="enterococcus_faecalis"
            ;;
        *"Enterococcus faecium"*)
            POINTFINDER_SPECIES="enterococcus_faecium"
            ;;
        *"Mycobacterium tuberculosis"*)
            POINTFINDER_SPECIES="mycobacterium_tuberculosis"
            ;;
        *"Neisseria gonorrhoeae"*)
            POINTFINDER_SPECIES="neisseria_gonorrhoeae"
            ;;
        *)
            log_info "  Espèce '$DETECTED_SPECIES' non supportée par PointFinder"
            ;;
    esac
fi

# Définir le chemin de la base PointFinder
if [[ -z "${POINTFINDER_DB:-}" ]]; then
    POINTFINDER_DB=$(find_pointfinder_db)
fi

# Si toujours pas de base, proposer le téléchargement
if [[ -z "$POINTFINDER_DB" ]] || [[ ! -f "$POINTFINDER_DB/config" ]]; then
    log_warn "  Base PointFinder non trouvée - téléchargement automatique..."
    download_pointfinder_db "$DB_DIR"
    POINTFINDER_DB="$DB_DIR/pointfinder_db"
fi

if [[ -n "$POINTFINDER_SPECIES" ]] && [[ -d "$POINTFINDER_DB/$POINTFINDER_SPECIES" ]]; then
    log_info "  Analyse PointFinder pour: $POINTFINDER_SPECIES"

    # Exécuter ResFinder avec PointFinder
    python3 -m resfinder \
        --inputfasta "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna \
        --outputPath "$RESULTS_DIR"/04_arg_detection/pointfinder \
        --species "$POINTFINDER_SPECIES" \
        --point \
        --db_path_point "$POINTFINDER_DB" \
        --ignore_missing_species 2>> "$LOG_FILE" || log_warn "  PointFinder a rencontré des avertissements"

    # Vérifier les résultats
    if [[ -f "$RESULTS_DIR/04_arg_detection/pointfinder/PointFinder_results.txt" ]]; then
        POINT_COUNT=$(grep -c "mutation" "$RESULTS_DIR/04_arg_detection/pointfinder/PointFinder_results.txt" 2>/dev/null || echo "0")
        log_success "PointFinder terminé - $POINT_COUNT mutations détectées"
    elif [[ -f "$RESULTS_DIR/04_arg_detection/pointfinder/pointfinder_results.txt" ]]; then
        POINT_COUNT=$(tail -n +2 "$RESULTS_DIR/04_arg_detection/pointfinder/pointfinder_results.txt" | wc -l)
        log_success "PointFinder terminé - $POINT_COUNT mutations détectées"
    else
        log_info "  Aucune mutation chromosomique détectée"
    fi
else
    if [[ -z "$POINTFINDER_SPECIES" ]]; then
        log_info "  PointFinder ignoré (espèce non supportée)"
    else
        log_warn "  Base PointFinder non trouvée pour $POINTFINDER_SPECIES"
    fi
fi

#------- 4.8 Synthèse ARG -------
log_info "4.8 Synthèse des résultats ARG..."

{
    echo "Sample ID: $SAMPLE_ID"
    echo "Date: $(date)"
    echo ""
    echo "=== AMRFinderPlus ==="
    wc -l < "$RESULTS_DIR"/04_arg_detection/amrfinderplus/"${SAMPLE_ID}"_amrfinderplus.tsv 2>/dev/null || echo "0"
    echo ""
    echo "=== ResFinder ==="
    wc -l < "$RESULTS_DIR"/04_arg_detection/resfinder/"${SAMPLE_ID}"_resfinder.tsv 2>/dev/null || echo "0"
    echo ""
    echo "=== PlasmidFinder ==="
    wc -l < "$RESULTS_DIR"/04_arg_detection/plasmidfinder/"${SAMPLE_ID}"_plasmidfinder.tsv 2>/dev/null || echo "0"
    echo ""
    echo "=== RGI/CARD ==="
    if [[ -f "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_rgi.txt" ]]; then
        tail -n +2 "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_rgi.txt" | wc -l
        echo "  dont gènes intrinsèques/efflux:"
        wc -l < "$RESULTS_DIR/04_arg_detection/rgi/${SAMPLE_ID}_intrinsic.txt" 2>/dev/null || echo "  0"
    else
        echo "Non exécuté"
    fi
    echo ""
    echo "=== PointFinder (mutations SNP) ==="
    if [[ -d "$RESULTS_DIR/04_arg_detection/pointfinder" ]]; then
        find "$RESULTS_DIR/04_arg_detection/pointfinder" -name "*results*" -exec wc -l {} \; 2>/dev/null | head -1 || echo "Aucune mutation"
    else
        echo "Non exécuté (espèce non supportée)"
    fi
} > "$RESULTS_DIR"/04_arg_detection/synthesis/"${SAMPLE_ID}"_ARG_synthesis.tsv

log_success "Synthèse ARG terminée"

log_success "MODULE 4 TERMINÉ"

#===============================================================================
# MODULE 5 : VARIANT CALLING - IGNORÉ SI FASTA ASSEMBLÉ
#===============================================================================

if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_info "═══════════════════════════════════════════════════════════════════"
    log_warn "MODULE 5 : VARIANT CALLING - IGNORÉ (entrée FASTA assemblée)"
    log_info "  (Pas de reads disponibles pour le variant calling)"
    log_info "═══════════════════════════════════════════════════════════════════"
else
    log_info "═══════════════════════════════════════════════════════════════════"
    log_info "MODULE 5 : VARIANT CALLING"
    log_info "═══════════════════════════════════════════════════════════════════"

    # [Docker] Snippy est dans l'env snippy_prokka, samtools/bcftools dans megam_arg

    #------- 5.1 Préparation du génome de référence -------
    log_info "5.1 Préparation du génome de référence..."

    SNIPPY_WORK="$RESULTS_DIR"/05_variant_calling/snippy

    mkdir -p "$SNIPPY_WORK"

    # Télécharger ou récupérer la référence appropriée pour l'espèce détectée
    log_info "Recherche de la référence pour l'espèce détectée..."
    if [[ -n "$PROKKA_GENUS" ]] && [[ "$PROKKA_GENUS" != "Bacteria" ]]; then
        log_info "  Espèce détectée: $PROKKA_GENUS $PROKKA_SPECIES"
        # || true pour éviter l'arrêt du script si la référence n'est pas trouvée
        get_or_download_reference "$PROKKA_GENUS" "$PROKKA_SPECIES" || true
    else
        log_warn "  Aucune espèce spécifique détectée"
        # Essayer avec la référence par défaut
        if [[ -f "$REFERENCE_DIR/ecoli_k12.fasta" ]]; then
            REFERENCE_GENOME="$REFERENCE_DIR/ecoli_k12.fasta"
            log_info "  Utilisation de la référence par défaut: E. coli K-12"
        else
            REFERENCE_GENOME=""
        fi
    fi

    # Utiliser la référence trouvée/téléchargée ou fallback sur l'assemblage
    if [[ -n "$REFERENCE_GENOME" ]] && [[ -f "$REFERENCE_GENOME" ]]; then
        log_success "Référence utilisée: $REFERENCE_GENOME"
        cp "$REFERENCE_GENOME" "$SNIPPY_WORK"/reference.fa
    else
        log_warn "Aucune référence disponible. Utilisation de l'assemblage comme référence."
        log_warn "  Note: Les variants seront relatifs à l'assemblage lui-même"
        cp "$RESULTS_DIR"/03_annotation/prokka/"${SAMPLE_ID}".fna "$SNIPPY_WORK"/reference.fa
    fi

    log_success "Référence préparée"

    #------- 5.2 Variant Calling avec Snippy -------
    log_info "5.2 Variant Calling avec Snippy..."

    if [[ "$IS_SINGLE_END" == true ]]; then
        # Mode single-end
        log_info "  Mode single-end détecté"
        mamba run --no-banner -n snippy_prokka snippy \
            --outdir "$SNIPPY_WORK" \
            --prefix "$SAMPLE_ID" \
            --reference "$SNIPPY_WORK"/reference.fa \
            --se "$CLEAN_R1" \
            --cpus "$THREADS" \
            --force 2>&1 | tee -a "$LOG_FILE"
    else
        # Mode paired-end
        mamba run --no-banner -n snippy_prokka snippy \
            --outdir "$SNIPPY_WORK" \
            --prefix "$SAMPLE_ID" \
            --reference "$SNIPPY_WORK"/reference.fa \
            --R1 "$CLEAN_R1" \
            --R2 "$CLEAN_R2" \
            --cpus "$THREADS" \
            --force 2>&1 | tee -a "$LOG_FILE"
    fi

    log_success "Variant Calling terminé"

    #------- 5.3 Copie des résultats -------
    log_info "5.3 Organisation des résultats variants..."

    if [[ -f "$SNIPPY_WORK"/"${SAMPLE_ID}".vcf ]]; then
        cp "$SNIPPY_WORK"/"${SAMPLE_ID}".vcf "$RESULTS_DIR"/05_variant_calling/"${SAMPLE_ID}"_variants.vcf
        log_success "Fichier VCF copié"
    fi

    log_success "MODULE 5 TERMINÉ"
fi  # Fin du bloc conditionnel Module 5

#===============================================================================
# MODULE 6 : ANALYSE ET GÉNÉRATION DE RAPPORTS
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "MODULE 6 : ANALYSE ET GÉNÉRATION DE RAPPORTS"
log_info "═══════════════════════════════════════════════════════════════════"

# [Docker] Les outils analyse (python3, pandas, matplotlib, etc.) sont dans l'env megam_arg déjà activé

#------- 6.1 Génération des métadonnées -------
log_info "6.1 Génération des métadonnées..."

# Utiliser SCRIPT_DIR déjà défini au début du script
METADATA_SCRIPT="$PYTHON_DIR/generate_metadata.py"

if [[ -f "$METADATA_SCRIPT" ]]; then
    # Passer l'espèce détectée si disponible
    if [[ -n "$DETECTED_SPECIES" ]]; then
        export NCBI_DETECTED_SPECIES="$DETECTED_SPECIES"
    fi
    
    python3 "$METADATA_SCRIPT" "$RESULTS_DIR" "$SAMPLE_ID" "$INPUT_TYPE" "$INPUT_ARG" "$THREADS" 2>&1 | tee -a "$LOG_FILE"
    log_success "Métadonnées générées: $RESULTS_DIR/METADATA.json"
else
    log_warn "Script de génération de métadonnées non trouvé: $METADATA_SCRIPT"
fi

#------- 6.2 Génération des rapports -------
log_info "6.2 Génération des rapports..."

{
    echo "================================================================================"
    echo "RAPPORT D'ANALYSE PIPELINE ARG v3.2"
    echo "================================================================================"
    echo ""
    echo "Échantillon: $SAMPLE_ID"
    echo "Type d'entrée: $INPUT_TYPE"
    echo "Version: $RESULTS_VERSION"
    echo "Date: $(date)"
    echo "Répertoire de résultats: $RESULTS_DIR"
    echo ""
    echo "================================================================================"
    echo "RÉSUMÉ DES RÉSULTATS"
    echo "================================================================================"
    echo ""
    if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
        echo "1. CONTRÔLE QUALITÉ"
        echo "   - IGNORÉ (entrée FASTA assemblée)"
        echo ""
        echo "2. ASSEMBLAGE"
        echo "   - IGNORÉ (entrée FASTA assemblée)"
    else
        echo "1. CONTRÔLE QUALITÉ"
        echo "   - FastQC: Complété"
        echo "   - Fastp: Complété"
        echo "   - NCBI API: Espèce détectée (si disponible)"
        echo ""
        echo "2. ASSEMBLAGE"
        echo "   - SPAdes: Complété (mode isolate)"
        echo "   - QUAST: Complété"
    fi
    echo ""
    echo "3. ANNOTATION"
    echo "   - Prokka: Complété"
    echo ""
    echo "4. DÉTECTION ARG"
    echo "   - AMRFinderPlus: Complété"
    echo "   - ResFinder: Complété"
    echo "   - PlasmidFinder: Complété"
    echo "   - CARD: Complété"
    echo "   - NCBI: Complété"
    echo ""
    if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
        echo "5. VARIANT CALLING"
        echo "   - IGNORÉ (entrée FASTA assemblée)"
    else
        echo "5. VARIANT CALLING"
        echo "   - Snippy: Complété"
    fi
    echo ""
    echo "6. ANALYSE ET RAPPORTS"
    echo "   - Rapport texte: Complété"
    echo "   - Rapport HTML professionnel: Complété"
    echo ""
    echo "================================================================================"
    echo "FICHIERS PRINCIPAUX GÉNÉRÉS"
    echo "================================================================================"
    echo ""
    if [[ "$IS_ASSEMBLED_INPUT" == false ]]; then
        ls -1 "$RESULTS_DIR"/01_qc/fastqc_raw/*.html 2>/dev/null | head -2 | sed 's|^|  - |' || true
    fi
    ls -1 "$RESULTS_DIR"/02_assembly/filtered/*.fasta 2>/dev/null | head -1 | sed 's|^|  - |' || true
    ls -1 "$RESULTS_DIR"/03_annotation/prokka/*.gff 2>/dev/null | head -1 | sed 's|^|  - |' || true
    ls -1 "$RESULTS_DIR"/04_arg_detection/*/*.tsv 2>/dev/null | head -3 | sed 's|^|  - |' || true
    if [[ "$IS_ASSEMBLED_INPUT" == false ]]; then
        ls -1 "$RESULTS_DIR"/05_variant_calling/*_variants.vcf 2>/dev/null | head -1 | sed 's|^|  - |' || true
    fi
} > "$RESULTS_DIR"/06_analysis/reports/"${SAMPLE_ID}"_summary.txt

log_success "Rapport texte généré"

open_file_safe "$RESULTS_DIR/06_analysis/reports/${SAMPLE_ID}_summary.txt" "Pipeline Summary Report"

#------- 6.2 Génération du rapport ARG professionnel -------
log_info "6.2 Génération du rapport ARG professionnel..."

ARG_REPORT_SCRIPT="$PYTHON_DIR/generate_arg_report.py"

# Utiliser DETECTED_SPECIES déjà extraite par fetch_species_from_ncbi()
# Si elle n'a pas été définie, essayer de l'extraire maintenant
if [[ -z "$DETECTED_SPECIES" ]]; then
    fetch_species_from_ncbi "$SAMPLE_ID" "$INPUT_TYPE" || true
fi

if [[ -f "$ARG_REPORT_SCRIPT" ]]; then
    # Passer l'espèce détectée au script Python via variable d'environnement
    if [[ -n "$DETECTED_SPECIES" ]]; then
        export NCBI_DETECTED_SPECIES="$DETECTED_SPECIES"
        log_info "Espèce passée au script de rapport: $DETECTED_SPECIES"
    else
        log_info "Aucune espèce détectée via NCBI"
    fi

    # Passer les résultats MLST au script Python
    if [[ -n "$MLST_ST" ]] && [[ "$MLST_ST" != "-" ]]; then
        export MLST_SCHEME="$MLST_SCHEME"
        export MLST_ST="$MLST_ST"
        export MLST_ALLELES="$MLST_ALLELES"
        log_info "MLST passé au script de rapport: $MLST_SCHEME / ST$MLST_ST"
    fi
    
    log_info "Exécution du script de génération de rapport HTML..."
    if python3 "$ARG_REPORT_SCRIPT" "$RESULTS_DIR" "$SAMPLE_ID" 2>&1 | tee -a "$LOG_FILE"; then
        if [[ -f "$RESULTS_DIR/06_analysis/reports/${SAMPLE_ID}_ARG_professional_report.html" ]]; then
            log_success "Rapport ARG professionnel généré"
            open_file_safe "$RESULTS_DIR/06_analysis/reports/${SAMPLE_ID}_ARG_professional_report.html" "ARG Professional Report"
        else
            log_warn "Rapport ARG professionnel: Le fichier HTML n'a pas été créé"
            log_warn "Vérifiez les erreurs ci-dessus dans le journal"
        fi
    else
        log_error "Erreur lors de l'exécution du script de génération de rapport"
        log_error "Vérifiez que Python3 et les dépendances sont installées"
    fi
else
    log_warn "Script de rapport ARG non trouvé: $ARG_REPORT_SCRIPT"
    log_warn "Le rapport HTML ne sera pas généré"
fi

log_success "MODULE 6 TERMINÉ"

#===============================================================================
# RÉSUMÉ FINAL
#===============================================================================

log_info "═══════════════════════════════════════════════════════════════════"
log_info "PIPELINE ARG v3.2 - EXÉCUTION COMPLÈTE"
log_info "═══════════════════════════════════════════════════════════════════"

log_success "TOUS LES MODULES COMPLÉTÉS AVEC SUCCÈS"

log_info ""
log_info "Configuration utilisée:"
log_info "   Échantillon: $SAMPLE_ID"
log_info "   Type d'entrée: $INPUT_TYPE"
if [[ "$IS_ASSEMBLED_INPUT" == true ]]; then
    log_info "   Modules exécutés: Annotation, Détection ARG, Analyse"
    log_info "   Modules ignorés: QC, Assemblage, Variant Calling"
else
    log_info "   Modules exécutés: QC, Assemblage, Annotation, Détection ARG, Variant Calling, Analyse"
fi
log_info ""
log_info "Fichiers de résultats disponibles dans:"
log_info "   $RESULTS_DIR"
log_info ""
log_info "Logs disponibles dans:"
log_info "   $LOG_DIR"
log_info ""
log_info "Fichier principal de log:"
log_info "   $LOG_FILE"
log_info ""
log_info "Archives stockées dans:"
log_info "   $ARCHIVE_DIR"
log_info ""

# Afficher le résumé des fichiers générés
log_info "Fichiers principaux générés:"
find "$RESULTS_DIR" -type f \( -name "*.html" -o -name "*_report.*" -o -name "*_summary.*" \) 2>/dev/null | while read f; do
    log_info "  ✓ $(basename "$f")"
done

log_success "═══════════════════════════════════════════════════════════════════"
log_success "Pipeline ARG v3.2 - TERMINÉ AVEC SUCCÈS!"
log_success "═══════════════════════════════════════════════════════════════════"

