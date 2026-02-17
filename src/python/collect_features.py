#!/usr/bin/env python3
"""
PIPELINE ARG v4.0 - collect_features.py
Extraction de features pour Machine Learning

Ce script extrait les métriques clés de chaque analyse pour construire
un dataset ML permettant de prédire la résistance aux antibiotiques.

Sorties:
- features_ml.csv: Features de l'échantillon courant
- Append au global_dataset.csv si spécifié
"""

import os
import sys
import json
import argparse
import csv
from datetime import datetime
from pathlib import Path
from collections import defaultdict


def parse_args():
    """Parse les arguments de la ligne de commande."""
    parser = argparse.ArgumentParser(
        description="Extraction de features ML pour la prédiction ARG"
    )
    parser.add_argument(
        "--results-dir", "-r",
        required=True,
        help="Répertoire des résultats de l'échantillon"
    )
    parser.add_argument(
        "--sample-id", "-s",
        required=True,
        help="Identifiant de l'échantillon"
    )
    parser.add_argument(
        "--species",
        default="unknown",
        help="Espèce détectée"
    )
    parser.add_argument(
        "--mlst-st",
        default="-",
        help="Sequence Type MLST"
    )
    parser.add_argument(
        "--global-dataset", "-g",
        default=None,
        help="Chemin vers le dataset global (pour append)"
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="Fichier de sortie (défaut: results_dir/features_ml.csv)"
    )

    return parser.parse_args()


def parse_quast_metrics(results_dir, sample_id):
    """Parse les métriques QUAST."""
    metrics = {
        "n50": 0,
        "total_length": 0,
        "num_contigs": 0,
        "gc_percent": 0,
        "largest_contig": 0,
        "l50": 0
    }

    quast_report = Path(results_dir) / "02_assembly" / "quast" / "report.tsv"

    if not quast_report.exists():
        return metrics

    try:
        with open(quast_report, 'r') as f:
            for line in f:
                parts = line.strip().split('\t')
                if len(parts) >= 2:
                    key, value = parts[0], parts[1]

                    if key == "N50":
                        metrics["n50"] = int(value) if value.isdigit() else 0
                    elif key == "Total length":
                        metrics["total_length"] = int(value) if value.isdigit() else 0
                    elif key == "# contigs":
                        metrics["num_contigs"] = int(value) if value.isdigit() else 0
                    elif key == "GC (%)":
                        metrics["gc_percent"] = float(value) if value else 0
                    elif key == "Largest contig":
                        metrics["largest_contig"] = int(value) if value.isdigit() else 0
                    elif key == "L50":
                        metrics["l50"] = int(value) if value.isdigit() else 0
    except Exception as e:
        print(f"Erreur parsing QUAST: {e}", file=sys.stderr)

    return metrics


def parse_amrfinder(results_dir, sample_id):
    """Parse les résultats AMRFinderPlus et retourne les gènes détectés."""
    genes = set()
    classes = defaultdict(int)

    amr_file = Path(results_dir) / "04_arg_detection" / "amrfinderplus" / f"{sample_id}_amrfinderplus.tsv"

    if not amr_file.exists():
        return genes, classes

    try:
        with open(amr_file, 'r') as f:
            header = f.readline().strip().split('\t')
            gene_idx = header.index("Gene symbol") if "Gene symbol" in header else 5
            class_idx = header.index("Class") if "Class" in header else 10
            type_idx = header.index("Element type") if "Element type" in header else 8

            for line in f:
                parts = line.strip().split('\t')
                if len(parts) > max(gene_idx, class_idx, type_idx):
                    gene = parts[gene_idx]
                    element_type = parts[type_idx] if type_idx < len(parts) else "AMR"

                    # Ne compter que les gènes AMR (pas VIRULENCE/STRESS)
                    if element_type == "AMR":
                        genes.add(gene)

                        if class_idx < len(parts):
                            drug_class = parts[class_idx]
                            if drug_class:
                                classes[drug_class] += 1
    except Exception as e:
        print(f"Erreur parsing AMRFinder: {e}", file=sys.stderr)

    return genes, classes


