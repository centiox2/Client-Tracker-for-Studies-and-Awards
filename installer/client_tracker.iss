; Windows installer for S&A Hub (Inno Setup 6), built by CI:
;   ISCC.exe /DAppVersion=1.1.0 installer\client_tracker.iss
; Installs for the current user (no admin rights needed), with Start menu
; and optional desktop shortcuts and an uninstaller. Running a newer
; installer upgrades in place. The app's data lives in the user's Documents
; folder, not here, so upgrading or uninstalling never touches it.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
; Fixed id: every version of the installer upgrades the same app.
AppId={{5B7E2C64-8F3A-4C2D-9E1B-6A4D0C3F7A21}
AppName=S&A Hub
AppVersion={#AppVersion}
AppVerName=S&A Hub {#AppVersion}
AppPublisher=Studies and Awards Limited
; An existing install keeps its folder (same AppId), so upgrades land in place.
DefaultDirName={autopf}\SA Hub
DefaultGroupName=S&A Hub
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=SAHubSetup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\client_tracker.exe
UninstallDisplayName=S&A Hub
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Close a running copy before replacing its files, and reopen it after.
CloseApplications=yes
RestartApplications=no
#ifdef Sign
; Signed by CI with the company's code-signing certificate ("sahub" is
; the sign tool defined on the ISCC command line): the installer and the
; uninstaller both carry the publisher's name.
SignTool=sahub
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; The app used to be called Client Tracker: remove its old shortcuts.
[InstallDelete]
Type: files; Name: "{autoprograms}\Client Tracker.lnk"
Type: files; Name: "{autodesktop}\Client Tracker.lnk"

[Icons]
Name: "{autoprograms}\S&A Hub"; Filename: "{app}\client_tracker.exe"
Name: "{autodesktop}\S&A Hub"; Filename: "{app}\client_tracker.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\client_tracker.exe"; Description: "Open S&A Hub"; Flags: nowait postinstall skipifsilent
