@echo off
rem Builds SpotifyGlobalHotkeys.exe with the C# compiler that ships with Windows (.NET Framework 4).
rem Set APP_VERSION to stamp a version (default 0.0.0, which never offers updates).
setlocal
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if "%APP_VERSION%"=="" set APP_VERSION=0.0.0
set VERSION_CS=%TEMP%\SpotifyGlobalHotkeysVersion.cs
> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyVersion("%APP_VERSION%")]
>> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyFileVersion("%APP_VERSION%")]
>> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyProduct("Spotify Global Hotkeys")]
"%CSC%" /nologo /r:System.Drawing.dll /out:"%TEMP%\SpotifyGlobalHotkeysMakeIcon.exe" MakeIcon.cs || exit /b 1
"%TEMP%\SpotifyGlobalHotkeysMakeIcon.exe" || exit /b 1
"%CSC%" /nologo /target:winexe /optimize /r:System.Web.Extensions.dll /win32icon:app.ico /resource:app.ico,app.ico /out:SpotifyGlobalHotkeys.exe SpotifyGlobalHotkeys.cs Jump.cs Update.cs "%VERSION_CS%" || exit /b 1
echo Built SpotifyGlobalHotkeys.exe (%APP_VERSION%)