def parse_resfinder(results_dir, sample_id):
    """Parse les résultats ResFinder."""
    genes = set()

    res_file = Path(results_dir) / "04_arg_detection" / "resfinder" / f"{sample_id}_resfinder.tsv"

    if not res_file.exists():
        return genes

    try:
        with open(res_file, 'r') as f:
            for line in f:
                if line.startswith('#'):
                    continue
                parts = line.strip().split('\t')
                if len(parts) >= 6:
                    gene = parts[5]  # Colonne GENE
                    if gene:
                        genes.add(gene)
    except Exception as e:
        print(f"Erreur parsing ResFinder: {e}", file=sys.stderr)

    return genes


def parse_rgi(results_dir, sample_id):
    """Parse les résultats RGI."""
    genes = set()
    mechanisms = defaultdict(int)

    rgi_file = Path(results_dir) / "04_arg_detection" / "rgi" / f"{sample_id}_rgi.txt"

    if not rgi_file.exists():
        return genes, mechanisms

    try:
        with open(rgi_file, 'r') as f:
            header = f.readline()  # Skip header
            for line in f:
                parts = line.strip().split('\t')
                if len(parts) >= 9:
                    gene = parts[8]  # Best_Hit_ARO
                    if gene:
                        genes.add(gene.split()[0])  # Prendre le premier mot

                    if len(parts) >= 16:
                        mechanism = parts[15]  # Resistance Mechanism
                        if mechanism:
                            mechanisms[mechanism] += 1
    except Exception as e:
        print(f"Erreur parsing RGI: {e}", file=sys.stderr)

    return genes, mechanisms


def parse_vfdb(results_dir, sample_id):
    """Parse les résultats VFDB (virulence)."""
    genes = set()

    vfdb_file = Path(results_dir) / "04_arg_detection" / "vfdb" / f"{sample_id}_vfdb.tsv"

    if not vfdb_file.exists():
        return genes

    try:
        with open(vfdb_file, 'r') as f:
            for line in f:
                if line.startswith('#'):
                    continue
                parts = line.strip().split('\t')
                if len(parts) >= 6:
                    gene = parts[5]  # Colonne GENE
                    if gene:
                        genes.add(gene)
    except Exception as e:
        print(f"Erreur parsing VFDB: {e}", file=sys.stderr)

    return genes


def parse_fastp_metrics(results_dir, sample_id):
    """Parse les métriques Fastp (qualité des reads)."""
    metrics = {
        "total_reads": 0,
        "total_bases": 0,
        "q30_rate": 0,
        "gc_content": 0,
        "duplication_rate": 0
    }

    fastp_json = Path(results_dir) / "01_qc" / "fastp" / f"{sample_id}_fastp.json"

    if not fastp_json.exists():
        return metrics

    try:
        with open(fastp_json, 'r') as f:
            data = json.load(f)

        if "summary" in data and "after_filtering" in data["summary"]:
            after = data["summary"]["after_filtering"]
            metrics["total_reads"] = after.get("total_reads", 0)
            metrics["total_bases"] = after.get("total_bases", 0)
            metrics["q30_rate"] = after.get("q30_rate", 0)
            metrics["gc_content"] = after.get("gc_content", 0)

        if "duplication" in data:
            metrics["duplication_rate"] = data["duplication"].get("rate", 0)

    except Exception as e:
        print(f"Erreur parsing Fastp: {e}", file=sys.stderr)

    return metrics


def get_common_arg_genes():
    """Retourne la liste des gènes ARG communs pour le vecteur binaire."""
    # Gènes de résistance les plus fréquents/importants
    return [
        # Beta-lactamases
        "blaTEM", "blaSHV", "blaCTX-M", "blaOXA", "blaNDM", "blaKPC", "blaVIM", "blaIMP",
        "blaCMY", "blaAmpC", "blaDHA", "blaGES",
        # Aminoglycosides
        "aac(3)", "aac(6')", "aph(3')", "aadA", "armA", "rmtB", "strA", "strB",
        # Fluoroquinolones
        "qnrA", "qnrB", "qnrS", "aac(6')-Ib-cr", "oqxA", "oqxB",
        # Tetracyclines
        "tetA", "tetB", "tetC", "tetM", "tetO", "tetW",
        # Macrolides
        "ermA", "ermB", "ermC", "mphA", "msrA",
        # Sulfonamides/Trimethoprim
        "sul1", "sul2", "sul3", "dfrA",
        # Glycopeptides
        "vanA", "vanB", "vanC",
        # Phenicols
        "catA", "floR", "cmlA",
        # Colistin
        "mcr-1", "mcr-2", "mcr-3", "mcr-4", "mcr-5",
        # Rifampicin
        "arr",
        # Fosfomycin
        "fosA",
        # Efflux pumps
        "acrA", "acrB", "tolC"
    ]


