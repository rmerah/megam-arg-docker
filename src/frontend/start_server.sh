#!/bin/bash
# Serveur HTTP simple pour le frontend
# Port 8080 pour éviter conflit avec backend (8000)

# Se placer dans le répertoire du script
cd "$(dirname "$0")"

echo "🌐 Démarrage serveur frontend..."
echo "📍 URL: http://localhost:8080"
echo ""
echo "Pages disponibles:"
echo "  - Formulaire: http://localhost:8080/form_launch_analysis.html"
echo "  - Dashboard:  http://localhost:8080/dashboard_monitoring.html?job_id=YOUR_JOB_ID"
echo "  - Résultats:  http://localhost:8080/page_results_arg.html?job_id=YOUR_JOB_ID"
echo ""
echo "Appuyez sur Ctrl+C pour arrêter"
echo ""

python3 -m http.server 8080
