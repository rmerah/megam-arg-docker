#!/usr/bin/env python3
"""
ARG Report Generator - Pipeline v3.1
Génère un rapport HTML professionnel pour la détection des gènes de résistance aux antibiotiques
"""

import sys
import os
import json
from datetime import datetime
from collections import defaultdict

def classify_resistance_type(gene_data):
    """Classifie le type de résistance: Acquis (mobile) vs Mutation (chromosomique)

    Returns:
        tuple: (type_label, type_code, color)
            - type_label: Texte affiché ("Acquis" ou "Mutation")
            - type_code: Code technique ("ACQUIRED" ou "MUTATION")
            - color: Couleur hex pour l'affichage
    """
    source = gene_data.get('source', '').upper()
    method = gene_data.get('method', '').upper()
    model_type = gene_data.get('model_type', '').lower()

    # AMRFinder+ - basé sur la méthode de détection
    if 'AMRFINDER' in source:
        if method in ['POINTX', 'POINTN', 'POINTMUT']:
            return 'Mutation', 'MUTATION', '9C27B0'  # Violet
        else:
            # EXACTX, BLASTX, ALLELEX, HMM, PARTIAL, INTERNAL_STOP = gènes acquis
            return 'Acquis', 'ACQUIRED', '2196F3'  # Bleu

    # RGI/CARD - basé sur le model_type
    if 'RGI' in source or 'CARD' in source:
        if 'variant' in model_type:
            # protein variant, rRNA variant = mutations
            return 'Mutation', 'MUTATION', '9C27B0'  # Violet
        elif 'overexpression' in model_type or 'knockout' in model_type:
            return 'Expression', 'EXPRESSION', 'FF9800'  # Orange
        else:
            # protein homolog = gène acquis
            return 'Acquis', 'ACQUIRED', '2196F3'  # Bleu

    # PointFinder - toujours des mutations
    if 'POINTFINDER' in source:
        return 'Mutation', 'MUTATION', '9C27B0'  # Violet

    # ResFinder - généralement des gènes acquis
    if 'RESFINDER' in source:
        return 'Acquis', 'ACQUIRED', '2196F3'  # Bleu

    # Par défaut - inconnu
    return 'Inconnu', 'UNKNOWN', '757575'  # Gris


def classify_gravity(gene_data):
    """
    Classifie la gravité d'un gène ARG (CRITICAL, HIGH, MEDIUM)
    Basé sur les standards OMS CIA 2024 et CDC Antibiotic Resistance Threats

    Méthodologie:
    - Score basé sur la classe d'antibiotique (OMS/CDC)
    - Bonus pour gènes critiques spécifiques
    - Bonus pour qualité de détection (coverage/identity)
    """

    # Utiliser TOUS les champs disponibles pour une détection maximale
    class_name = (gene_data.get('class', '') or '').lower()
    resistance = (gene_data.get('resistance', '') or '').lower()
    subclass = (gene_data.get('subclass', '') or '').lower()
    gene_name = (gene_data.get('gene', '') or '').lower()
    product = (gene_data.get('product', '') or '').lower()
    coverage = float(gene_data.get('coverage', 0) or 0)
    identity = float(gene_data.get('identity', 0) or 0)

    combined = f"{class_name} {resistance} {subclass} {gene_name} {product}"

    # === Classes d'antibiotiques par priorité OMS/CDC ===

    # Dernier recours / Menace urgente CDC (score +4)
    critical_classes = [
        'carbapenem', 'polymyxin', 'colistin', 'glycopeptide', 'vancomycin',
        'oxazolidinone', 'linezolid', 'lipopeptide', 'daptomycin', 'tigecycline'
    ]

    # CIA Priorité 1 / Menace sérieuse CDC (score +3)
    high_classes = [
        'cephalosporin', 'fluoroquinolone', 'quinolone', 'macrolide',
        'aminoglycoside', 'beta-lactam', 'penicillin'
    ]

    # CIA Priorité 2 / Menace préoccupante (score +2)
    medium_classes = [
        'tetracycline', 'phenicol', 'chloramphenicol', 'sulfonamide', 'sulphonamide',
        'trimethoprim', 'rifamycin', 'rifampicin', 'fosfomycin', 'nitroimidazole',
        'nitrofuran', 'fusidic', 'mupirocin', 'streptogramin'
    ]

    # === Gènes critiques spécifiques (bonus +2) ===
    critical_genes = [
        # Carbapénémases
        'ndm', 'kpc', 'vim', 'imp', 'oxa-48', 'oxa-23', 'oxa-24', 'oxa-58', 'oxa-181',
        # Colistine/Polymyxines
        'mcr-1', 'mcr-2', 'mcr-3', 'mcr-4', 'mcr-5', 'mcr-6', 'mcr-7', 'mcr-8', 'mcr-9', 'mcr-10', 'mcr',
        # Glycopeptides (Vancomycine)
        'vana', 'vanb', 'vanc', 'vand', 'vane', 'vancomycin',
        # MRSA
        'meca', 'mecc', 'methicillin', 'mrsa',
        # Linézolide
        'optra', 'cfr', 'poxta',
        # Daptomycine
        'daptomycin'
    ]

    # === Gènes à haute priorité (bonus +1) ===
    high_genes = [
        # ESBL
        'ctx-m', 'ctxm', 'tem', 'shv', 'esbl', 'cmy', 'dha', 'acc',
        # Fluoroquinolones
        'qnra', 'qnrb', 'qnrs', 'qnrd', 'qnr', 'gyra', 'parc', 'aac(6\')-ib-cr',
        # Macrolides
        'erma', 'ermb', 'ermc', 'erm(', 'mefa', 'mef(', 'mph(',
        # Aminosides
        'aac(', 'aph(', 'ant(', 'arma', 'rmta', 'rmtb', 'rmtc', 'npma'
    ]

    # === Calcul du score de gravité ===
    severity_score = 0

    # 1. Score basé sur la classe d'antibiotique
    class_found = False
    for keyword in critical_classes:
        if keyword in combined:
            severity_score += 4
            class_found = True
            break

    if not class_found:
        for keyword in high_classes:
            if keyword in combined:
                severity_score += 3
                class_found = True
                break

    if not class_found:
        for keyword in medium_classes:
            if keyword in combined:
                severity_score += 2
                class_found = True
                break

    if not class_found:
        severity_score = 1  # Classe inconnue

    # 2. Bonus pour gènes critiques spécifiques
    for crit_gene in critical_genes:
        if crit_gene in gene_name or crit_gene in product:
            severity_score += 2
            break

    # 3. Bonus pour gènes à haute priorité spécifiques
    if severity_score < 5:
        for high_gene in high_genes:
            if high_gene in gene_name or high_gene in product:
                severity_score += 1
                break

    # 4. Bonus pour qualité de détection
    if coverage >= 95 and identity >= 95:
        severity_score += 1  # Détection très confiante

    # === Classification finale ===
    if severity_score >= 5:
        return 'CRITICAL', 'FF4444'  # Rouge
    elif severity_score >= 3:
        return 'HIGH', 'FF9933'       # Orange
    else:
        return 'MEDIUM', '4499FF'     # Bleu

