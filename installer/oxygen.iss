; Installer for oxygen. Installs for the current user (no admin prompt) into
; %LOCALAPPDATA%\Programs\oxygen, adds a Start menu entry and registers an
; uninstaller under Settings > Apps > Installed apps.
;
; Build: ISCC.exe /DAppVersion=0.2.0 installer\oxygen.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{8E1B7A4C-3F2D-4C5B-9A61-0B2E7D4F1C93}
AppName=oxygen
AppVersion={#AppVersion}
AppVerName=oxygen {#AppVersion}
AppPublisher=oxygen
AppPublisherURL=https://github.com/aidma123/oxygen
AppSupportURL=https://github.com/aidma123/oxygen/issues
DefaultDirName={autopf}\oxygen
DefaultGroupName=oxygen
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=oxygen-setup
SetupIconFile=..\desktop\assets\oxygen.ico
UninstallDisplayIcon={app}\oxygen.exe
UninstallDisplayName=oxygen
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
MinVersion=10.0

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "..\desktop\target\release\oxygen.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\desktop\assets\fonts\JetBrainsMono-OFL.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\oxygen"; Filename: "{app}\oxygen.exe"; Comment: "Lightweight browser"
Name: "{autodesktop}\oxygen"; Filename: "{app}\oxygen.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\oxygen.exe"; Description: "Open oxygen"; Flags: nowait postinstall skipifsilent

; Your tabs and settings in %LOCALAPPDATA%\Oxygen are kept when uninstalling.
