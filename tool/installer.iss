; Compile through tool/build_installer.ps1. Never reuse the WinForms AppId.
#ifndef BundleDir
  #error BundleDir must point to a complete offline package
#endif
#ifndef OutputDir
  #error OutputDir must be supplied
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppExeName "flutter_gallery_test.exe"

[Setup]
AppId={{7040E4F7-ABCB-4FE7-AAD9-DC602B72EA63}
AppName=Umbra Tags (Flutter)
AppVersion={#AppVersion}
AppPublisher=Luka
DefaultDirName={localappdata}\Programs\Umbra Tags Flutter
DefaultGroupName=Umbra Tags (Flutter)
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=UmbraTags-Flutter-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/fast
SolidCompression=yes
DiskSpanning=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Umbra Tags (Flutter)"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall Umbra Tags (Flutter)"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Umbra Tags (Flutter)"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Description: "Launch Umbra Tags"; Flags: nowait postinstall skipifsilent

; No UninstallDelete or legacy registry/shortcut changes: external libraries and
; AppData settings remain owned by the user, including on uninstall.
[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\UmbraTags.exe')) or
     FileExists(ExpandConstant('{app}\Calypso.exe')) or
     FileExists(ExpandConstant('{app}\catalog.sqlite')) then
    Result := 'Choose a separate application folder. This folder contains a legacy application or image library.';
end;
