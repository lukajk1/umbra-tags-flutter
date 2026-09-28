#ifndef RuntimeId
  #error RuntimeId is required
#endif
[Setup]
AppId=UmbraTags-ML-{#RuntimeId}
AppName=Umbra Tags ML Runtime {#RuntimeId}
AppVersion={#RuntimeId}
AppPublisher=Luka
DefaultDirName={localappdata}\Umbra Tags\ML\{#RuntimeId}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=UmbraTags-ML-Runtime-{#RuntimeId}
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/fast
SolidCompression=yes
DiskSpanning=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#BundleDir}\umbra-tags-ml\python\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\umbra-tags-ml\models\*"; DestDir: "{app}\models"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\umbra-tags-ml\*.pth"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BundleDir}\umbra-tags-ml\ml-runtime.json"; DestDir: "{app}"; Flags: ignoreversion

; Deliberately no shortcuts, app launch or library/settings deletion.
