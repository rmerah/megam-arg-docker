#===============================================================================
# MEGAM ARG Detection - Arret de l'application
#===============================================================================

$AppDir = "$env:ProgramFiles\MEGAM-ARG"
$ComposeFile = "$AppDir\docker\docker-compose.yml"

Add-Type -AssemblyName System.Windows.Forms

try {
    Set-Location $AppDir
    docker compose -f $ComposeFile down 2>&1 | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        "MEGAM ARG Detection a ete arrete.",
        "MEGAM ARG Detection",
        "OK",
        "Information"
    )
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Erreur lors de l'arret : $($_.Exception.Message)",
        "MEGAM ARG - Erreur",
        "OK",
        "Error"
    )
}
