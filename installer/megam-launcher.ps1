#===============================================================================
# MEGAM ARG Detection - Lanceur Windows
# Ce script est execute par le raccourci bureau
#===============================================================================

# Log file pour debug
$LogFile = "$env:TEMP\megam-launcher.log"
"[$(Get-Date)] MEGAM Launcher demarre" | Out-File $LogFile -Append

# Charger WinForms en tout premier
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

# Chemins
$AppDir = "$env:ProgramFiles\MEGAM-ARG"
$ComposeFile = "$AppDir\docker\docker-compose.yml"
$Port = 8080

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

function Show-Progress {
    param([string]$Title, [string]$Message)
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

    if ($LogContent) {
        $fullMsg = "$Message`n`nDernieres lignes de log :`n$LogContent`n`nCliquez OK pour copier les logs dans le presse-papiers."
        [System.Windows.Forms.MessageBox]::Show($fullMsg, "MEGAM ARG - Erreur", "OK", "Error")
        [System.Windows.Forms.Clipboard]::SetText($LogContent)
    } else {
        [System.Windows.Forms.MessageBox]::Show($Message, "MEGAM ARG - Erreur", "OK", "Error")
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

# -----------------------------------------------------------------------------
# DEBUT - Tout est wrappe dans un try/catch global
# -----------------------------------------------------------------------------

try {

"[$(Get-Date)] Verification de Docker..." | Out-File $LogFile -Append

# -----------------------------------------------------------------------------
# 0. Verifier que Docker Desktop est installe
# -----------------------------------------------------------------------------

if (-not (Test-DockerInstalled)) {
    "[$(Get-Date)] Docker Desktop non trouve" | Out-File $LogFile -Append
    Show-Error ("Docker Desktop n'est pas installe.`n`n" +
        "Pour l'installer :`n" +
        "1. Ouvrez votre navigateur (Chrome, Edge, Firefox...)`n" +
        "2. Allez sur Google et tapez : install docker desktop windows`n" +
        "3. Cliquez sur le premier lien (docker.com)`n" +
        "4. Cliquez sur 'Download Docker Desktop'`n" +
        "5. Lancez le fichier telecharge et suivez les etapes`n" +
        "6. Redemarrez si demande`n" +
        "7. Lancez Docker Desktop une fois depuis le menu Demarrer`n" +
        "8. Puis relancez MEGAM ARG Detection")
    exit 1
}

"[$(Get-Date)] Docker Desktop trouve" | Out-File $LogFile -Append

# -----------------------------------------------------------------------------
# 1. Verifier et lancer Docker Desktop
# -----------------------------------------------------------------------------

if (-not (Test-DockerRunning)) {
    "[$(Get-Date)] Docker pas en cours, tentative de demarrage..." | Out-File $LogFile -Append
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
    $form = Show-Progress -Title "MEGAM ARG Detection" -Message "Demarrage de Docker Desktop... (~30 secondes)`nVeuillez patienter."
    Start-Process $dockerExe
    $dockerReady = Wait-ForDocker -TimeoutSeconds 120
    $form.Close()

    if (-not $dockerReady) {
        "[$(Get-Date)] Docker Desktop timeout apres 120s" | Out-File $LogFile -Append
        Show-Error "Docker Desktop ne demarre pas apres 2 minutes.`nVeuillez le relancer manuellement depuis le menu Demarrer, puis reessayez."
        exit 1
    }
} else {
    "[$(Get-Date)] Docker deja en cours d'execution" | Out-File $LogFile -Append
}

# -----------------------------------------------------------------------------
# 2. Verifier si l'image existe (premier lancement)
# -----------------------------------------------------------------------------

$imageExists = $false
try {
    $images = docker images --format "{{.Repository}}:{{.Tag}}" 2>&1
    if ($images -match "megam-arg") {
        $imageExists = $true
    }
} catch {}

"[$(Get-Date)] Image existe: $imageExists" | Out-File $LogFile -Append

if (-not $imageExists) {
    # Premier lancement : pull l'image depuis GHCR
    "[$(Get-Date)] Debut du pull de l'image..." | Out-File $LogFile -Append
    $form = Show-Progress -Title "MEGAM ARG Detection" -Message "Telechargement de l'application... (~10-15 minutes)`nCette etape n'est necessaire qu'une seule fois."
    $form.Refresh()

    try {
        Set-Location $AppDir
        # Lancer docker compose pull dans une fenetre cmd visible
        $cmdArgs = '/c docker compose -f "' + $ComposeFile + '" pull & pause'
        $pullProcess = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -PassThru -Wait
        if ($pullProcess.ExitCode -ne 0) {
            # Fallback : build local (visible aussi)
            "[$(Get-Date)] Pull echoue, tentative de build local..." | Out-File $LogFile -Append
            $form.Close()
            $form = Show-Progress -Title "MEGAM ARG Detection" -Message "Construction de l'image en local... (~20-30 minutes)`nCette etape n'est necessaire qu'une seule fois."
            $form.Refresh()
            $cmdArgs = '/c docker compose -f "' + $ComposeFile + '" build & pause'
            $buildProcess = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -PassThru -Wait
            if ($buildProcess.ExitCode -ne 0) {
                throw "Build failed"
            }
        }
    } catch {
        $form.Close()
        "[$(Get-Date)] ERREUR pull/build: $($_.Exception.Message)" | Out-File $LogFile -Append
        Show-Error ("Echec du telechargement de l'image Docker.`n`n" +
            "Verifiez :`n" +
            "- Votre connexion Internet`n" +
            "- Que Docker Desktop est bien lance (icone baleine dans la barre des taches)`n`n" +
            "Puis reessayez en double-cliquant sur le raccourci MEGAM ARG Detection.") $_.Exception.Message
        exit 1
    }

    $form.Close()
    "[$(Get-Date)] Image telechargee avec succes" | Out-File $LogFile -Append
}

# -----------------------------------------------------------------------------
# 3. Demarrer l'application
# -----------------------------------------------------------------------------

"[$(Get-Date)] Demarrage de l'application..." | Out-File $LogFile -Append
$form = Show-Progress -Title "MEGAM ARG Detection" -Message "Demarrage de l'application... (~10 secondes)"

try {
    Set-Location $AppDir
    $upProcess = Start-Process -FilePath "docker" -ArgumentList ('compose -f "' + $ComposeFile + '" up -d') -PassThru -Wait -NoNewWindow
    if ($upProcess.ExitCode -ne 0) {
        throw "docker compose up failed"
    }
} catch {
    $form.Close()
    $logs = ""
    try { $logs = docker compose -f $ComposeFile logs --tail=30 2>&1 | Out-String } catch {}
    "[$(Get-Date)] ERREUR docker up: $($_.Exception.Message)" | Out-File $LogFile -Append
    Show-Error "Echec du demarrage de l'application." $logs
    exit 1
}

# -----------------------------------------------------------------------------
# 4. Attendre que l'app soit prete et ouvrir le navigateur
# -----------------------------------------------------------------------------

"[$(Get-Date)] Attente de l'application sur le port $Port..." | Out-File $LogFile -Append
$appReady = Wait-ForApp -TimeoutSeconds 180
$form.Close()

if ($appReady) {
    "[$(Get-Date)] Application prete, ouverture du navigateur" | Out-File $LogFile -Append
    Start-Process "http://localhost:$Port"
} else {
    $logs = ""
    try { $logs = docker compose -f $ComposeFile logs --tail=50 2>&1 | Out-String } catch {}
    "[$(Get-Date)] Application ne repond pas apres 180s" | Out-File $LogFile -Append
    Show-Error ("L'application ne repond pas apres 3 minutes.`n`n" +
        "Essayez :`n" +
        "1. Ouvrez Docker Desktop et verifiez que le conteneur 'megam-arg' est en cours d'execution`n" +
        "2. Si le conteneur est arrete, relancez MEGAM ARG Detection`n" +
        "3. Si le probleme persiste, redemarrez Docker Desktop") $logs
}

# -----------------------------------------------------------------------------
} catch {
    # Erreur inattendue - toujours montrer quelque chose a l'utilisateur
    $errorMsg = $_.Exception.Message
    $errorLine = $_.InvocationInfo.ScriptLineNumber
    "[$(Get-Date)] ERREUR FATALE ligne $errorLine : $errorMsg" | Out-File $LogFile -Append
    [System.Windows.Forms.MessageBox]::Show(
        "Une erreur inattendue s'est produite :`n`n$errorMsg`n`n(ligne $errorLine)`n`nConsultez le log : $LogFile",
        "MEGAM ARG - Erreur",
        "OK",
        "Error"
    )
}
