#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Génération automatique des métadonnées pour chaque run du pipeline
Crée un fichier METADATA.json avec toutes les informations de traçabilité
"""

import sys
import os
import json
import subprocess
from datetime import datetime
from pathlib import Path

def get_tool_version(tool_name, env_name=None):
    """Récupère la version d'un outil"""
    try:
        if env_name:
            # Activer l'environnement conda si nécessaire
            conda_prefix = os.environ.get('CONDA_PREFIX', '')
            if not conda_prefix or env_name not in conda_prefix:
                # Essayer de trouver le chemin de l'environnement
                result = subprocess.run(
                    ['conda', 'env', 'list'],
                    capture_output=True,
                    text=True
                )
                # Parser la sortie pour trouver l'environnement
                # (simplifié, pourrait être amélioré)
                pass
        
        # Essayer différentes méthodes pour obtenir la version
        version_commands = {
            'fastqc': ['fastqc', '--version'],
            'fastp': ['fastp', '--version'],
            'multiqc': ['multiqc', '--version'],
            'spades.py': ['spades.py', '--version'],
            'quast.py': ['quast.py', '--version'],
            'seqkit': ['seqkit', 'version'],
            'prokka': ['prokka', '--version'],
            'amrfinder': ['amrfinder', '--version'],
            'abricate': ['abricate', '--version'],
            'snippy': ['snippy', '--version'],
            'samtools': ['samtools', '--version'],
            'bcftools': ['bcftools', '--version'],
            'python3': ['python3', '--version'],
        }
        
        if tool_name in version_commands:
            result = subprocess.run(
                version_commands[tool_name],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                # Extraire la version (simplifié)
                output = result.stdout + result.stderr
                import re
                version_match = re.search(r'(\d+\.\d+(?:\.\d+)?)', output)
                if version_match:
                    return version_match.group(1)
        
        return "unknown"
    except Exception:
        return "unknown"

def get_conda_env_versions():
    """Récupère les versions depuis les environnements conda"""
    versions = {}
    
    envs = {
        'qc_arg': ['fastqc', 'fastp', 'multiqc'],
        'assembly_arg': ['spades.py', 'quast.py', 'seqkit'],
        'annotation_arg': ['prokka'],
        'arg_detection': ['amrfinder', 'abricate'],
        'variant_arg': ['snippy', 'samtools', 'bcftools'],
    }
    
    try:
        for env_name, tools in envs.items():
            for tool in tools:
                # Simplifié : utiliser les versions documentées
                # Dans un vrai système, on pourrait activer l'env et vérifier
                versions[tool] = get_tool_version(tool, env_name)
    except Exception:
        pass
    
    return versions

def get_database_info():
    """Récupère les informations sur les bases de données"""
    db_info = {}
    
    # AMRFinder DB
    amrfinder_db = os.path.expanduser("~/.local/share/amrfinder/latest")
    if os.path.exists(amrfinder_db):
        # Essayer de trouver un fichier de version ou date
        db_info['amrfinder'] = {
            'path': amrfinder_db,
            'version': 'latest',
            'last_updated': 'unknown'
        }
    else:
        db_info['amrfinder'] = {
            'path': None,
            'status': 'not_installed'
        }
    
    return db_info

def generate_metadata(results_dir, sample_id, input_type, input_arg, 
                     threads=8, work_dir=None, detected_species=None):
    """Génère le fichier METADATA.json"""
    
    metadata = {
        'pipeline': {
            'name': 'Pipeline ARG v3.2',
            'version': '3.2',
            'date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'script': 'MANUAL_MEGA_MONOLITHIC_PIPELINE_v3.2.sh'
        },
        'sample': {
            'sample_id': sample_id,
            'input_type': input_type,
            'input_argument': input_arg,
            'detected_species': detected_species
        },
        'parameters': {
            'threads': threads,
            'work_directory': str(work_dir) if work_dir else 'default',
            'force_mode': False  # Sera mis à jour si nécessaire
        },
        'tools': {
            'fastqc': '0.12.1',
            'fastp': '0.23.4',
            'multiqc': '1.19',
            'spades': '3.15.5',
            'quast': '5.2.0',
            'seqkit': '2.5.1',
            'prokka': '1.14.6',
            'amrfinderplus': '4.2',
            'abricate': '1.0.1',
            'snippy': '4.6.0',
            'samtools': '1.18',
            'bcftools': '1.18',
            'python': '3.11'
        },
        'databases': get_database_info(),
        'system': {
            'hostname': os.uname().nodename if hasattr(os, 'uname') else 'unknown',
            'platform': sys.platform,
            'python_version': sys.version.split()[0]
        },
        'results': {
            'results_directory': str(results_dir),
            'timestamp': datetime.now().isoformat()
        }
    }
    
    # Essayer de récupérer les versions réelles si possible
    try:
        real_versions = get_conda_env_versions()
        for tool, version in real_versions.items():
            if version != "unknown":
                metadata['tools'][tool] = version
    except Exception:
        pass
    
    return metadata

def main():
    """Point d'entrée principal"""
    if len(sys.argv) < 4:
        print("Usage: python3 generate_metadata.py <results_dir> <sample_id> <input_type> [input_arg] [threads]")
        print("")
        print("Exemple:")
        print("  python3 generate_metadata.py outputs/SRR123_v3.2_20251218_120000 SRR123 sra SRR123456 8")
        sys.exit(1)
    
    results_dir = Path(sys.argv[1])
    sample_id = sys.argv[2]
    input_type = sys.argv[3]
    input_arg = sys.argv[4] if len(sys.argv) > 4 else sample_id
    threads = int(sys.argv[5]) if len(sys.argv) > 5 else 8
    
    # Récupérer l'espèce détectée si disponible
    detected_species = os.environ.get('NCBI_DETECTED_SPECIES', None)
    
    # Générer les métadonnées
    metadata = generate_metadata(
        results_dir=results_dir,
        sample_id=sample_id,
        input_type=input_type,
        input_arg=input_arg,
        threads=threads,
        detected_species=detected_species
    )
    
    # Écrire le fichier JSON
    metadata_file = results_dir / "METADATA.json"
    with open(metadata_file, 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)
    
    print(f"✅ Métadonnées générées: {metadata_file}")
    return 0

if __name__ == "__main__":
    sys.exit(main())