def create_binary_vector(detected_genes, reference_genes):
    """Crée un vecteur binaire de présence/absence des gènes."""
    vector = {}
    detected_lower = {g.lower() for g in detected_genes}

    for ref_gene in reference_genes:
        # Vérifier si le gène de référence est présent (correspondance partielle)
        is_present = 0
        ref_lower = ref_gene.lower()

        for detected in detected_lower:
            if ref_lower in detected or detected in ref_lower:
                is_present = 1
                break

        vector[f"gene_{ref_gene}"] = is_present

    return vector


def collect_features(args):
    """Collecte toutes les features et génère le CSV."""
    results_dir = Path(args.results_dir)
    sample_id = args.sample_id

    print(f"Extraction des features pour: {sample_id}")

    # Initialiser le dictionnaire de features
    features = {
        "sample_id": sample_id,
        "species": args.species,
        "mlst_st": args.mlst_st,
        "analysis_date": datetime.now().isoformat()
    }

    # Métriques d'assemblage (QUAST)
    quast_metrics = parse_quast_metrics(results_dir, sample_id)
    features.update(quast_metrics)

    # Métriques de qualité (Fastp)
    fastp_metrics = parse_fastp_metrics(results_dir, sample_id)
    features.update(fastp_metrics)

    # Gènes ARG détectés
    amr_genes, amr_classes = parse_amrfinder(results_dir, sample_id)
    res_genes = parse_resfinder(results_dir, sample_id)
    rgi_genes, rgi_mechanisms = parse_rgi(results_dir, sample_id)
    vf_genes = parse_vfdb(results_dir, sample_id)

    # Fusion de tous les gènes détectés
    all_arg_genes = amr_genes | res_genes | rgi_genes
    all_vf_genes = vf_genes

    # Comptages
    features["total_arg_genes"] = len(all_arg_genes)
    features["total_virulence_genes"] = len(all_vf_genes)
    features["amrfinder_count"] = len(amr_genes)
    features["resfinder_count"] = len(res_genes)
    features["rgi_count"] = len(rgi_genes)
    features["vfdb_count"] = len(vf_genes)

    # Classes de résistance (top 10)
    top_classes = sorted(amr_classes.items(), key=lambda x: x[1], reverse=True)[:10]
    for i, (cls, count) in enumerate(top_classes):
        features[f"drug_class_{i+1}"] = cls
        features[f"drug_class_{i+1}_count"] = count

    # Vecteur binaire de présence/absence des gènes communs
    reference_genes = get_common_arg_genes()
    binary_vector = create_binary_vector(all_arg_genes, reference_genes)
    features.update(binary_vector)

    # Liste des gènes détectés (pour référence)
    features["detected_arg_genes"] = ";".join(sorted(all_arg_genes))
    features["detected_vf_genes"] = ";".join(sorted(all_vf_genes))

    return features


def save_features(features, output_file, global_dataset=None):
    """Sauvegarde les features en CSV."""

    # Créer le répertoire si nécessaire
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Écrire le fichier de l'échantillon
    with open(output_file, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=features.keys())
        writer.writeheader()
        writer.writerow(features)

    print(f"Features sauvegardées: {output_file}")

    # Append au dataset global si spécifié
    if global_dataset:
        global_path = Path(global_dataset)
        file_exists = global_path.exists()

        with open(global_path, 'a', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=features.keys())

            # Écrire le header seulement si le fichier n'existait pas
            if not file_exists:
                writer.writeheader()

            writer.writerow(features)

        print(f"Ligne ajoutée au dataset global: {global_dataset}")


def main():
    args = parse_args()

    # Définir le fichier de sortie
    output_file = args.output
    if output_file is None:
        output_file = Path(args.results_dir) / "features_ml.csv"

    # Collecter les features
    features = collect_features(args)

    # Sauvegarder
    save_features(features, output_file, args.global_dataset)

    print(f"\n✅ Extraction terminée")
    print(f"   Total gènes ARG: {features['total_arg_genes']}")
    print(f"   Total gènes virulence: {features['total_virulence_genes']}")
    print(f"   Espèce: {features['species']}")
    print(f"   MLST: ST{features['mlst_st']}")


if __name__ == "__main__":
    main()
