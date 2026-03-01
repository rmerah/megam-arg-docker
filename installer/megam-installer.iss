; ===============================================================================
; MEGAM ARG Detection — Installeur Windows (Inno Setup 6)
;
; Cet installeur :
;   1. Affiche une page de prérequis (WSL2, Docker, espace disque)
;   2. Installe WSL2 si absent (via wsl --install)
;   3. Guide l'utilisateur pour installer Docker Desktop manuellement
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
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\megam-launcher.ps1"""; Description: "Lancer {#MyAppName} maintenant"; Flags: postinstall nowait skipifsilent

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
// Utilise le chemin absolu vers wsl.exe pour éviter l'erreur "terme non reconnu"
// sur les machines où WSL n'a jamais été installé (wsl.exe absent du PATH)
// ─────────────────────────────────────────────────────────────────────────────
function CheckWSL: Boolean;
var
  ExitCode: Integer;
  WslExe: String;
begin
  WslExe := ExpandConstant('{sys}\wsl.exe');
  // Si wsl.exe n'existe pas du tout, WSL n'est pas installé
  if not FileExists(WslExe) then
  begin
    Result := False;
    Exit;
  end;
  // wsl --status retourne 0 si WSL est installé et fonctionnel
  Exec(WslExe, '--status', '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
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
      '     > Vous devez l''installer manuellement avant de continuer' + #13#10 +
      '     > Cliquez sur Suivant pour obtenir les instructions';

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
// Utilise le chemin absolu pour éviter l'erreur "terme non reconnu".
// Sur Windows trop ancien (< Build 19041), wsl.exe est absent : on affiche
// un message d'erreur explicite plutôt qu'un échec silencieux.
// ─────────────────────────────────────────────────────────────────────────────
function DoInstallWSL: Boolean;
var
  ExitCode: Integer;
  WslExe: String;
begin
  Result := False;
  WslExe := ExpandConstant('{sys}\wsl.exe');

  // wsl.exe absent = Windows trop ancien pour wsl --install (< Build 19041)
  if not FileExists(WslExe) then
  begin
    MsgBox(
      'La commande wsl.exe est introuvable sur votre système.' + #13#10 +
      '' + #13#10 +
      'Votre version de Windows est probablement trop ancienne.' + #13#10 +
      'WSL2 nécessite Windows 10 version 2004 (Build 19041) ou supérieur.' + #13#10 +
      '' + #13#10 +
      'Solutions :' + #13#10 +
      '  1. Mettez à jour Windows via :' + #13#10 +
      '     Paramètres → Mise à jour et sécurité → Windows Update' + #13#10 +
      '' + #13#10 +
      '  2. Ou activez WSL manuellement (PowerShell en administrateur) :' + #13#10 +
      '     dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart' + #13#10 +
      '     dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart' + #13#10 +
      '     Puis redémarrez et relancez cet installeur.',
      mbError, MB_OK);
    Exit;
  end;

  // Lancer wsl --install via le chemin absolu
  Result := Exec(WslExe, '--install --no-distribution',
                 '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := Result and (ExitCode = 0);
  if Result then
    RestartNeeded := True;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Instructions pour installer Docker Desktop manuellement
// L'installeur ne télécharge PAS Docker à la place de l'utilisateur
// ─────────────────────────────────────────────────────────────────────────────
procedure ShowDockerInstallInstructions;
begin
  MsgBox(
    'Docker Desktop doit être installé manuellement.' + #13#10 +
    '' + #13#10 +
    'Voici les étapes :' + #13#10 +
    '' + #13#10 +
    '1. Ouvrez votre navigateur (Chrome, Firefox, Edge...)' + #13#10 +
    '2. Allez sur Google et tapez : install docker desktop windows' + #13#10 +
    '3. Cliquez sur le premier lien (docker.com)' + #13#10 +
    '4. Cliquez sur le bouton "Download Docker Desktop"' + #13#10 +
    '5. Lancez le fichier téléchargé (Docker Desktop Installer.exe)' + #13#10 +
    '6. Suivez l''assistant d''installation (acceptez les options par défaut)' + #13#10 +
    '7. Redémarrez votre ordinateur si demandé' + #13#10 +
    '8. Lancez Docker Desktop une première fois depuis le menu Démarrer' + #13#10 +
    '' + #13#10 +
    'Une fois Docker Desktop installé, relancez cet installeur.',
    mbInformation, MB_OK);
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

  // 3. Docker Desktop — installation manuelle requise
  if not DockerReady then
  begin
    ShowDockerInstallInstructions;
    Result := False;
    Exit;
  end;
end;

function NeedRestart: Boolean;
begin
  Result := RestartNeeded;
end;
