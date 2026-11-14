; Inno Setup script for Spoco. Build Spoco.exe first (build.cmd), then:
;   iscc /DAppVersion=1.2.3 installer\Spoco.iss
; Installs per user (no admin prompt) to %LOCALAPPDATA%\Programs\Spoco.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6C1F3E0A-8B2D-4E7A-9F4C-2D5B7A1E9C33}
AppName=Spoco
AppVersion={#AppVersion}
AppVerName=Spoco {#AppVersion}
AppPublisher=Matti Vakkilainen
AppPublisherURL=https://github.com/liekki/spoco
AppSupportURL=https://github.com/liekki/spoco/issues
DefaultDirName={localappdata}\Programs\Spoco
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=SpocoSetup
SetupIconFile=..\Spoco.ico
UninstallDisplayIcon={app}\Spoco.exe
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "startup"; Description: "Start Spoco when I log in to Windows"
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\Spoco.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Spoco"; Filename: "{app}\Spoco.exe"
Name: "{autodesktop}\Spoco"; Filename: "{app}\Spoco.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Spoco.exe"; Description: "Start Spoco now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\Spoco.ini"

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

procedure StopSpoco;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im Spoco.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

// Spoco syncs autostart from Spoco.ini on launch. Dropping the setting there makes it
// adopt whatever the installer just chose, instead of undoing it.
procedure ForgetStartupSetting(Path: String);
var
  Lines, Kept: TArrayOfString;
  I, N: Integer;
begin
  if not LoadStringsFromFile(Path, Lines) then Exit;
  N := 0;
  SetArrayLength(Kept, GetArrayLength(Lines));
  for I := 0 to GetArrayLength(Lines) - 1 do
    if Pos('startwithwindows', Lowercase(Trim(Lines[I]))) <> 1 then
    begin
      Kept[N] := Lines[I];
      N := N + 1;
    end;
  SetArrayLength(Kept, N);
  SaveStringsToFile(Path, Kept, False);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopSpoco;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('startup') then
      RegWriteStringValue(HKCU, RunKey, 'Spoco', '"' + ExpandConstant('{app}\Spoco.exe') + '"')
    else
      RegDeleteValue(HKCU, RunKey, 'Spoco');
    ForgetStartupSetting(ExpandConstant('{app}\Spoco.ini'));
  end;
end;

function InitializeUninstall(): Boolean;
begin
  StopSpoco;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKCU, RunKey, 'Spoco');
end;
