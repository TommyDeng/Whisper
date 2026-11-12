; 耳语 Whisper Windows 安装脚本
; 使用 Inno Setup 编译：iscc installer.iss

#define MyAppName "耳语 Whisper"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "TommyDeng"
#define MyAppURL "https://github.com/TommyDeng/Whisper"
#define MyAppExeName "whisper.exe"

[Setup]
AppId={{7A1F2B3C-4D5E-6F7A-8B9C-0D1E2F3A4B5C}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={pf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=packaging/windows/output
OutputBaseFilename=Whisper-Setup-{#MyAppVersion}-x64
Compression=lzma
SolidCompression=yes
PrivilegesRequired=low

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:LangSimpChinese.ini"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesanddirs; Dir: "{app}"
