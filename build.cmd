@echo off
rem Builds SpotifyGlobalHotkeys.exe with the C# compiler that ships with Windows (.NET Framework 4).
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
"%CSC%" /nologo /r:System.Drawing.dll /out:"%TEMP%\SpotifyGlobalHotkeysMakeIcon.exe" MakeIcon.cs || exit /b 1
"%TEMP%\SpotifyGlobalHotkeysMakeIcon.exe" || exit /b 1
"%CSC%" /nologo /target:winexe /optimize /r:System.Web.Extensions.dll /win32icon:app.ico /resource:app.ico,app.ico /out:SpotifyGlobalHotkeys.exe SpotifyGlobalHotkeys.cs Jump.cs