def parse_amrfinder(tsv_file):
    """Parse fichier AMRFinder+ (avec support virulence et stress via --plus)"""
    genes = []
    try:
        with open(tsv_file, 'r') as f:
            lines = f.readlines()
            if len(lines) <= 1:
                return genes

            header = lines[0].strip().split('\t')
            for line in lines[1:]:
                if not line.strip():
                    continue
                fields = line.strip().split('\t')
                if len(fields) >= 17:
                    gene_symbol = fields[5] if len(fields) > 5 else "Unknown"
                    element_type = fields[8] if len(fields) > 8 else 'AMR'  # AMR, VIRULENCE, STRESS
                    element_subtype = fields[9] if len(fields) > 9 else ''

                    gene_data = {
                        'source': 'AMRFinder+',
                        'gene': gene_symbol,
                        'gene_description': fields[6] if len(fields) > 6 else '',
                        'element_type': element_type,  # AMR, VIRULENCE, STRESS
                        'element_subtype': element_subtype,
                        'class': fields[10] if len(fields) > 10 else '',
                        'subclass': fields[11] if len(fields) > 11 else '',
                        'coverage': 100,  # AMRFinder+ ne donne pas coverage directement
                        'identity': float(fields[16]) if len(fields) > 16 and fields[16] else 100,
                        'contig': fields[1],
                        'method': fields[12] if len(fields) > 12 else '',
                        'resistance': fields[11] if len(fields) > 11 else ''
                    }
                    genes.append(gene_data)
    except Exception as e:
        print(f"Erreur lors du parsing AMRFinder+: {e}", file=sys.stderr)

    return genes


def parse_vfdb(tsv_file):
    """Parse fichier VFDB (Virulence Factor Database) depuis ABRicate"""
    genes = []
    try:
        with open(tsv_file, 'r') as f:
            lines = f.readlines()
            data_started = False
            for line in lines:
                if line.startswith('#FILE'):
                    data_started = True
                    continue
                if not data_started or not line.strip():
                    continue

                fields = line.strip().split('\t')
                if len(fields) >= 14:
                    gene_data = {
                        'source': 'VFDB',
                        'gene': fields[5],
                        'element_type': 'VIRULENCE',
                        'coverage': float(fields[9]) if fields[9] else 100,
                        'identity': float(fields[10]) if fields[10] else 100,
                        'contig': fields[1],
                        'product': fields[13] if len(fields) > 13 else '',
                        'resistance': fields[13] if len(fields) > 13 else '',  # Utiliser product comme description
                        'class': 'VIRULENCE',
                        'subclass': fields[13] if len(fields) > 13 else ''
                    }
                    genes.append(gene_data)
    except Exception as e:
        print(f"Erreur lors du parsing VFDB: {e}", file=sys.stderr)

    return genes


def parse_card_abricate(tsv_file):
    """Parse fichier CARD depuis ABRicate (différent de RGI)"""
    genes = []
    try:
        with open(tsv_file, 'r') as f:
            lines = f.readlines()
            data_started = False
            for line in lines:
                if line.startswith('#FILE'):
                    data_started = True
                    continue
                if not data_started or not line.strip():
                    continue

                fields = line.strip().split('\t')
                if len(fields) >= 14:
                    gene_data = {
                        'source': 'CARD',
                        'gene': fields[5],
                        'element_type': 'AMR',
                        'coverage': float(fields[9]) if fields[9] else 100,
                        'identity': float(fields[10]) if fields[10] else 100,
                        'contig': fields[1],
                        'product': fields[13] if len(fields) > 13 else '',
                        'resistance': fields[14] if len(fields) > 14 else '',
                        'class': fields[14] if len(fields) > 14 else '',
                        'subclass': ''
                    }
                    genes.append(gene_data)
    except Exception as e:
        print(f"Erreur lors du parsing CARD (abricate): {e}", file=sys.stderr)

    return genes


def parse_ncbi_abricate(tsv_file):
    """Parse fichier NCBI AMR depuis ABRicate"""
    genes = []
    try:
        with open(tsv_file, 'r') as f:
            lines = f.readlines()
            data_started = False
            for line in lines:
                if line.startswith('#FILE'):
                    data_started = True
                    continue
                if not data_started or not line.strip():
                    continue

                fields = line.strip().split('\t')
                if len(fields) >= 14:
                    gene_data = {
                        'source': 'NCBI',
                        'gene': fields[5],
                        'element_type': 'AMR',
                        'coverage': float(fields[9]) if fields[9] else 100,
                        'identity': float(fields[10]) if fields[10] else 100,
                        'contig': fields[1],
                        'product': fields[13] if len(fields) > 13 else '',
                        'resistance': fields[14] if len(fields) > 14 else '',
                        'class': fields[14] if len(fields) > 14 else '',
                        'subclass': ''
                    }
                    genes.append(gene_data)
    except Exception as e:
        print(f"Erreur lors du parsing NCBI (abricate): {e}", file=sys.stderr)

    return genes

def parse_resfinder(tsv_file):
    """Parse fichier ResFinder"""
    genes = []
    try:
        with open(tsv_file, 'r') as f:
            lines = f.readlines()
            # Skip les premières lignes de texte
            data_started = False
            for line in lines:
                if line.startswith('#FILE'):
                    data_started = True
                    continue
                if not data_started or not line.strip():
                    continue

                fields = line.strip().split('\t')
                if len(fields) >= 14:
                    gene_data = {
                        'source': 'ResFinder',
                        'gene': fields[5],
                        'coverage': float(fields[9]),
                        'identity': float(fields[10]),
                        'contig': fields[1],
                        'product': fields[12],
                        'resistance': fields[13] if len(fields) > 13 else ''
                    }
                    # Classifier par défaut (sera mis à jour avec AMRFinder+)
                    gene_data['class'] = ''
                    gene_data['subclass'] = ''
                    genes.append(gene_data)
    except Exception as e:
        print(f"Erreur lors du parsing ResFinder: {e}", file=sys.stderr)

    return genes

