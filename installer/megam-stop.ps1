#===============================================================================
# MEGAM ARG Detection — Arrêt de l'application
#===============================================================================

$AppDir = "$env:ProgramFiles\MEGAM-ARG"
$ComposeFile = "$AppDir\docker\docker-compose.yml"

Add-Type -AssemblyName System.Windows.Forms

try {
    Set-Location $AppDir
    docker compose -f $ComposeFile down 2>&1 | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        "MEGAM ARG Detection a été arrêté.",
        "MEGAM ARG Detection",
        "OK",
        "Information"
    )
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Erreur lors de l'arrêt : $($_.Exception.Message)",
        "MEGAM ARG — Erreur",
        "OK",
        "Error"
    )
}
