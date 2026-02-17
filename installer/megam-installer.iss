; ===============================================================================
; MEGAM ARG Detection — Installeur Windows (Inno Setup)
; ===============================================================================

#define MyAppName "MEGAM ARG Detection"
#define MyAppVersion "3.2"
#define MyAppPublisher "Rachid Merah"
#define MyAppURL "https://github.com/rmerah/megam-arg-docker"
#define MyAppExeName "megam-launcher.ps1"

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
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\installer\icon.ico
MinVersion=10.0
ArchitecturesInstallIn64BitModeOnly=x64

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
Source: "..\.env.example"; DestDir: "{app}"; DestName: ".env"

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
var
  PrereqPage: TWizardPage;
  WSLLabel, DockerLabel, DiskLabel: TNewStaticText;
  WSLInstalled, DockerInstalled: Boolean;
  NeedsRestart: Boolean;

// ─────────────────────────────────────────────────────────────────────────────
// Vérification des prérequis
// ─────────────────────────────────────────────────────────────────────────────

function IsWSLInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe', '/c wsl --status >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function IsDockerInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf}\Docker\Docker\Docker Desktop.exe')) or
            FileExists(ExpandConstant('{localappdata}\Docker\Docker Desktop.exe'));
end;

function GetFreeDiskSpaceGB: Integer;
var
  FreeSpace: Int64;
begin
  GetSpaceOnDisk(ExpandConstant('{commonpf}'), True, FreeSpace, FreeSpace);
  Result := FreeSpace div (1024 * 1024 * 1024);
end;

// ─────────────────────────────────────────────────────────────────────────────
// Page de vérification des prérequis
// ─────────────────────────────────────────────────────────────────────────────

procedure CreatePrereqPage;
var
  FreeDisk: Integer;
  StatusText: String;
begin
  PrereqPage := CreateCustomPage(wpWelcome,
    'Vérification des prérequis',
    'L''installeur vérifie les composants nécessaires au fonctionnement de ' + '{#MyAppName}');

  WSLInstalled := IsWSLInstalled;
  DockerInstalled := IsDockerInstalled;
  FreeDisk := GetFreeDiskSpaceGB;

  // WSL2
  WSLLabel := TNewStaticText.Create(WizardForm);
  WSLLabel.Parent := PrereqPage.Surface;
  WSLLabel.Left := 0;
  WSLLabel.Top := 20;
  WSLLabel.Width := PrereqPage.SurfaceWidth;
  WSLLabel.AutoSize := False;
  WSLLabel.WordWrap := True;
  if WSLInstalled then
    WSLLabel.Caption := '✓  WSL2 est installé'
  else
    WSLLabel.Caption := '✗  WSL2 n''est PAS installé' + #13#10 +
      '     → Installation automatique (~3 min)' + #13#10 +
      '     → Un redémarrage sera nécessaire';

  // Docker Desktop
  DockerLabel := TNewStaticText.Create(WizardForm);
  DockerLabel.Parent := PrereqPage.Surface;
  DockerLabel.Left := 0;
  DockerLabel.Top := 90;
  DockerLabel.Width := PrereqPage.SurfaceWidth;
  DockerLabel.AutoSize := False;
  DockerLabel.WordWrap := True;
  if DockerInstalled then
    DockerLabel.Caption := '✓  Docker Desktop est installé'
  else
    DockerLabel.Caption := '✗  Docker Desktop n''est PAS installé' + #13#10 +
      '     → Installation automatique (~5 min)' + #13#10 +
      '     → Téléchargement ~500 MB';

  // Espace disque
  DiskLabel := TNewStaticText.Create(WizardForm);
  DiskLabel.Parent := PrereqPage.Surface;
  DiskLabel.Left := 0;
  DiskLabel.Top := 160;
  DiskLabel.Width := PrereqPage.SurfaceWidth;
  DiskLabel.AutoSize := False;
  if FreeDisk >= 10 then
    StatusText := '✓'
  else
    StatusText := '✗';
  DiskLabel.Caption := StatusText + '  Espace disque : ' + IntToStr(FreeDisk) + ' GB libres (minimum : 10 GB)';
end;

// ─────────────────────────────────────────────────────────────────────────────
// Installation WSL2
// ─────────────────────────────────────────────────────────────────────────────

function InstallWSL: Boolean;
var
  ResultCode: Integer;
begin
  WizardForm.StatusLabel.Caption := 'Activation de WSL2... (~3 minutes)';
  Result := Exec('cmd.exe', '/c wsl --install --no-distribution', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if Result and (ResultCode = 0) then
  begin
    NeedsRestart := True;
  end;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Installation Docker Desktop
// ─────────────────────────────────────────────────────────────────────────────

function DownloadAndInstallDocker: Boolean;
var
  ResultCode: Integer;
  DockerInstaller: String;
begin
  DockerInstaller := ExpandConstant('{tmp}\DockerDesktopInstaller.exe');
  Result := False;

  // Télécharger Docker Desktop
  WizardForm.StatusLabel.Caption := 'Téléchargement de Docker Desktop... (~500 MB)';
  if idpDownloadFile('https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe', DockerInstaller) then
  begin
    // Installation silencieuse
    WizardForm.StatusLabel.Caption := 'Installation de Docker Desktop... (~5 minutes)';
    Result := Exec(DockerInstaller, 'install --quiet --accept-license', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if Result and (ResultCode = 0) then
    begin
      NeedsRestart := True;
    end;
  end;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Hooks Inno Setup
// ─────────────────────────────────────────────────────────────────────────────

procedure InitializeWizard;
begin
  NeedsRestart := False;
  CreatePrereqPage;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  // Si on quitte la page des prérequis
  if CurPageID = PrereqPage.ID then
  begin
    // Vérifier l'espace disque
    if GetFreeDiskSpaceGB < 10 then
    begin
      MsgBox('Espace disque insuffisant. Au moins 10 GB sont nécessaires.', mbError, MB_OK);
      Result := False;
      Exit;
    end;

    // Installer WSL2 si nécessaire
    if not WSLInstalled then
    begin
      if MsgBox('WSL2 va être installé. Continuer ?', mbConfirmation, MB_YESNO) = IDNO then
      begin
        Result := False;
        Exit;
      end;
      if not InstallWSL then
      begin
        MsgBox('Échec de l''installation de WSL2. Veuillez l''installer manuellement.', mbError, MB_OK);
        Result := False;
        Exit;
      end;
    end;

    // Installer Docker Desktop si nécessaire
    if not DockerInstalled then
    begin
      if MsgBox('Docker Desktop va être téléchargé et installé (~500 MB). Continuer ?', mbConfirmation, MB_YESNO) = IDNO then
      begin
        Result := False;
        Exit;
      end;
      if not DownloadAndInstallDocker then
      begin
        MsgBox('Échec de l''installation de Docker Desktop. Veuillez l''installer manuellement depuis docker.com', mbError, MB_OK);
        Result := False;
        Exit;
      end;
    end;
  end;
end;

function NeedRestart: Boolean;
begin
  Result := NeedsRestart;
end;
