#===============================================================================
# MEGAM ARG Detection — Lanceur Windows
# Ce script est exécuté par le raccourci bureau (fenêtre cachée)
#===============================================================================

$ErrorActionPreference = "Stop"

# Chemins
$AppDir = "$env:ProgramFiles\MEGAM-ARG"
$ComposeFile = "$AppDir\docker\docker-compose.yml"
$Port = 8080

# ─────────────────────────────────────────────────────────────────────────────
# Fonctions utilitaires
# ─────────────────────────────────────────────────────────────────────────────

function Show-Progress {
    param([string]$Title, [string]$Message)
    # Utiliser une notification toast Windows ou une fenêtre WPF simple
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(420, 160)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $false
    $label.Size = New-Object System.Drawing.Size(380, 60)
    $label.Location = New-Object System.Drawing.Point(15, 20)
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($label)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Style = "Marquee"
    $progress.MarqueeAnimationSpeed = 30
    $progress.Size = New-Object System.Drawing.Size(380, 25)
    $progress.Location = New-Object System.Drawing.Point(15, 85)
    $form.Controls.Add($progress)

    $form.Show()
    $form.Refresh()
    return $form
}

function Show-Error {
    param([string]$Message, [string]$LogContent = "")
    Add-Type -AssemblyName System.Windows.Forms

    if ($LogContent) {
        $fullMsg = "$Message`n`nDernières lignes de log :`n$LogContent`n`nCliquez OK pour copier les logs dans le presse-papiers."
        [System.Windows.Forms.MessageBox]::Show($fullMsg, "MEGAM ARG — Erreur", "OK", "Error")
        [System.Windows.Forms.Clipboard]::SetText($LogContent)
    } else {
        [System.Windows.Forms.MessageBox]::Show($Message, "MEGAM ARG — Erreur", "OK", "Error")
    }
}

function Test-DockerRunning {
    try {
        $null = docker info 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Wait-ForDocker {
    param([int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-DockerRunning) { return $true }
        Start-Sleep -Seconds 3
        $elapsed += 3
        # Rafraîchir la fenêtre de progression
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $false
}

function Wait-ForApp {
    param([int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Seconds 3
        $elapsed += 3
        # Rafraîchir la fenêtre de progression
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Vérifier et lancer Docker Desktop
# ─────────────────────────────────────────────────────────────────────────────

if (-not (Test-DockerRunning)) {
    # Chercher Docker Desktop
    $dockerExe = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $dockerExe)) {
        $dockerExe = "${env:LOCALAPPDATA}\Docker\Docker Desktop.exe"
    }

    if (-not (Test-Path $dockerExe)) {
        Show-Error "Docker Desktop n'est pas installé.`nVeuillez réinstaller MEGAM ARG Detection."
        exit 1
    }

    # Lancer Docker Desktop
    $form = Show-Progress -Title "MEGAM ARG Detection" -Message "Démarrage de Docker Desktop... (~30 secondes)`nVeuillez patienter."
    Start-Process $dockerExe
    $dockerReady = Wait-ForDocker -TimeoutSeconds 120
    $form.Close()

    if (-not $dockerReady) {
        Show-Error "Docker Desktop ne démarre pas après 2 minutes.`nVeuillez le relancer manuellement depuis le menu Démarrer, puis réessayez."
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Vérifier si l'image existe (premier lancement)
# ─────────────────────────────────────────────────────────────────────────────

$imageExists = $false
try {
    $images = docker images --format "{{.Repository}}:{{.Tag}}" 2>&1
    if ($images -match "megam-arg") {
        $imageExists = $true
    }
} catch {}

if (-not $imageExists) {
    # Premier lancement : pull ou build
    $form = Show-Progress -Title "MEGAM ARG Detection — Premier lancement" -Message "Téléchargement de l'application... (~10-15 minutes)`nCette étape n'est nécessaire qu'une seule fois."

    try {
        $env:COMPOSE_FILE = $ComposeFile
        Set-Location $AppDir
        docker compose -f $ComposeFile pull 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Fallback : build local
            docker compose -f $ComposeFile build 2>&1 | Out-Null
        }
    } catch {
        $form.Close()
        Show-Error "Échec du téléchargement de l'image Docker.`nVérifiez votre connexion Internet et réessayez." $_.Exception.Message
        exit 1
    }

    $form.Close()
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Démarrer l'application
# ─────────────────────────────────────────────────────────────────────────────

$form = Show-Progress -Title "MEGAM ARG Detection" -Message "Démarrage de l'application... (~10 secondes)"

try {
    Set-Location $AppDir
    docker compose -f $ComposeFile up -d 2>&1 | Out-Null
} catch {
    $form.Close()
    $logs = docker compose -f $ComposeFile logs --tail=30 2>&1 | Out-String
    Show-Error "Échec du démarrage de l'application." $logs
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Attendre que l'app soit prête et ouvrir le navigateur
# ─────────────────────────────────────────────────────────────────────────────

$appReady = Wait-ForApp -TimeoutSeconds 120
$form.Close()

if ($appReady) {
    Start-Process "http://localhost:$Port"
} else {
    $logs = docker compose -f $ComposeFile logs --tail=50 2>&1 | Out-String
    Show-Error "L'application ne répond pas après 2 minutes de démarrage." $logs
}