def parse_rgi(rgi_file):
    """Parse fichier RGI (Resistance Gene Identifier)"""
    genes = []
    try:
        with open(rgi_file, 'r') as f:
            lines = f.readlines()
            if len(lines) <= 1:
                return genes

            header = lines[0].strip().split('\t')
            for line in lines[1:]:
                if not line.strip():
                    continue
                fields = line.strip().split('\t')
                if len(fields) >= 10:
                    # RGI columns: ORF_ID, Contig, Start, Stop, Orientation, Cut_Off, Pass_Bitscore, Best_Hit_Bitscore, Best_Hit_ARO, Best_Identities, ARO, Model_type, SNPs_in_Best_Hit_ARO, Other_SNPs, Drug Class, Resistance Mechanism, AMR Gene Family, Percentage Length of Reference Sequence, ID, Model_ID
                    gene_data = {
                        'source': 'RGI/CARD',
                        'gene': fields[8] if len(fields) > 8 else fields[0],  # Best_Hit_ARO ou ORF_ID
                        'contig': fields[1] if len(fields) > 1 else '',
                        'identity': float(fields[9].replace('%', '')) if len(fields) > 9 and fields[9] else 100,
                        'coverage': float(fields[17]) if len(fields) > 17 and fields[17] else 100,  # Percentage Length
                        'class': fields[14] if len(fields) > 14 else '',  # Drug Class
                        'subclass': fields[16] if len(fields) > 16 else '',  # AMR Gene Family
                        'resistance': fields[14] if len(fields) > 14 else '',  # Drug Class
                        'mechanism': fields[15] if len(fields) > 15 else '',  # Resistance Mechanism
                        'model_type': fields[11] if len(fields) > 11 else '',  # Model_type (protein homolog, variant, etc.)
                        'cut_off': fields[5] if len(fields) > 5 else ''  # Perfect/Strict/Loose
                    }
                    genes.append(gene_data)
    except Exception as e:
        print(f"Erreur lors du parsing RGI: {e}", file=sys.stderr)

    return genes

def parse_pointfinder(pointfinder_dir):
    """Parse résultats PointFinder"""
    mutations = []
    try:
        # Chercher le fichier de résultats PointFinder
        import os
        for filename in os.listdir(pointfinder_dir):
            if 'pointfinder' in filename.lower() and filename.endswith('.txt'):
                filepath = os.path.join(pointfinder_dir, filename)
                with open(filepath, 'r') as f:
                    lines = f.readlines()
                    for line in lines[1:]:  # Skip header
                        if not line.strip() or line.startswith('#'):
                            continue
                        fields = line.strip().split('\t')
                        if len(fields) >= 4:
                            mutation_data = {
                                'source': 'PointFinder',
                                'gene': fields[0] if fields else '',
                                'mutation': fields[1] if len(fields) > 1 else '',
                                'resistance': fields[3] if len(fields) > 3 else '',
                                'identity': 100,
                                'coverage': 100,
                                'class': 'CHROMOSOMAL_MUTATION',
                                'subclass': fields[3] if len(fields) > 3 else ''
                            }
                            mutations.append(mutation_data)
    except Exception as e:
        print(f"Erreur lors du parsing PointFinder: {e}", file=sys.stderr)

    return mutations

