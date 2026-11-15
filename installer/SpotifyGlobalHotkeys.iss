; Inno Setup script for Spotify Global Hotkeys. Build SpotifyGlobalHotkeys.exe first (build.cmd), then:
;   iscc /DAppVersion=1.2.3 installer\SpotifyGlobalHotkeys.iss
; Installs per user (no admin prompt) to %LOCALAPPDATA%\Programs\Spotify Global Hotkeys.
; The AppId is unchanged from the app's old name, so installing over an old version upgrades it in place.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6C1F3E0A-8B2D-4E7A-9F4C-2D5B7A1E9C33}
AppName=Spotify Global Hotkeys
AppVersion={#AppVersion}
AppVerName=Spotify Global Hotkeys {#AppVersion}
AppPublisher=Matti Vakkilainen
AppPublisherURL=https://github.com/liekki/spotify-global-hotkeys
AppSupportURL=https://github.com/liekki/spotify-global-hotkeys/issues
DefaultDirName={localappdata}\Programs\Spotify Global Hotkeys
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=SpotifyGlobalHotkeysSetup
SetupIconFile=..\app.ico
UninstallDisplayIcon={app}\SpotifyGlobalHotkeys.exe
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "startup"; Description: "Start Spotify Global Hotkeys when I log in to Windows"
Name: "jump"; Description: "Start Spotify with Jump support (opens a debugging port on 127.0.0.1 that programs on this PC can use to control Spotify)"; Flags: unchecked
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[InstallDelete]
; Left over from the app's old name
Type: files; Name: "{app}\Spoco.exe"
Type: files; Name: "{autoprograms}\Spoco.lnk"
Type: files; Name: "{autodesktop}\Spoco.lnk"

[Files]
Source: "..\SpotifyGlobalHotkeys.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Spotify Global Hotkeys"; Filename: "{app}\SpotifyGlobalHotkeys.exe"
Name: "{autodesktop}\Spotify Global Hotkeys"; Filename: "{app}\SpotifyGlobalHotkeys.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SpotifyGlobalHotkeys.exe"; Description: "Start Spotify Global Hotkeys now"; Flags: nowait postinstall skipifsilent
; The app's own updater runs this setup with /VERYSILENT /UPDATE and has quit by now: start the new version.
Filename: "{app}\SpotifyGlobalHotkeys.exe"; Flags: nowait; Check: IsUpdate

[UninstallDelete]
Type: files; Name: "{app}\SpotifyGlobalHotkeys.ini"
Type: files; Name: "{app}\SpotifyGlobalHotkeys-history.tsv"
Type: files; Name: "{app}\SpotifyGlobalHotkeys-history.tsv.tmp"
Type: files; Name: "{app}\Spoco.ini"
Type: files; Name: "{app}\SpocoHistory.tsv"

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

// Started by the app's "Update to version ..." (with /VERYSILENT /UPDATE).
function IsUpdate: Boolean;
begin
  Result := WizardSilent and (Pos('/UPDATE', Uppercase(GetCmdTail)) > 0);
end;

procedure StopApp;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im SpotifyGlobalHotkeys.exe /im Spoco.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

// Carry settings and history saved under the old name over, like the app itself does on first start, so the
// installer's choices below land in the file the app will read.
procedure MigrateFromOldName;
begin
  if FileExists(ExpandConstant('{app}\Spoco.ini')) and not FileExists(ExpandConstant('{app}\SpotifyGlobalHotkeys.ini')) then
    RenameFile(ExpandConstant('{app}\Spoco.ini'), ExpandConstant('{app}\SpotifyGlobalHotkeys.ini'));
  if FileExists(ExpandConstant('{app}\SpocoHistory.tsv')) and not FileExists(ExpandConstant('{app}\SpotifyGlobalHotkeys-history.tsv')) then
    RenameFile(ExpandConstant('{app}\SpocoHistory.tsv'), ExpandConstant('{app}\SpotifyGlobalHotkeys-history.tsv'));
end;

// The app syncs autostart from its .ini on launch. Dropping StartWithWindows there makes it
// adopt whatever the installer just chose, instead of undoing it. StartSpotify is set to the
// installer's choice (the app fills in everything else on its next start).
procedure WriteSettings(Path: String; StartSpotify: Boolean);
var
  Lines, Kept: TArrayOfString;
  I, N: Integer;
  Line: String;
begin
  if not LoadStringsFromFile(Path, Lines) then SetArrayLength(Lines, 0);
  N := 0;
  SetArrayLength(Kept, GetArrayLength(Lines) + 1);
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Lowercase(Trim(Lines[I]));
    if (Pos('startwithwindows', Line) <> 1) and (Pos('startspotify', Line) <> 1) then
    begin
      Kept[N] := Lines[I];
      N := N + 1;
    end;
  end;
  if StartSpotify then Kept[N] := 'StartSpotify=true' else Kept[N] := 'StartSpotify=false';
  SetArrayLength(Kept, N + 1);
  SaveStringsToFile(Path, Kept, False);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopApp;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // An update keeps the settings the app has now (they may have changed since this setup last ran).
  if (CurStep = ssPostInstall) and not IsUpdate then
  begin
    RegDeleteValue(HKCU, RunKey, 'Spoco');
    if WizardIsTaskSelected('startup') then
      RegWriteStringValue(HKCU, RunKey, 'SpotifyGlobalHotkeys', '"' + ExpandConstant('{app}\SpotifyGlobalHotkeys.exe') + '"')
    else
      RegDeleteValue(HKCU, RunKey, 'SpotifyGlobalHotkeys');
    MigrateFromOldName;
    WriteSettings(ExpandConstant('{app}\SpotifyGlobalHotkeys.ini'), WizardIsTaskSelected('jump'));
  end;
end;

function InitializeUninstall(): Boolean;
begin
  StopApp;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKCU, RunKey, 'SpotifyGlobalHotkeys');
    RegDeleteValue(HKCU, RunKey, 'Spoco');
  end;
end;
