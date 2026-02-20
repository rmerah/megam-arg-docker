#===============================================================================
# MEGAM ARG Detection — Lanceur Windows
# Ce script est exécuté par le raccourci bureau
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

function Test-DockerInstalled {
    $paths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    try {
        $null = docker --version 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    return $false
}

function Wait-ForDocker {
    param([int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-DockerRunning) { return $true }
        Start-Sleep -Seconds 3
        $elapsed += 3
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $false
}

function Wait-ForApp {
    param([int]$TimeoutSeconds = 180)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Seconds 3
        $elapsed += 3
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# 0. Vérifier que Docker Desktop est installé
# ─────────────────────────────────────────────────────────────────────────────

if (-not (Test-DockerInstalled)) {
    Show-Error ("Docker Desktop n'est pas installé.`n`n" +
        "Pour l'installer :`n" +
        "1. Ouvrez votre navigateur (Chrome, Edge, Firefox...)`n" +
        "2. Allez sur Google et tapez : install docker desktop windows`n" +
        "3. Cliquez sur le premier lien (docker.com)`n" +
        "4. Cliquez sur 'Download Docker Desktop'`n" +
        "5. Lancez le fichier téléchargé et suivez les étapes`n" +
        "6. Redémarrez si demandé`n" +
        "7. Lancez Docker Desktop une fois depuis le menu Démarrer`n" +
        "8. Puis relancez MEGAM ARG Detection")
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Vérifier et lancer Docker Desktop
# ─────────────────────────────────────────────────────────────────────────────

if (-not (Test-DockerRunning)) {
    # Chercher Docker Desktop
    $dockerExe = $null
    $paths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { $dockerExe = $p; break }
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
    # Premier lancement : pull l'image depuis GHCR
    $form = Show-Progress -Title "MEGAM ARG Detection — Premier lancement" -Message "Téléchargement de l'application... (~10-15 minutes)`nCette étape n'est nécessaire qu'une seule fois.`nUne fenêtre va s'ouvrir pour montrer la progression."
    $form.Refresh()

    try {
        Set-Location $AppDir
        # Montrer la progression du pull dans une fenêtre visible
        $pullProcess = Start-Process -FilePath "docker" -ArgumentList "compose -f `"$ComposeFile`" pull" -PassThru -Wait -NoNewWindow
        if ($pullProcess.ExitCode -ne 0) {
            # Fallback : build local (visible aussi)
            $form.Close()
            $form = Show-Progress -Title "MEGAM ARG Detection — Construction" -Message "Construction de l'image en local... (~20-30 minutes)`nCette étape n'est nécessaire qu'une seule fois."
            $form.Refresh()
            $buildProcess = Start-Process -FilePath "docker" -ArgumentList "compose -f `"$ComposeFile`" build" -PassThru -Wait -NoNewWindow
            if ($buildProcess.ExitCode -ne 0) {
                throw "Build failed"
            }
        }
    } catch {
        $form.Close()
        Show-Error ("Échec du téléchargement de l'image Docker.`n`n" +
            "Vérifiez :`n" +
            "- Votre connexion Internet`n" +
            "- Que Docker Desktop est bien lancé (icône dans la barre des tâches)`n`n" +
            "Puis réessayez en double-cliquant sur le raccourci MEGAM ARG Detection.") $_.Exception.Message
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
    $upProcess = Start-Process -FilePath "docker" -ArgumentList "compose -f `"$ComposeFile`" up -d" -PassThru -Wait -NoNewWindow
    if ($upProcess.ExitCode -ne 0) {
        throw "docker compose up failed"
    }
} catch {
    $form.Close()
    $logs = ""
    try { $logs = docker compose -f $ComposeFile logs --tail=30 2>&1 | Out-String } catch {}
    Show-Error "Échec du démarrage de l'application." $logs
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Attendre que l'app soit prête et ouvrir le navigateur
# ─────────────────────────────────────────────────────────────────────────────

$appReady = Wait-ForApp -TimeoutSeconds 180
$form.Close()

if ($appReady) {
    Start-Process "http://localhost:$Port"
} else {
    $logs = ""
    try { $logs = docker compose -f $ComposeFile logs --tail=50 2>&1 | Out-String } catch {}
    Show-Error ("L'application ne répond pas après 3 minutes.`n`n" +
        "Essayez :`n" +
        "1. Ouvrez Docker Desktop et vérifiez que le conteneur 'megam-arg' est en cours d'exécution`n" +
        "2. Si le conteneur est arrêté, relancez MEGAM ARG Detection`n" +
        "3. Si le problème persiste, redémarrez Docker Desktop") $logs
}
