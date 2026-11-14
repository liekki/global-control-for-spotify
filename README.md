<p align="center">
  <img src="docs/logo.png" alt="Spoco logo" width="128">
</p>

<h1 align="center">Spoco</h1>

Global hotkeys for Spotify on Windows. Play/pause, skip and go back from anywhere — in a fullscreen game, a browser, a meeting — without switching to Spotify.

Spoco is a tiny tray app (about 100 KB) with no dependencies beyond what ships with Windows.

## Download

Get the latest version from the [Releases page](https://github.com/liekki/spoco/releases/latest):

- **SpocoSetup.exe** — installer. Installs for your user only (no admin prompt), adds a Start menu entry, and can start Spoco when you log in.
- **Spoco.exe** — portable. Put it in any folder and run it. Its settings are saved next to it in `Spoco.ini`.

Windows SmartScreen may warn about an unrecognized app the first time, since the binaries aren't code-signed. Choose **More info → Run anyway**, or [build it yourself](#building-from-source).

## Default hotkeys

| Action     | Hotkey          |
|------------|-----------------|
| Play/Pause | `Ctrl+Shift+C` |
| Next       | `Ctrl+Shift+B` |
| Previous   | `Ctrl+Shift+Z` |

These are Winamp's classic global hotkeys. Note that they take over the same keys in other apps while Spoco is running — for example Redo (`Ctrl+Shift+Z`) in many editors, and the element inspector (`Ctrl+Shift+C`) and bookmarks bar (`Ctrl+Shift+B`) in Chrome and Edge. Change them in Settings if that gets in your way.

## Changing hotkeys

Double-click the tray icon (or right-click → **Settings...**), click the box for an action and press the keys you want. Changes apply as soon as you save.

- **Clear** disables an action. **Defaults** restores the hotkeys above.
- A key without Ctrl, Alt, Shift or Win is only accepted if it's an F-key, a media key, Pause or Scroll Lock — otherwise it would stop working in every other app.
- If another app already owns a combination, Spoco tells you which one couldn't be registered.

Settings live in `Spoco.ini` next to `Spoco.exe`, which you can also edit by hand (restart Spoco afterwards):

```ini
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z

; true or false: launch Spoco when you log in to Windows.
StartWithWindows=true
```

Key names are the .NET [`Keys`](https://learn.microsoft.com/dotnet/api/system.windows.forms.keys) names, such as `F9`, `Space`, `OemPeriod` or `MediaPlayPause`. Leave a value empty to disable that action.

## Start with Windows

Toggle it from the tray menu, the Settings window, or `StartWithWindows` in `Spoco.ini`. Spoco adds itself to your user's startup list (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), so no admin rights are needed.

## How it works

Spoco registers system-wide hotkeys with `RegisterHotKey` and sends the matching `WM_APPCOMMAND` straight to Spotify's window. Unlike the keyboard media keys, this always reaches Spotify, even when a browser tab or game has taken over Windows' media controls. It works whether Spotify is in the foreground, minimized or closed to the tray. If Spotify isn't running, the hotkeys do nothing.

## Building from source

Requires only Windows — it uses the C# compiler included with .NET Framework 4.

```bat
build.cmd
```

This draws the icon (`MakeIcon.cs` → `Spoco.ico`) and compiles `Spoco.exe`. To build the installer, install [Inno Setup 6](https://jrsoftware.org/isinfo.php) and run:

```bat
"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 installer\Spoco.iss
```

The installer is written to `dist\SpocoSetup.exe`.

### Releasing

GitHub Actions builds both on every push. Pushing a version tag publishes them as a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

[MIT](LICENSE). Spoco is not affiliated with or endorsed by Spotify. Spotify is a trademark of Spotify AB.