def generate_html_report(amr_genes, sample_id, output_file, detected_species=None, quality_metrics=None, mlst_data=None, rgi_genes=None, pointfinder_mutations=None):
    """Génère le rapport HTML"""

    # Classification (utiliser existante si déjà classifié)
    classified_genes = []
    gravity_counts = defaultdict(int)
    type_counts = defaultdict(int)  # Compteur par type (Acquis vs Mutation)
    element_counts = defaultdict(int)  # Compteur par élément (AMR vs VIRULENCE vs STRESS)
    antibiotics_set = set()
    source_counts = defaultdict(int)  # Compteur par source

    for gene in amr_genes:
        # Vérifier si déjà classifié (gravité)
        if 'gravity' not in gene or 'color' not in gene:
            gravity, color = classify_gravity(gene)
            gene['gravity'] = gravity
            gene['color'] = color

        # Classifier le type de résistance (Acquis vs Mutation)
        if 'resistance_type' not in gene:
            type_label, type_code, type_color = classify_resistance_type(gene)
            gene['resistance_type'] = type_label
            gene['resistance_type_code'] = type_code
            gene['resistance_type_color'] = type_color

        gravity_counts[gene['gravity']] += 1
        type_counts[gene['resistance_type_code']] += 1
        element_counts[gene.get('element_type', 'AMR')] += 1
        source_counts[gene.get('source', 'Unknown')] += 1
        classified_genes.append(gene)

        # Extraire antibiotiques
        if 'resistance' in gene and gene['resistance']:
            for ab in gene['resistance'].split(';'):
                antibiotics_set.add(ab.strip())

    # Générer deux tableaux : tous les gènes et AMR uniquement
    table_rows_all = ""
    table_rows_amr = ""

    for gene in sorted(classified_genes, key=lambda x: ('CRITICAL', 'HIGH', 'MEDIUM').index(x['gravity'])):
        gravity = gene['gravity']
        color = gene['color']
        resistance_type = gene.get('resistance_type', 'Inconnu')
        resistance_type_color = gene.get('resistance_type_color', '757575')
        element_type = gene.get('element_type', 'AMR')
        resistance = gene.get('resistance', gene.get('product', ''))
        coverage = gene.get('coverage', 100)
        identity = gene.get('identity', 100)

        # Icône et couleur selon le type d'élément (AMR/VIRULENCE/STRESS)
        if element_type == 'VIRULENCE':
            element_icon = "🦠"
            element_color = "E91E63"  # Rose
            element_label = "Virulence"
        elif element_type == 'STRESS':
            element_icon = "⚡"
            element_color = "FF5722"  # Orange foncé
            element_label = "Stress"
        else:
            element_icon = "💊"
            element_color = "4CAF50"  # Vert
            element_label = "AMR"

        # Icône selon le type de résistance (Acquis/Mutation)
        type_icon = "🧬" if resistance_type == "Acquis" else ("🔬" if resistance_type == "Mutation" else "❓")

        row_html = f"""
        <tr>
            <td><strong>{gene['gene']}</strong></td>
            <td>{gene.get('source', 'Unknown')}</td>
            <td><span class="badge" style="background:#{element_color};">{element_icon} {element_label}</span></td>
            <td><span class="badge" style="background:#{resistance_type_color};">{type_icon} {resistance_type}</span></td>
            <td><span class="badge" style="background:#{color};">{gravity}</span></td>
            <td>{resistance}</td>
            <td>{coverage:.1f}%</td>
            <td>{identity:.1f}%</td>
        </tr>
        """

        # Ajouter à tous les gènes
        table_rows_all += row_html

        # Ajouter au tableau AMR uniquement si c'est un gène AMR
        if element_type == 'AMR':
            table_rows_amr += row_html

    # Compte des gènes
    total_genes = len(classified_genes)
    critical = gravity_counts.get('CRITICAL', 0)
    high = gravity_counts.get('HIGH', 0)
    medium = gravity_counts.get('MEDIUM', 0)

    # Compte par type (Acquis/Mutation)
    acquired_count = type_counts.get('ACQUIRED', 0)
    mutation_count = type_counts.get('MUTATION', 0)
    expression_count = type_counts.get('EXPRESSION', 0)
    unknown_count = type_counts.get('UNKNOWN', 0)

    # Compte par élément (AMR/VIRULENCE/STRESS)
    amr_element_count = element_counts.get('AMR', 0)
    virulence_count = element_counts.get('VIRULENCE', 0)
    stress_element_count = element_counts.get('STRESS', 0)
    
    # Message si aucun gène trouvé
    no_genes_message = ""
    if total_genes == 0:
        no_genes_message = """
            <div class="recommendations" style="background: #e3f2fd; border-left: 4px solid #2196F3; margin-top: 20px;">
                <h3 style="color: #1976D2; margin-bottom: 10px;">ℹ️ Information</h3>
                <p style="color: #333; line-height: 1.6;">
                    Aucun gène de résistance aux antibiotiques (ARG) n'a été détecté dans cet échantillon.
                    Cela peut indiquer soit l'absence de gènes ARG, soit la nécessité d'utiliser des bases de données supplémentaires.
                </p>
            </div>
        """

    # HTML complet
    html = f"""
    <!DOCTYPE html>
    <html lang="fr">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
        <meta http-equiv="Pragma" content="no-cache">
        <meta http-equiv="Expires" content="0">
        <title>Rapport ARG - {sample_id}</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
        <style>
            * {{ margin: 0; padding: 0; box-sizing: border-box; }}
            body {{
                font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                padding: 20px;
                min-height: 100vh;
            }}
            .container {{
                max-width: 1600px;
                margin: 0 auto;
                background: white;
                border-radius: 15px;
                box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                overflow: hidden;
            }}
            .header {{
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 40px;
                text-align: center;
            }}
            .header h1 {{ font-size: 2.5em; margin-bottom: 10px; }}
            .header p {{ font-size: 1.1em; opacity: 0.9; }}
            .metadata {{
                display: grid;
                grid-template-columns: 1fr 1fr 1fr;
                gap: 20px;
                padding: 20px;
                background: #f8f9fa;
                border-bottom: 1px solid #ddd;
            }}
            .meta-item {{
                display: flex;
                flex-direction: column;
            }}
            .meta-label {{
                font-size: 0.9em;
                color: #666;
                font-weight: 600;
                text-transform: uppercase;
                margin-bottom: 5px;
            }}
            .meta-value {{
                font-size: 1.1em;
                color: #333;
                font-weight: 500;
            }}
            .content {{ padding: 40px; }}

            .stats-grid {{
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                gap: 20px;
                margin-bottom: 40px;
            }}
            .stat-card {{
                background: white;
                border: 2px solid #ddd;
                border-radius: 10px;
                padding: 20px;
                text-align: center;
                transition: transform 0.3s;
            }}
            .stat-card:hover {{ transform: translateY(-5px); }}
            .stat-card.total {{ border-color: #667eea; }}
            .stat-card.critical {{ border-color: #FF4444; }}
            .stat-card.high {{ border-color: #FF9933; }}
            .stat-card.medium {{ border-color: #4499FF; }}

            .stat-value {{
                font-size: 2em;
                font-weight: bold;
                margin: 10px 0;
            }}
            .stat-card.total .stat-value {{ color: #667eea; }}
            .stat-card.critical .stat-value {{ color: #FF4444; }}
            .stat-card.high .stat-value {{ color: #FF9933; }}
            .stat-card.medium .stat-value {{ color: #4499FF; }}

            .stat-label {{
                font-size: 0.9em;
                color: #666;
                text-transform: uppercase;
                font-weight: 600;
            }}

            .charts-grid {{
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 30px;
                margin-bottom: 40px;
            }}
            .chart-container {{
                background: white;
                border-radius: 10px;
                padding: 20px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            }}
            .chart-container h3 {{
                margin-bottom: 20px;
                color: #333;
                font-size: 1.2em;
            }}
            .chart-box {{
                position: relative;
                height: 300px;
            }}

            .table-wrapper {{
                overflow-x: auto;
                max-width: 100%;
            }}
            table {{
                width: 100%;
                border-collapse: collapse;
                margin-top: 20px;
                table-layout: fixed;
            }}
            th {{
                background: #667eea;
                color: white;
                padding: 12px;
                text-align: left;
                font-weight: 600;
            }}
            td {{
                padding: 10px 8px;
                border-bottom: 1px solid #ddd;
                word-wrap: break-word;
                overflow-wrap: break-word;
                white-space: normal;
                vertical-align: middle;
            }}
            /* Colonnes proportionnelles */
            th:nth-child(1), td:nth-child(1) {{ width: 10%; }}
            th:nth-child(2), td:nth-child(2) {{ width: 10%; }}
            th:nth-child(3), td:nth-child(3) {{ width: 10%; }}
            th:nth-child(4), td:nth-child(4) {{ width: 10%; }}
            th:nth-child(5), td:nth-child(5) {{ width: 10%; }}
            th:nth-child(6), td:nth-child(6) {{ width: 35%; }}
            th:nth-child(7), td:nth-child(7) {{ width: 8%; }}
            th:nth-child(8), td:nth-child(8) {{ width: 7%; }}
            tr:hover {{ background: #f8f9fa; }}

            .badge {{
                color: white;
                padding: 4px 8px;
                border-radius: 4px;
                font-weight: bold;
                font-size: 0.8em;
                display: inline-block;
                white-space: nowrap;
            }}

            /* Système d'onglets */
            .tabs {{
                display: flex;
                border-bottom: 2px solid #667eea;
                margin-bottom: 0;
            }}
            .tab-btn {{
                padding: 12px 24px;
                border: none;
                background: #f0f0f0;
                cursor: pointer;
                font-size: 1em;
                font-weight: 600;
                color: #666;
                border-radius: 8px 8px 0 0;
                margin-right: 4px;
                transition: all 0.3s;
            }}
            .tab-btn:hover {{
                background: #e0e0e0;
            }}
            .tab-btn.active {{
                background: #667eea;
                color: white;
            }}
            .tab-content {{
                display: none;
                padding: 20px 0;
            }}
            .tab-content.active {{
                display: block;
            }}
            .tab-count {{
                background: rgba(255,255,255,0.3);
                padding: 2px 8px;
                border-radius: 10px;
                font-size: 0.85em;
                margin-left: 8px;
            }}
            .tab-btn.active .tab-count {{
                background: rgba(255,255,255,0.3);
            }}
            .tab-btn:not(.active) .tab-count {{
                background: #ddd;
            }}

            .recommendations {{
                background: #fffacd;
                border-left: 4px solid #FF9933;
                padding: 20px;
                margin-top: 30px;
                border-radius: 5px;
            }}
            .recommendations h3 {{
                color: #FF9933;
                margin-bottom: 10px;
            }}
            .recommendations ul {{
                margin-left: 20px;
            }}
            .recommendations li {{
                margin: 8px 0;
                color: #333;
                line-height: 1.6;
            }}

            .footer {{
                background: #f8f9fa;
                padding: 20px;
                text-align: center;
                color: #666;
                font-size: 0.9em;
                border-top: 1px solid #ddd;
            }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>🧬 Rapport ARG - Détection des Gènes de Résistance</h1>
                <p>Pipeline d'analyse des gènes de résistance aux antibiotiques (ARG)</p>
            </div>

            <div class="metadata">
                <div class="meta-item">
                    <span class="meta-label">Échantillon</span>
                    <span class="meta-value">{sample_id}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Date d'analyse</span>
                    <span class="meta-value">{datetime.now().strftime('%d/%m/%Y %H:%M')}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Total gènes ARG</span>
                    <span class="meta-value">{total_genes}</span>
                </div>
            </div>
            {f'''
            <div class="metadata" style="background: #e8f5e9; border-top: 2px solid #4caf50;">
                <div class="meta-item" style="grid-column: 1 / -1; text-align: center;">
                    <span class="meta-label" style="font-size: 1em; color: #2e7d32;">🦠 Espèce bactérienne détectée (NCBI)</span>
                    <span class="meta-value" style="font-size: 1.3em; color: #1b5e20; font-weight: bold; margin-top: 5px;">{detected_species}</span>
                </div>
            </div>
            ''' if detected_species else ''}
            {f'''
            <div class="metadata" style="background: #e3f2fd; border-top: 2px solid #2196f3; margin-top: 10px;">
                <div class="meta-item" style="text-align: center;">
                    <span class="meta-label" style="font-size: 0.9em; color: #1565c0;">🧬 Schéma MLST</span>
                    <span class="meta-value" style="font-size: 1.1em; color: #0d47a1; font-weight: bold;">{mlst_data["scheme"]}</span>
                </div>
                <div class="meta-item" style="text-align: center;">
                    <span class="meta-label" style="font-size: 0.9em; color: #1565c0;">📍 Sequence Type</span>
                    <span class="meta-value" style="font-size: 1.4em; color: #0d47a1; font-weight: bold;">ST{mlst_data["st"]}</span>
                </div>
                <div class="meta-item" style="text-align: center;">
                    <span class="meta-label" style="font-size: 0.9em; color: #1565c0;">🔗 Profil allélique</span>
                    <span class="meta-value" style="font-size: 0.9em; color: #1976d2; font-family: monospace;">{mlst_data["alleles"]}</span>
                </div>
            </div>
            ''' if mlst_data else ''}

            <div class="content">
                <!-- STATISTIQUES PAR GRAVITÉ -->
                <h2 style="margin-bottom:20px; color:#333;">📊 Résumé des Découvertes</h2>
                <div class="stats-grid">
                    <div class="stat-card total">
                        <div class="stat-label">Total ARG</div>
                        <div class="stat-value">{total_genes}</div>
                    </div>
                    <div class="stat-card critical">
                        <div class="stat-label">Critique</div>
                        <div class="stat-value">{critical}</div>
                    </div>
                    <div class="stat-card high">
                        <div class="stat-label">Élevé</div>
                        <div class="stat-value">{high}</div>
                    </div>
                    <div class="stat-card medium">
                        <div class="stat-label">Moyen</div>
                        <div class="stat-value">{medium}</div>
                    </div>
                </div>

                <!-- STATISTIQUES PAR ÉLÉMENT (AMR/VIRULENCE/STRESS) -->
                <h2 style="margin-top:30px; margin-bottom:20px; color:#333;">🔬 Catégorie d'Éléments</h2>
                <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-bottom: 30px;">
                    <div class="stat-card" style="border-color: #4CAF50;">
                        <div class="stat-label">💊 AMR</div>
                        <div class="stat-value" style="color: #4CAF50;">{amr_element_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Résistance aux antibiotiques</div>
                    </div>
                    <div class="stat-card" style="border-color: #E91E63;">
                        <div class="stat-label">🦠 Virulence</div>
                        <div class="stat-value" style="color: #E91E63;">{virulence_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Facteurs de pathogénicité</div>
                    </div>
                    <div class="stat-card" style="border-color: #FF5722;">
                        <div class="stat-label">⚡ Stress</div>
                        <div class="stat-value" style="color: #FF5722;">{stress_element_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Résistance métaux/biocides</div>
                    </div>
                </div>

                <!-- STATISTIQUES PAR TYPE (ACQUIS VS MUTATION) -->
                <h2 style="margin-top:30px; margin-bottom:20px; color:#333;">🧬 Mécanisme de Résistance</h2>
                <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; margin-bottom: 30px;">
                    <div class="stat-card" style="border-color: #2196F3;">
                        <div class="stat-label">🧬 Acquis</div>
                        <div class="stat-value" style="color: #2196F3;">{acquired_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Gènes mobiles</div>
                    </div>
                    <div class="stat-card" style="border-color: #9C27B0;">
                        <div class="stat-label">🔬 Mutation</div>
                        <div class="stat-value" style="color: #9C27B0;">{mutation_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Mutations chromosomiques</div>
                    </div>
                    <div class="stat-card" style="border-color: #FF9800;">
                        <div class="stat-label">📈 Expression</div>
                        <div class="stat-value" style="color: #FF9800;">{expression_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Surexpression/Knockout</div>
                    </div>
                    <div class="stat-card" style="border-color: #757575;">
                        <div class="stat-label">❓ Inconnu</div>
                        <div class="stat-value" style="color: #757575;">{unknown_count}</div>
                        <div style="font-size: 0.8em; color: #666; margin-top: 5px;">Non classifié</div>
                    </div>
                </div>

                <!-- GRAPHIQUES -->
                <div class="charts-grid">
                    <div class="chart-container">
                        <h3>Catégorie d'Éléments (AMR/Virulence/Stress)</h3>
                        <div class="chart-box">
                            <canvas id="elementChart"></canvas>
                        </div>
                    </div>
                    <div class="chart-container">
                        <h3>Mécanisme (Acquis/Mutation/Inconnu)</h3>
                        <div class="chart-box">
                            <canvas id="typeChart"></canvas>
                        </div>
                    </div>
                </div>

                <!-- TABLEAU DÉTAILLÉ AVEC ONGLETS -->
                <h2 style="margin-top:40px; margin-bottom:20px; color:#333;">🔬 Gènes Détectés</h2>

                {f'''
                <div class="tabs">
                    <button class="tab-btn active" onclick="showTab('all')">
                        📋 Tous les gènes <span class="tab-count">{total_genes}</span>
                    </button>
                    <button class="tab-btn" onclick="showTab('amr')">
                        💊 AMR uniquement <span class="tab-count">{amr_element_count}</span>
                    </button>
                </div>

                <!-- Onglet: Tous les gènes -->
                <div id="tab-all" class="tab-content active">
                    <div class="table-wrapper">
                    <table>
                        <thead>
                            <tr>
                                <th>Gène</th>
                                <th>Source</th>
                                <th>Élément</th>
                                <th>Mécanisme</th>
                                <th>Gravité</th>
                                <th>Description</th>
                                <th>Coverage</th>
                                <th>Identité</th>
                            </tr>
                        </thead>
                        <tbody>
                            {table_rows_all}
                        </tbody>
                    </table>
                    </div>
                </div>

                <!-- Onglet: AMR uniquement -->
                <div id="tab-amr" class="tab-content">
                    <div class="table-wrapper">
                    <table>
                        <thead>
                            <tr>
                                <th>Gène</th>
                                <th>Source</th>
                                <th>Élément</th>
                                <th>Mécanisme</th>
                                <th>Gravité</th>
                                <th>Description</th>
                                <th>Coverage</th>
                                <th>Identité</th>
                            </tr>
                        </thead>
                        <tbody>
                            {table_rows_amr if table_rows_amr else '<tr><td colspan="8" style="text-align:center; padding:20px; color:#666;">Aucun gène AMR détecté</td></tr>'}
                        </tbody>
                    </table>
                    </div>
                </div>
                ''' if table_rows_all else ''}
                {no_genes_message}

                <!-- MÉTRIQUES DE QUALITÉ -->
                {f'''
                <div class="recommendations" style="background: #e8f5e9; border-left: 4px solid #4caf50; margin-top: 20px;">
                    <h3 style="color: #2e7d32; margin-bottom: 10px;">📊 Métriques de Qualité</h3>
                    <p style="color: #333; line-height: 1.6;">
                        <strong>Gènes haute confiance (identity ≥95%):</strong> {quality_metrics['summary']['high_confidence_genes']} ({quality_metrics['confidence_distribution']['high_confidence_pct']:.1f}%)<br>
                        <strong>Gènes confiance moyenne (90-95%):</strong> {quality_metrics['summary']['medium_confidence_genes']} ({quality_metrics['confidence_distribution']['medium_confidence_pct']:.1f}%)<br>
                        <strong>Gènes CRITICAL détectés:</strong> {quality_metrics['summary']['total_critical_genes']}
                    </p>
                </div>
                ''' if quality_metrics else ''}

                <!-- EXPLICATION ACQUIS VS MUTATION -->
                <div class="recommendations" style="background: #e8eaf6; border-left: 4px solid #3f51b5; margin-top: 20px;">
                    <h3 style="color: #3f51b5; margin-bottom: 15px;">📚 Comprendre les Types de Résistance</h3>
                    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
                        <div>
                            <h4 style="color: #2196F3; margin-bottom: 8px;">🧬 Gènes Acquis (Mobiles)</h4>
                            <ul style="margin-left: 20px; color: #333; line-height: 1.6;">
                                <li>Portés par des <strong>éléments mobiles</strong> (plasmides, transposons, intégrons)</li>
                                <li><strong>Transférables</strong> entre bactéries par conjugaison/transformation</li>
                                <li><strong>Risque épidémiologique élevé</strong> - propagation horizontale</li>
                                <li>Exemples: gènes bla (β-lactamases), tet (tétracycline), erm (macrolides)</li>
                            </ul>
                        </div>
                        <div>
                            <h4 style="color: #9C27B0; margin-bottom: 8px;">🔬 Mutations Chromosomiques</h4>
                            <ul style="margin-left: 20px; color: #333; line-height: 1.6;">
                                <li>Modifications dans les <strong>gènes chromosomiques</strong> existants</li>
                                <li><strong>Non transférables</strong> (transmission verticale uniquement)</li>
                                <li><strong>Risque épidémiologique modéré</strong> - pas de propagation horizontale</li>
                                <li>Exemples: mutations gyrA/gyrB (fluoroquinolones), rpoB (rifampicine)</li>
                            </ul>
                        </div>
                    </div>
                </div>

                <!-- RECOMMANDATIONS -->
                <div class="recommendations">
                    <h3>⚠️ Recommandations Cliniques</h3>
                    <ul>
                        <li><strong>Tests de sensibilité:</strong> Effectuer des antibiogrammes pour confirmer les profils de résistance détectés.</li>
                        <li><strong>Surveillance:</strong> Suivi épidémiologique recommandé pour les gènes CRITICAL et HIGH.</li>
                        <li><strong>Infection contrôle:</strong> Mesures d'isolation appropriées basées sur le profil de résistance.</li>
                        <li><strong>Gènes acquis:</strong> Attention particulière aux souches avec gènes mobiles - risque de dissémination accru.</li>
                        <li><strong>Traitement:</strong> Consultation avec un microbiologiste/infectiologue pour optimiser la thérapie.</li>
                    </ul>
                </div>
            </div>

            <div class="footer">
                <p>Rapport généré automatiquement - Pipeline ARG v3.1</p>
                <p>⚠️ Ce rapport est fourni à titre informatif. Les résultats doivent être confirmés par des tests de sensibilité conventionnels.</p>
            </div>
        </div>

        <script>
            // Données pour les graphiques
            const elementData = {{
                labels: ['AMR (Antibiotiques)', 'Virulence', 'Stress'],
                datasets: [{{
                    data: [{amr_element_count}, {virulence_count}, {stress_element_count}],
                    backgroundColor: ['#4CAF50', '#E91E63', '#FF5722'],
                    borderColor: ['#388E3C', '#C2185B', '#E64A19'],
                    borderWidth: 2
                }}]
            }};

            const typeData = {{
                labels: ['Acquis (Mobile)', 'Mutation', 'Expression', 'Inconnu'],
                datasets: [{{
                    data: [{acquired_count}, {mutation_count}, {expression_count}, {unknown_count}],
                    backgroundColor: ['#2196F3', '#9C27B0', '#FF9800', '#757575'],
                    borderColor: ['#1565C0', '#7B1FA2', '#F57C00', '#616161'],
                    borderWidth: 2
                }}]
            }};

            // Graphique Élément (AMR/Virulence/Stress)
            new Chart(document.getElementById('elementChart'), {{
                type: 'doughnut',
                data: elementData,
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {{
                        legend: {{ position: 'bottom' }},
                        title: {{
                            display: true,
                            text: 'Catégorie fonctionnelle des gènes',
                            font: {{ size: 11 }},
                            color: '#666'
                        }}
                    }}
                }}
            }});

            // Graphique Mécanisme (Acquis vs Mutation vs Inconnu)
            new Chart(document.getElementById('typeChart'), {{
                type: 'doughnut',
                data: typeData,
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {{
                        legend: {{ position: 'bottom' }},
                        title: {{
                            display: true,
                            text: 'Mode d\\'acquisition de la résistance',
                            font: {{ size: 11 }},
                            color: '#666'
                        }}
                    }}
                }}
            }});

            // Fonction pour changer d'onglet
            function showTab(tabName) {{
                // Masquer tous les contenus d'onglets
                document.querySelectorAll('.tab-content').forEach(tab => {{
                    tab.classList.remove('active');
                }});

                // Désactiver tous les boutons
                document.querySelectorAll('.tab-btn').forEach(btn => {{
                    btn.classList.remove('active');
                }});

                // Afficher l'onglet sélectionné
                document.getElementById('tab-' + tabName).classList.add('active');

                // Activer le bouton correspondant
                event.target.closest('.tab-btn').classList.add('active');
            }}
        </script>
    </body>
    </html>
    """

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"✅ Rapport généré: {output_file}")
    return output_file

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate_arg_report.py <results_dir> [sample_id]")
        sys.exit(1)

    results_dir = sys.argv[1]
    sample_id = sys.argv[2] if len(sys.argv) > 2 else "Unknown"

    # Chemins des fichiers
    amrfinder_file = os.path.join(results_dir, "04_arg_detection", "amrfinderplus", f"{sample_id}_amrfinderplus.tsv")
    resfinder_file = os.path.join(results_dir, "04_arg_detection", "resfinder", f"{sample_id}_resfinder.tsv")
    rgi_file = os.path.join(results_dir, "04_arg_detection", "rgi", f"{sample_id}_rgi.txt")
    card_file = os.path.join(results_dir, "04_arg_detection", "card", f"{sample_id}_card.tsv")  # CARD via abricate
    ncbi_file = os.path.join(results_dir, "04_arg_detection", "ncbi", f"{sample_id}_ncbi.tsv")  # NCBI via abricate
    vfdb_file = os.path.join(results_dir, "04_arg_detection", "vfdb", f"{sample_id}_vfdb.tsv")
    pointfinder_dir = os.path.join(results_dir, "04_arg_detection", "pointfinder")
    output_file = os.path.join(results_dir, "06_analysis", "reports", f"{sample_id}_ARG_professional_report.html")

    # Créer répertoire si nécessaire
    os.makedirs(os.path.dirname(output_file), exist_ok=True)

    # Parser les fichiers
    print("📊 Parsing des données ARG...")
    amr_genes = []
    rgi_genes = []
    pointfinder_mutations = []

    if os.path.exists(amrfinder_file):
        amr_genes.extend(parse_amrfinder(amrfinder_file))
        print(f"  ✓ {len([g for g in amr_genes if g['source'] == 'AMRFinder+'])} gènes AMRFinder+ trouvés")

    if os.path.exists(resfinder_file):
        resfinder_genes = parse_resfinder(resfinder_file)
        # Merge avec AMRFinder+ si possible
        for rf_gene in resfinder_genes:
            # Chercher match avec AMRFinder+
            amr_match = next((g for g in amr_genes if g['gene'].split('_')[0] == rf_gene['gene'].split('_')[0]), None)
            if amr_match:
                amr_match.update({k: v for k, v in rf_gene.items() if k not in amr_match})
            else:
                amr_genes.append(rf_gene)
        print(f"  ✓ {len(resfinder_genes)} gènes ResFinder trouvés")

    # Parser RGI/CARD (outil standalone)
    if os.path.exists(rgi_file):
        rgi_genes = parse_rgi(rgi_file)
        if rgi_genes:
            print(f"  ✓ {len(rgi_genes)} gènes RGI/CARD trouvés")
            # Ajouter les gènes RGI uniques (non détectés par AMRFinder+)
            for rgi_gene in rgi_genes:
                gene_name = rgi_gene['gene'].split()[0]  # Prendre le premier mot
                if not any(gene_name.lower() in g['gene'].lower() for g in amr_genes):
                    amr_genes.append(rgi_gene)

    # Parser CARD via abricate (complément ou remplacement de RGI)
    if os.path.exists(card_file):
        card_genes = parse_card_abricate(card_file)
        if card_genes:
            print(f"  ✓ {len(card_genes)} gènes CARD (abricate) trouvés")
            # Ajouter les gènes CARD uniques
            added = 0
            for card_gene in card_genes:
                gene_name = card_gene['gene'].split('_')[0]
                if not any(gene_name.lower() in g['gene'].lower() for g in amr_genes):
                    amr_genes.append(card_gene)
                    added += 1
            print(f"    → {added} gènes CARD ajoutés (après déduplication)")

    # Parser NCBI AMR via abricate
    if os.path.exists(ncbi_file):
        ncbi_genes = parse_ncbi_abricate(ncbi_file)
        if ncbi_genes:
            print(f"  ✓ {len(ncbi_genes)} gènes NCBI (abricate) trouvés")
            # Ajouter les gènes NCBI uniques
            added = 0
            for ncbi_gene in ncbi_genes:
                gene_name = ncbi_gene['gene'].split('_')[0]
                if not any(gene_name.lower() in g['gene'].lower() for g in amr_genes):
                    amr_genes.append(ncbi_gene)
                    added += 1
            print(f"    → {added} gènes NCBI ajoutés (après déduplication)")

    # Parser PointFinder
    if os.path.exists(pointfinder_dir) and os.path.isdir(pointfinder_dir):
        pointfinder_mutations = parse_pointfinder(pointfinder_dir)
        if pointfinder_mutations:
            print(f"  ✓ {len(pointfinder_mutations)} mutations PointFinder trouvées")
            # Ajouter les mutations comme gènes
            for mutation in pointfinder_mutations:
                mutation['gene'] = f"{mutation['gene']} ({mutation.get('mutation', '')})"
                amr_genes.append(mutation)

    # Parser VFDB (Virulence Factor Database)
    if os.path.exists(vfdb_file):
        vfdb_genes = parse_vfdb(vfdb_file)
        if vfdb_genes:
            print(f"  ✓ {len(vfdb_genes)} facteurs de virulence VFDB trouvés")
            # Ajouter les gènes VFDB uniques
            for vf_gene in vfdb_genes:
                gene_name = vf_gene['gene'].split('_')[0]
                # Vérifier si déjà détecté par AMRFinder+
                if not any(gene_name.lower() in g['gene'].lower() for g in amr_genes):
                    amr_genes.append(vf_gene)

    # Compter les types de gènes
    amr_count = len([g for g in amr_genes if g.get('element_type', 'AMR') == 'AMR'])
    vir_count = len([g for g in amr_genes if g.get('element_type', '') == 'VIRULENCE'])
    stress_count = len([g for g in amr_genes if g.get('element_type', '') == 'STRESS'])
    print(f"📊 Total: {len(amr_genes)} gènes ({amr_count} AMR, {vir_count} virulence, {stress_count} stress)")

    # Récupérer l'espèce détectée par NCBI depuis la variable d'environnement
    detected_species = os.environ.get('NCBI_DETECTED_SPECIES', None)
    if detected_species:
        print(f"🦠 Espèce détectée via NCBI: {detected_species}")

    # Récupérer les résultats MLST depuis les variables d'environnement
    mlst_data = None
    mlst_scheme = os.environ.get('MLST_SCHEME', None)
    mlst_st = os.environ.get('MLST_ST', None)
    mlst_alleles = os.environ.get('MLST_ALLELES', None)
    if mlst_st and mlst_st != '-':
        mlst_data = {
            'scheme': mlst_scheme,
            'st': mlst_st,
            'alleles': mlst_alleles
        }
        print(f"🧬 MLST: {mlst_scheme} / ST{mlst_st}")
    
    # Pré-classifier les gènes pour les métriques (même classification que dans generate_html_report)
    for gene in amr_genes:
        gravity, color = classify_gravity(gene)
        gene['gravity'] = gravity
        gene['color'] = color
        gene['priority'] = gravity  # Alias pour compatibilité avec le backend

    # Sauvegarder le JSON des gènes classifiés (source unique de vérité pour le backend)
    json_output_file = os.path.join(os.path.dirname(output_file), f"{sample_id}_classified_genes.json")
    try:
        # Préparer les données pour le JSON (convertir en format compatible backend)
        json_genes = []
        for gene in amr_genes:
            json_gene = {
                'gene': gene.get('gene', ''),
                'sequence': gene.get('contig', ''),
                'start': 0,
                'end': 0,
                'strand': '+',
                'coverage': float(gene.get('coverage', 0) or 0),
                'identity': float(gene.get('identity', 0) or 0),
                'database': gene.get('source', ''),
                'accession': '',
                'product': gene.get('product') or gene.get('gene_description', ''),
                'resistance': gene.get('class') or gene.get('resistance', ''),
                'subclass': gene.get('subclass', ''),
                'element_type': gene.get('element_type', 'AMR'),
                'element_subtype': gene.get('element_subtype', ''),
                'source': gene.get('source', ''),
                'sources': [gene.get('source', '')],
                'priority': gene.get('priority', 'MEDIUM')
            }
            json_genes.append(json_gene)

        json_data = {
            'genes': json_genes,
            'stats': {
                'total_raw': len(amr_genes),
                'total_deduplicated': len(amr_genes),
                'duplicates_removed': 0,
                'by_type': {
                    'AMR': len([g for g in amr_genes if g.get('element_type', 'AMR') == 'AMR']),
                    'VIRULENCE': len([g for g in amr_genes if g.get('element_type', '') == 'VIRULENCE']),
                    'STRESS': len([g for g in amr_genes if g.get('element_type', '') == 'STRESS']),
                    'UNKNOWN': 0
                }
            }
        }
        with open(json_output_file, 'w', encoding='utf-8') as jf:
            json.dump(json_data, jf, ensure_ascii=False, indent=2)
        print(f"💾 JSON gènes classifiés: {json_output_file}")
    except Exception as e:
        print(f"⚠️  Impossible de sauvegarder le JSON: {e}", file=sys.stderr)

    # Calculer les métriques de qualité APRÈS classification
    quality_metrics = None
    if amr_genes:
        try:
            # Compter les gènes par gravité
            critical_count = len([g for g in amr_genes if g.get('gravity') == 'CRITICAL'])
            high_count = len([g for g in amr_genes if g.get('gravity') == 'HIGH'])
            medium_count = len([g for g in amr_genes if g.get('gravity') == 'MEDIUM'])

            # Compter par niveau de confiance (basé sur identity)
            high_conf = len([g for g in amr_genes if g.get('identity', 0) >= 95])
            medium_conf = len([g for g in amr_genes if 90 <= g.get('identity', 0) < 95])
            low_conf = len([g for g in amr_genes if g.get('identity', 0) < 90])
            total = len(amr_genes)

            quality_metrics = {
                'summary': {
                    'total_genes_detected': total,
                    'total_critical_genes': critical_count,
                    'total_high_genes': high_count,
                    'total_medium_genes': medium_count,
                    'high_confidence_genes': high_conf,
                    'medium_confidence_genes': medium_conf,
                    'low_confidence_genes': low_conf
                },
                'confidence_distribution': {
                    'high_confidence_pct': (high_conf / total * 100) if total > 0 else 0,
                    'medium_confidence_pct': (medium_conf / total * 100) if total > 0 else 0,
                    'low_confidence_pct': (low_conf / total * 100) if total > 0 else 0
                }
            }
            print(f"📊 Métriques: {critical_count} CRITICAL, {high_count} HIGH, {medium_count} MEDIUM")
        except Exception as e:
            print(f"⚠️  Impossible de calculer les métriques de qualité: {e}", file=sys.stderr)
    
    # Générer rapport même s'il n'y a pas de gènes ARG (pour afficher l'espèce détectée)
    print(f"📝 Génération du rapport HTML...")
    if not amr_genes:
        print("⚠️  Aucun gène ARG trouvé, mais génération du rapport avec les informations disponibles...")
        # Générer un rapport minimal avec juste l'espèce détectée
        generate_html_report([], sample_id, output_file, detected_species, quality_metrics, mlst_data)
    else:
        generate_html_report(amr_genes, sample_id, output_file, detected_species, quality_metrics, mlst_data)
    print(f"\n✨ Rapport disponible: {output_file}")

if __name__ == "__main__":
    main()
