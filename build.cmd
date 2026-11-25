@echo off
rem Builds GlobalControlForSpotify.exe with the C# compiler that ships with Windows (.NET Framework 4).
rem Set APP_VERSION to stamp a version (default 0.0.0, which never offers updates).
setlocal
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if "%APP_VERSION%"=="" set APP_VERSION=0.0.0
set VERSION_CS=%TEMP%\GlobalControlForSpotifyVersion.cs
> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyVersion("%APP_VERSION%")]
>> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyFileVersion("%APP_VERSION%")]
>> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyInformationalVersion("%APP_VERSION%")]
>> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyProduct("Global Control for Spotify")]
>> "%VERSION_CS%" echo [assembly: System.Reflection.AssemblyTitle("Global Control for Spotify")]
"%CSC%" /nologo /r:System.Drawing.dll /out:"%TEMP%\GlobalControlForSpotifyMakeIcon.exe" MakeIcon.cs || exit /b 1
"%TEMP%\GlobalControlForSpotifyMakeIcon.exe" || exit /b 1
"%CSC%" /nologo /target:winexe /optimize /r:System.Web.Extensions.dll /win32icon:app.ico /resource:app.ico,app.ico /out:GlobalControlForSpotify.exe GlobalControlForSpotify.cs Jump.cs Update.cs Install.cs "%VERSION_CS%" || exit /b 1
echo Built GlobalControlForSpotify.exe (%APP_VERSION%)
