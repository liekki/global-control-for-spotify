<p align="center">
  <img src="docs/logo.png" alt="Spoco logo" width="128">
</p>

<h1 align="center">Spoco</h1>

Global hotkeys for Spotify on Windows and macOS. Play/pause, skip and go back from anywhere — in a fullscreen game, a browser, a meeting — without switching to Spotify.

Spoco is a tiny tray / menu bar app with no dependencies beyond what ships with the OS. This page covers Windows first; see [macOS](#macos) for the Mac version.

## Download

Get the latest version from the [Releases page](https://github.com/liekki/spoco/releases/latest):

- **SpocoSetup.exe** — installer. Installs for your user only (no admin prompt), adds a Start menu entry, and can start Spoco when you log in.
- **Spoco.exe** — portable. Put it in any folder and run it. Its settings are saved next to it in `Spoco.ini`.
- **Spoco-macOS.zip** — the Mac app. See [macOS](#macos).

Windows SmartScreen may warn about an unrecognized app the first time, since the binaries aren't code-signed. Choose **More info → Run anyway**, or [build it yourself](#building-from-source).

## Default hotkeys

| Action     | Hotkey          |
|------------|-----------------|
| Play/Pause | `Ctrl+Shift+C` |
| Next       | `Ctrl+Shift+B` |
| Previous   | `Ctrl+Shift+Z` |
| Jump       | `Ctrl+Shift+J` |

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
Jump=Ctrl+Shift+J

; true or false: launch Spoco when you log in to Windows.
StartWithWindows=true

; true or false: Spoco starts Spotify with the debugging port Jump needs (127.0.0.1 only).
StartSpotify=false
```

Key names are the .NET [`Keys`](https://learn.microsoft.com/dotnet/api/system.windows.forms.keys) names, such as `F9`, `Space`, `OemPeriod` or `MediaPlayPause`. Leave a value empty to disable that action.

## Start with Windows

Toggle it from the tray menu, the Settings window, or `StartWithWindows` in `Spoco.ini`. Spoco adds itself to your user's startup list (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), so no admin rights are needed.

## Jump (Windows)

Winamp's **J** for Spotify, from anywhere: press `Ctrl+Shift+J`, type a few letters of a song you've played, press **Enter**, and Spotify plays it — continuing with the rest of its album. Your game or app keeps focus.

- Spoco remembers every song that plays for at least 20 seconds, with how often and how recently you played it (`SpocoHistory.tsv` next to `Spoco.exe`; nothing leaves your PC). **Clear history...** in Settings forgets it.
- Type words in any order (`doors storm`); matched letters are highlighted. **↑/↓** pick, **Enter** plays, **Esc** closes, **Ctrl+R** switches between *Recent* and *Most played*.
- The last row, **Search Spotify for "…"**, plays Spotify's top song for what you typed, even if you've never played it.
- **Import playlists into Jump** (tray menu) adds every song in your playlists and Liked Songs, so Jump finds them before you've played them. They're listed below the songs you've actually played, with the playlist they came from ("in Liked Songs"); once you play one it becomes a normal entry. The import runs in the background — about a minute and a half for 80 playlists and 3,500 songs — and running it again only adds what's new. If Spotify is minimized or in the tray, Spoco briefly moves its window off-screen (it has to be rendered for the lists to load) and then puts it back exactly as it was. The history has no size limit.

**Jump needs Spotify started by Spoco.** It plays songs by running a little JavaScript inside Spotify's own app through Chromium's debugging port, which is the only way to do it without the Spotify Web API and without Spotify jumping in front of your game. The first time you open Jump it offers to restart Spotify that way (press Enter; the music pauses for a few seconds and carries on). To have Spoco start Spotify for you every time, tick **Start Spotify with Jump support** in Settings and turn off Spotify's own *Settings → Startup and window behaviour → Open Spotify automatically after you log into the computer*.

Good to know:

- The debugging port (`127.0.0.1:9229`) only accepts connections from programs on your own PC, not from websites. While it's open, any program running on your PC could control Spotify and read its session, so only use Jump on a computer you trust.
- Jump relies on how Spotify's app is built (button labels such as "Play Lions by Dire Straits"); a Spotify update can break it until Spoco is updated. It needs Spotify from spotify.com, not the Microsoft Store version, and Spotify's interface in English.

## How it works (Windows)

Spoco registers system-wide hotkeys with `RegisterHotKey` and sends the matching `WM_APPCOMMAND` straight to Spotify's window. Unlike the keyboard media keys, this always reaches Spotify, even when a browser tab or game has taken over Windows' media controls. It works whether Spotify is in the foreground, minimized or closed to the tray. If Spotify isn't running, the hotkeys do nothing.

## macOS

Requires macOS 13 (Ventura) or later, on Apple silicon or Intel.

1. Download **Spoco-macOS.zip** from the [Releases page](https://github.com/liekki/spoco/releases/latest), unzip it and move **Spoco.app** to Applications.
2. The app isn't notarized by Apple, so the first time, **right-click Spoco.app → Open** and confirm. (On newer macOS versions, if there's no Open button: try to open it once, then go to System Settings → Privacy & Security and click **Open Anyway**.) Or [build it yourself](#building-on-macos).
3. Spoco appears in the menu bar (no Dock icon). The first time you press a hotkey while Spotify is running, macOS asks whether Spoco may control Spotify — choose **Allow**. If you said no, turn it back on in System Settings → Privacy & Security → Automation → Spoco.

The default hotkeys are the same as on Windows: `⌃⇧C` (Ctrl+Shift+C) play/pause, `⌃⇧B` next, `⌃⇧Z` previous. Mac apps use Cmd for their shortcuts, so these rarely get in the way.

**Don't see the icon?** On MacBooks with a notch, macOS hides menu bar icons that don't fit to the left of the notch, and new apps are the first to go. Open Spoco.app again (from Spotlight or Finder) to bring up its Settings. To make room, hide some icons you don't need (System Settings → Control Centre, or the other apps' own settings), or use a menu bar manager such as [Ice](https://github.com/jordanbaird/Ice). Once Spoco is visible, ⌘-drag it further right so it stays visible.

Click the menu bar icon → **Settings…** to change them. Click a box and press the combination; it needs Ctrl, Option or Cmd unless it's an F-key. **Start at Login** is in the same menu and adds Spoco to System Settings → General → Login Items.

Settings live in `~/Library/Application Support/Spoco/Spoco.ini` (restart Spoco after editing by hand):

```ini
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z

; true or false: launch Spoco when you log in.
StartAtLogin=true
```

Modifiers are `Ctrl`, `Option`, `Shift` and `Cmd` (`Alt` and `Win` work too). Keys are letters, digits, `F1`–`F20`, `Space`, `Return`, `Tab`, `Escape`, `Delete`, `ForwardDelete`, `Home`, `End`, `PageUp`, `PageDown`, `Left`, `Right`, `Up`, `Down`, and `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave`. Letters mean the key's position on a US layout. Leave a value empty to disable that action.

**How it works:** Spoco registers system-wide hotkeys with Carbon's `RegisterEventHotKey` (no Accessibility permission needed) and sends Spotify's own `playpause`, `next track` and `previous track` commands as Apple Events, so they reach Spotify even when a browser owns the Mac's media controls. If Spotify isn't running, the hotkeys do nothing. macOS only reports a hotkey conflict when the other app also claimed the combination exclusively, so if a hotkey seems dead, another app or a system shortcut may have it.

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

### Building on macOS

Requires the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh
```

This builds a universal `Spoco.app` and `dist/Spoco-macOS.zip`. `Spoco.app/Contents/MacOS/Spoco --selftest` checks hotkey parsing and the config file.

### Releasing

GitHub Actions builds the Windows and macOS versions on every push. Pushing a version tag publishes them as a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

[MIT](LICENSE). Spoco is not affiliated with or endorsed by Spotify. Spotify is a trademark of Spotify AB.
