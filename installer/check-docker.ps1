#===============================================================================
# MEGAM ARG Detection - Verification des prerequis
# Retourne un objet JSON avec l'etat de chaque prerequis
#===============================================================================

$ErrorActionPreference = "SilentlyContinue"

function Test-WSL {
    # Utiliser le chemin absolu pour eviter l'erreur "terme non reconnu"
    # sur les machines ou WSL n'a jamais ete installe
    $wslExe = "$env:SystemRoot\System32\wsl.exe"
    if (-not (Test-Path $wslExe)) { return $false }

    try {
        $wslOutput = & $wslExe --status 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}

    # Verifier si la feature Windows est activee
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux 2>$null
    if ($wslFeature -and $wslFeature.State -eq "Enabled") { return $true }

    return $false
}

function Test-DockerDesktop {
    # Verifier si Docker Desktop est installe (plusieurs chemins possibles)
    $paths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    # Dernier recours : verifier si docker est dans le PATH
    try {
        $null = docker --version 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    return $false
}

function Test-DockerRunning {
    try {
        $result = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    return $false
}

function Get-FreeDiskSpaceGB {
    $drive = (Get-Item $env:ProgramFiles).PSDrive
    return [math]::Round($drive.Free / 1GB, 1)
}

# Verifications
$status = @{
    wsl_installed     = Test-WSL
    docker_installed  = Test-DockerDesktop
    docker_running    = Test-DockerRunning
    free_disk_gb      = Get-FreeDiskSpaceGB
    disk_ok           = (Get-FreeDiskSpaceGB) -ge 10
}

# Affichage
Write-Host ""
Write-Host "=== MEGAM ARG Detection - Verification des prerequis ===" -ForegroundColor Cyan
Write-Host ""

if ($status.wsl_installed) {
    Write-Host "  [OK] WSL2 est installe" -ForegroundColor Green
} else {
    Write-Host "  [!!] WSL2 n'est PAS installe" -ForegroundColor Red
}

if ($status.docker_installed) {
    Write-Host "  [OK] Docker Desktop est installe" -ForegroundColor Green
} else {
    Write-Host "  [!!] Docker Desktop n'est PAS installe" -ForegroundColor Red
}

if ($status.docker_running) {
    Write-Host "  [OK] Docker est en cours d'execution" -ForegroundColor Green
} else {
    Write-Host "  [!!] Docker n'est PAS en cours d'execution" -ForegroundColor Yellow
}

Write-Host "  [INFO] Espace disque libre : $($status.free_disk_gb) GB" -ForegroundColor $(if ($status.disk_ok) { "Green" } else { "Red" })
Write-Host ""

# Retourner le resultat sous forme d'objet
return $status
