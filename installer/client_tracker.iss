; Windows installer for Client Tracker (Inno Setup 6), built by CI:
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
AppName=Client Tracker
AppVersion={#AppVersion}
AppVerName=Client Tracker {#AppVersion}
AppPublisher=Studies and Awards Limited
DefaultDirName={autopf}\Client Tracker
DefaultGroupName=Client Tracker
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=ClientTrackerSetup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\client_tracker.exe
UninstallDisplayName=Client Tracker
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Close a running copy before replacing its files, and reopen it after.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Client Tracker"; Filename: "{app}\client_tracker.exe"
Name: "{autodesktop}\Client Tracker"; Filename: "{app}\client_tracker.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\client_tracker.exe"; Description: "Open Client Tracker"; Flags: nowait postinstall skipifsilent
