; ===============================================================================
; MEGAM ARG Detection — Installeur Windows (Inno Setup 6)
;
; Cet installeur :
;   1. Affiche une page de prérequis (WSL2, Docker, espace disque)
;   2. Installe WSL2 si absent (via wsl --install)
;   3. Télécharge et installe Docker Desktop si absent (via PowerShell)
;   4. Copie les fichiers de l'application
;   5. Crée des raccourcis bureau + menu démarrer
;   6. Propose de lancer l'application
; ===============================================================================

#define MyAppName "MEGAM ARG Detection"
#define MyAppVersion "3.2"
#define MyAppPublisher "Rachid Merah"
#define MyAppURL "https://github.com/rmerah/megam-arg-docker"

[Setup]
AppId={{B5E8F4A2-3C7D-4E9B-A1F6-2D8E9C0B7A3F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={commonpf}\MEGAM-ARG
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputBaseFilename=MEGAM-ARG-Detection-Setup-{#MyAppVersion}
OutputDir=Output
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\installer\icon.ico
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Messages]
french.WelcomeLabel1=Bienvenue dans l'assistant d'installation de {#MyAppName}
french.WelcomeLabel2=Cet assistant va installer {#MyAppName} v{#MyAppVersion} sur votre ordinateur.%n%n{#MyAppName} est un pipeline de détection des gènes de résistance aux antimicrobiens (ARG).%n%nL'installation va :%n  - Vérifier les prérequis (WSL2, Docker Desktop)%n  - Installer automatiquement les composants manquants%n  - Configurer l'application%n%nCliquez sur Suivant pour continuer.

[Files]
; Fichiers de l'application
Source: "..\docker\*"; DestDir: "{app}\docker"; Flags: recursesubdirs
Source: "..\src\*"; DestDir: "{app}\src"; Flags: recursesubdirs
Source: "..\installer\megam-launcher.ps1"; DestDir: "{app}\installer"
Source: "..\installer\megam-stop.ps1"; DestDir: "{app}\installer"
Source: "..\installer\check-docker.ps1"; DestDir: "{app}\installer"
Source: "..\installer\icon.ico"; DestDir: "{app}\installer"
Source: "..\.env.example"; DestDir: "{app}"; DestName: ".env"; Flags: onlyifdoesntexist

[Icons]
Name: "{commondesktop}\{#MyAppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\installer\megam-launcher.ps1"""; IconFilename: "{app}\installer\icon.ico"; Comment: "Lancer {#MyAppName}"
Name: "{group}\{#MyAppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\installer\megam-launcher.ps1"""; IconFilename: "{app}\installer\icon.ico"
Name: "{group}\Arrêter {#MyAppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\megam-stop.ps1"""; IconFilename: "{app}\installer\icon.ico"

[Run]
; Proposer de lancer après installation
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\installer\megam-launcher.ps1"""; Description: "Lancer {#MyAppName} maintenant"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Arrêter l'application avant désinstallation
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\megam-stop.ps1"""; Flags: runhidden waituntilterminated

[Code]

// ─────────────────────────────────────────────────────────────────────────────
// Variables globales
// ─────────────────────────────────────────────────────────────────────────────
var
  PrereqPage: TWizardPage;
  LabelWSL, LabelDocker, LabelDisk: TNewStaticText;
  WSLReady, DockerReady: Boolean;
  RestartNeeded: Boolean;

// ─────────────────────────────────────────────────────────────────────────────
// Détection WSL2
// ─────────────────────────────────────────────────────────────────────────────
function CheckWSL: Boolean;
var
  ExitCode: Integer;
begin
  // wsl --status retourne 0 si WSL est installé et fonctionnel
  Exec('cmd.exe', '/c wsl --status >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := (ExitCode = 0);
end;

// ─────────────────────────────────────────────────────────────────────────────
// Détection Docker Desktop
// Vérifie plusieurs chemins d'installation possibles + la commande docker
// ─────────────────────────────────────────────────────────────────────────────
function CheckDocker: Boolean;
var
  ExitCode: Integer;
begin
  // Chemin classique (installation système, 64-bit)
  Result := FileExists(ExpandConstant('{commonpf64}\Docker\Docker\Docker Desktop.exe'));
  // Chemin classique (installation système, 32-bit fallback)
  if not Result then
    Result := FileExists(ExpandConstant('{commonpf}\Docker\Docker\Docker Desktop.exe'));
  // Chemin per-user (anciennes versions)
  if not Result then
    Result := FileExists(ExpandConstant('{localappdata}\Docker\Docker Desktop.exe'));
  // Chemin per-user (versions récentes : %LOCALAPPDATA%\Programs\Docker\Docker\)
  if not Result then
    Result := FileExists(ExpandConstant('{localappdata}\Programs\Docker\Docker\Docker Desktop.exe'));
  // Dernier recours : vérifier si la commande docker est dans le PATH
  if not Result then
  begin
    Exec('cmd.exe', '/c docker --version >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
    Result := (ExitCode = 0);
  end;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Espace disque libre (en Go)
// ─────────────────────────────────────────────────────────────────────────────
function FreeDiskGB: Integer;
var
  FreeMB, TotalMB: Cardinal;
begin
  GetSpaceOnDisk(ExpandConstant('{sd}'), True, FreeMB, TotalMB);
  Result := FreeMB div 1024;  // Mo -> Go
end;

// ─────────────────────────────────────────────────────────────────────────────
// Création de la page de prérequis
// ─────────────────────────────────────────────────────────────────────────────
procedure BuildPrereqPage;
var
  DiskGB: Integer;
  Marker: String;
begin
  PrereqPage := CreateCustomPage(wpWelcome,
    'Vérification des prérequis',
    'L''installeur vérifie les composants nécessaires.');

  WSLReady := CheckWSL;
  DockerReady := CheckDocker;
  DiskGB := FreeDiskGB;

  // --- WSL2 ---
  LabelWSL := TNewStaticText.Create(WizardForm);
  LabelWSL.Parent := PrereqPage.Surface;
  LabelWSL.Left := 0;
  LabelWSL.Top := 16;
  LabelWSL.Width := PrereqPage.SurfaceWidth;
  LabelWSL.Height := 70;
  LabelWSL.AutoSize := False;
  LabelWSL.WordWrap := True;
  if WSLReady then
    LabelWSL.Caption := '[OK]  WSL2 est installé'
  else
    LabelWSL.Caption :=
      '[MANQUANT]  WSL2 n''est pas installé' + #13#10 +
      '     > Installation automatique (~3 min)' + #13#10 +
      '     > Un redémarrage sera nécessaire après l''installation';

  // --- Docker Desktop ---
  LabelDocker := TNewStaticText.Create(WizardForm);
  LabelDocker.Parent := PrereqPage.Surface;
  LabelDocker.Left := 0;
  LabelDocker.Top := 96;
  LabelDocker.Width := PrereqPage.SurfaceWidth;
  LabelDocker.Height := 70;
  LabelDocker.AutoSize := False;
  LabelDocker.WordWrap := True;
  if DockerReady then
    LabelDocker.Caption := '[OK]  Docker Desktop est installé'
  else
    LabelDocker.Caption :=
      '[MANQUANT]  Docker Desktop n''est pas installé' + #13#10 +
      '     > Téléchargement et installation automatiques (~5 min)' + #13#10 +
      '     > Téléchargement : environ 500 Mo';

  // --- Espace disque ---
  if DiskGB >= 10 then Marker := '[OK]' else Marker := '[INSUFFISANT]';
  LabelDisk := TNewStaticText.Create(WizardForm);
  LabelDisk.Parent := PrereqPage.Surface;
  LabelDisk.Left := 0;
  LabelDisk.Top := 180;
  LabelDisk.Width := PrereqPage.SurfaceWidth;
  LabelDisk.AutoSize := False;
  LabelDisk.Caption := Marker + '  Espace disque libre : ' + IntToStr(DiskGB) + ' Go  (minimum requis : 10 Go)';
end;

// ─────────────────────────────────────────────────────────────────────────────
// Installation WSL2 via wsl --install
// ─────────────────────────────────────────────────────────────────────────────
function DoInstallWSL: Boolean;
var
  ExitCode: Integer;
begin
  Result := Exec('cmd.exe', '/c wsl --install --no-distribution',
                 '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := Result and (ExitCode = 0);
  if Result then
    RestartNeeded := True;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Téléchargement + installation Docker Desktop via PowerShell
// Utilise Invoke-WebRequest natif (pas de plugin externe)
// ─────────────────────────────────────────────────────────────────────────────
function DoInstallDocker: Boolean;
var
  ExitCode: Integer;
  PSCmd: String;
begin
  // Script PowerShell inline :
  //   1. Télécharge Docker Desktop Installer dans %TEMP%
  //   2. Lance l'installation silencieuse
  PSCmd := '-ExecutionPolicy Bypass -Command "' +
    '$ErrorActionPreference = ''Stop''; ' +
    '$installer = Join-Path $env:TEMP ''DockerDesktopInstaller.exe''; ' +
    'Write-Host ''Telechargement de Docker Desktop...''; ' +
    '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ' +
    'Invoke-WebRequest -Uri ''https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'' -OutFile $installer -UseBasicParsing; ' +
    'Write-Host ''Installation de Docker Desktop...''; ' +
    'Start-Process -FilePath $installer -ArgumentList ''install --quiet --accept-license'' -Wait; ' +
    'Remove-Item $installer -Force -ErrorAction SilentlyContinue; ' +
    'Write-Host ''Installation terminee.''"';

  Result := Exec('powershell.exe', PSCmd, '', SW_SHOW, ewWaitUntilTerminated, ExitCode);
  Result := Result and (ExitCode = 0);
  if Result then
    RestartNeeded := True;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Hooks
// ─────────────────────────────────────────────────────────────────────────────
procedure InitializeWizard;
begin
  RestartNeeded := False;
  BuildPrereqPage;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID <> PrereqPage.ID then
    Exit;

  // 1. Espace disque
  if FreeDiskGB < 10 then
  begin
    MsgBox('Espace disque insuffisant (minimum 10 Go).', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  // 2. WSL2
  if not WSLReady then
  begin
    if MsgBox('WSL2 n''est pas installé. L''installer maintenant ?'
              + #13#10 + '(Durée estimée : ~3 minutes, redémarrage nécessaire)',
              mbConfirmation, MB_YESNO) = IDNO then
    begin
      MsgBox('WSL2 est requis par Docker Desktop. L''installation ne peut pas continuer.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not DoInstallWSL then
    begin
      MsgBox('L''installation de WSL2 a échoué.'
             + #13#10 + 'Essayez manuellement : ouvrez PowerShell en admin et tapez : wsl --install',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
    MsgBox('WSL2 a été installé. Un redémarrage est nécessaire.'
           + #13#10 + 'Après le redémarrage, relancez cet installeur.',
           mbInformation, MB_OK);
    RestartNeeded := True;
    // Arrêter l'installation : Docker ne peut pas fonctionner avant le redémarrage
    Result := False;
    Exit;
  end;

  // 3. Docker Desktop
  if not DockerReady then
  begin
    if MsgBox('Docker Desktop n''est pas installé. Le télécharger et l''installer maintenant ?'
              + #13#10 + '(Téléchargement ~500 Mo, installation ~5 minutes)',
              mbConfirmation, MB_YESNO) = IDNO then
    begin
      MsgBox('Docker Desktop est requis. L''installation ne peut pas continuer.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not DoInstallDocker then
    begin
      MsgBox('L''installation de Docker Desktop a échoué.'
             + #13#10 + 'Téléchargez-le manuellement sur https://www.docker.com/products/docker-desktop/',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

function NeedRestart: Boolean;
begin
  Result := RestartNeeded;
end;
