<p align="center">
  <img src="docs/logo.png" alt="Spotify Global Hotkeys logo" width="128">
</p>

<h1 align="center">Spotify Global Hotkeys</h1>

Global hotkeys for Spotify on Windows and macOS. Play/pause, skip and go back from anywhere — in a fullscreen game, a browser, a meeting — without switching to Spotify.

Spotify Global Hotkeys is a tiny tray / menu bar app with no dependencies beyond what ships with the OS. This page covers Windows first; see [macOS](#macos) for the Mac version.

## Download

Get the latest version from the [Releases page](https://github.com/liekki/spotify-global-hotkeys/releases/latest):

- **SpotifyGlobalHotkeysSetup.exe** — installer. Installs for your user only (no admin prompt), adds a Start menu entry, and can start Spotify Global Hotkeys when you log in.
- **SpotifyGlobalHotkeys.exe** — portable. Put it in any folder and run it. Its settings are saved next to it in `SpotifyGlobalHotkeys.ini`.
- **SpotifyGlobalHotkeys-macOS.zip** — the Mac app. See [macOS](#macos).

Windows SmartScreen may warn about an unrecognized app the first time, since the binaries aren't code-signed. Choose **More info → Run anyway**, or [build it yourself](#building-from-source).

## Default hotkeys

| Action     | Hotkey          |
|------------|-----------------|
| Play/Pause | `Ctrl+Shift+C` |
| Next       | `Ctrl+Shift+B` |
| Previous   | `Ctrl+Shift+Z` |
| Jump       | `Ctrl+Shift+J` |
| Volume up / down | `Ctrl+Shift+PageUp` / `Ctrl+Shift+PageDown` |

Volume changes Spotify's own volume, not your system's: on Windows Spotify's slider in the volume mixer, in 5% steps (hold the keys to keep going); on macOS Spotify's volume slider, in steps of 10. It works without Jump's setup.

The play/pause, next and previous keys are Winamp's classic global hotkeys. Note that they take over the same keys in other apps while Spotify Global Hotkeys is running — for example Redo (`Ctrl+Shift+Z`) in many editors, and the element inspector (`Ctrl+Shift+C`) and bookmarks bar (`Ctrl+Shift+B`) in Chrome and Edge. Change them in Settings if that gets in your way.

## Changing hotkeys

Double-click the tray icon (or right-click → **Settings...**), click the box for an action and press the keys you want. Changes apply as soon as you save.

- **Clear** disables an action. **Defaults** restores the hotkeys above.
- A key without Ctrl, Alt, Shift or Win is only accepted if it's an F-key, a media key, Pause or Scroll Lock — otherwise it would stop working in every other app.
- If another app already owns a combination, Spotify Global Hotkeys tells you which one couldn't be registered.

Settings live in `SpotifyGlobalHotkeys.ini` next to `SpotifyGlobalHotkeys.exe`, which you can also edit by hand (restart Spotify Global Hotkeys afterwards):

```ini
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z
Jump=Ctrl+Shift+J
VolumeUp=Ctrl+Shift+PageUp
VolumeDown=Ctrl+Shift+PageDown

; true or false: launch Spotify Global Hotkeys when you log in to Windows.
StartWithWindows=true

; true or false: Spotify Global Hotkeys starts Spotify with the debugging port Jump needs (127.0.0.1 only).
StartSpotify=false

; true or false: once a day, ask GitHub whether there's a new version (it's only installed when you choose).
CheckForUpdates=true
```

Key names are the .NET [`Keys`](https://learn.microsoft.com/dotnet/api/system.windows.forms.keys) names, such as `F9`, `Space`, `OemPeriod` or `MediaPlayPause`. Leave a value empty to disable that action.

## Start with Windows

Toggle it from the tray menu, the Settings window, or `StartWithWindows` in `SpotifyGlobalHotkeys.ini`. Spotify Global Hotkeys adds itself to your user's startup list (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), so no admin rights are needed.

## Updates

Once a day Spotify Global Hotkeys asks GitHub for the latest release (one request to `api.github.com`; nothing about you or your music is sent). When there's a newer version, **Update to version …** appears at the top of the tray menu; nothing pops up and nothing installs until you click it. **Check for updates** in the menu checks right away. To turn the daily check off, untick it in Settings or set `CheckForUpdates=false`.

- **Installed with the setup:** clicking Update downloads the new setup, quits, installs it in place (your settings, Jump history and autostart stay as they are) and starts the new version. No admin prompt.
- **Portable copy:** Update opens the release page instead, so you can replace the exe yourself.
- **Mac:** the same menu items. Update downloads the new app, replaces the one in Applications and reopens it. If the app runs from somewhere it can't replace itself (straight from Downloads), Update opens the release page instead. Because the Mac app isn't signed with an Apple Developer ID, macOS may ask again whether Spotify Global Hotkeys may control Spotify after an update.

Updates come from this repository's GitHub releases over HTTPS. The builds aren't code-signed, so an update is exactly as trustworthy as downloading it from the Releases page yourself.

Versions before 1.6.0 don't update themselves: install 1.6.0 or later once by hand.

## Jump (Windows)

Winamp's **J** for Spotify, from anywhere: press `Ctrl+Shift+J`, type a few letters of a song you've played, press **Enter**, and Spotify plays it — continuing with the rest of its playlist, or of its album. Your game or app keeps focus.

What plays next: if you last played the song from one of your playlists (or Liked Songs), Jump plays it there, so that playlist carries on after it. A song you've never played from a playlist plays in the first playlist **Import playlists into Jump** found it in, and anything else in its album. Songs you queued yourself still come first, and shuffle and repeat work as usual. If the playlist no longer has the song, Jump falls back to the album.

- Spotify Global Hotkeys remembers every song that plays for at least 20 seconds, with how often and how recently you played it (`SpotifyGlobalHotkeys-history.tsv` next to `SpotifyGlobalHotkeys.exe`; nothing leaves your PC). **Clear history...** in Settings forgets it.
- Type words in any order (`doors storm`); matched letters are highlighted. **↑/↓** pick, **Enter** plays, **Esc** closes, **Ctrl+R** switches between *Recent* and *Most played*.
- The last row, **Search Spotify for "…"**, plays Spotify's top song for what you typed, even if you've never played it.
- **Import playlists into Jump** (tray menu) adds every song in your playlists and Liked Songs, so Jump finds them before you've played them. They're listed below the songs you've actually played, with the playlist they came from ("in Liked Songs"); once you play one it becomes a normal entry. The import runs in the background and reads your playlists straight from Spotify, without touching its window — about ten seconds for 90 playlists and 12,000 songs — and running it again only adds what's new. The history has no size limit.

**Jump needs Spotify started by Spotify Global Hotkeys.** It plays songs by running a little JavaScript inside Spotify's own app through Chromium's debugging port, which is the only way to do it without the Spotify Web API and without Spotify jumping in front of your game. The first time you open Jump it offers to restart Spotify that way (press Enter; the music pauses for a few seconds and carries on). To have Jump ready after every login, tick **Start Spotify with Jump support** in the installer or in Settings. Spotify Global Hotkeys then starts Spotify with Jump support, and if Spotify's own autostart got there first, restarts it (only while it's freshly opened and not yet playing).

Good to know:

- The debugging port (`127.0.0.1:9229`) only accepts connections from programs on your own PC, not from websites. While it's open, any program running on your PC could control Spotify and read its session, so only use Jump on a computer you trust.
- Jump relies on how Spotify's app is built (button labels such as "Play Lions by Dire Straits"); a Spotify update can break it until Spotify Global Hotkeys is updated. It needs Spotify from spotify.com, not the Microsoft Store version, and Spotify's interface in English.

## How it works (Windows)

Spotify Global Hotkeys registers system-wide hotkeys with `RegisterHotKey` and sends the matching `WM_APPCOMMAND` straight to Spotify's window. Unlike the keyboard media keys, this always reaches Spotify, even when a browser tab or game has taken over Windows' media controls. It works whether Spotify is in the foreground, minimized or closed to the tray. If Spotify isn't running, the hotkeys do nothing.

## macOS

Requires macOS 13 (Ventura) or later, on Apple silicon or Intel.

1. Download **SpotifyGlobalHotkeys-macOS.zip** from the [Releases page](https://github.com/liekki/spotify-global-hotkeys/releases/latest), unzip it and move **Spotify Global Hotkeys.app** to Applications.
2. The app isn't notarized by Apple, so the first time, **right-click Spotify Global Hotkeys.app → Open** and confirm. (On newer macOS versions, if there's no Open button: try to open it once, then go to System Settings → Privacy & Security and click **Open Anyway**.) Or [build it yourself](#building-on-macos).
3. Spotify Global Hotkeys appears in the menu bar (no Dock icon). The first time Spotify plays while Spotify Global Hotkeys runs (Jump checks what is playing), macOS asks whether Spotify Global Hotkeys may control Spotify — choose **Allow**. If you said no, turn it back on in System Settings → Privacy & Security → Automation → Spotify Global Hotkeys.

The default hotkeys are the same as on Windows: `⌃⇧C` (Ctrl+Shift+C) play/pause, `⌃⇧B` next, `⌃⇧Z` previous, `⌃⇧J` [Jump](#jump-macos), `⌃⇧⇞` / `⌃⇧⇟` (Ctrl+Shift+Page Up/Down) volume. Mac apps use Cmd for their shortcuts, so these rarely get in the way.

**Don't see the icon?** On MacBooks with a notch, macOS hides menu bar icons that don't fit to the left of the notch, and new apps are the first to go. Open Spotify Global Hotkeys.app again (from Spotlight or Finder) to bring up its Settings. To make room, hide some icons you don't need (System Settings → Control Centre, or the other apps' own settings), or use a menu bar manager such as [Ice](https://github.com/jordanbaird/Ice). Once Spotify Global Hotkeys is visible, ⌘-drag it further right so it stays visible.

Click the menu bar icon → **Settings…** to change them. Click a box and press the combination; it needs Ctrl, Option or Cmd unless it's an F-key. **Start at Login** is in the same menu and adds Spotify Global Hotkeys to System Settings → General → Login Items.

Settings live in `~/Library/Application Support/Spotify Global Hotkeys/SpotifyGlobalHotkeys.ini` (restart Spotify Global Hotkeys after editing by hand):

```ini
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z
Jump=Ctrl+Shift+J
VolumeUp=Ctrl+Shift+PageUp
VolumeDown=Ctrl+Shift+PageDown

; true or false: launch Spotify Global Hotkeys when you log in.
StartAtLogin=true

; true or false: start Spotify with the debugging port Jump uses for albums, search and playlist import (127.0.0.1 only).
StartSpotify=false

; true or false: once a day, ask GitHub whether there's a new version (it's only installed when you choose).
CheckForUpdates=true
```

Modifiers are `Ctrl`, `Option`, `Shift` and `Cmd` (`Alt` and `Win` work too). Keys are letters, digits, `F1`–`F20`, `Space`, `Return`, `Tab`, `Escape`, `Delete`, `ForwardDelete`, `Home`, `End`, `PageUp`, `PageDown`, `Left`, `Right`, `Up`, `Down`, and `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave`. Letters mean the key's position on a US layout. Leave a value empty to disable that action.

### Jump (macOS)

Works like [Jump on Windows](#jump-windows): press `⌃⇧J`, type a few letters of a song you've played, press **Enter**. The app you're in stays in front; the popup takes your typing without switching apps.

- Songs are remembered after 20 seconds of play, in `~/Library/Application Support/Spotify Global Hotkeys/SpotifyGlobalHotkeys-history.tsv`. **Clear History…** in Settings forgets them.
- **↑/↓** (or **⌃N/⌃P**) pick, **Enter** plays, **Esc** closes, **⌃R** switches between *Recent* and *Most played*, **⌃U** clears.
- It works with Spotify as you normally start it: songs you've played are started through Spotify's AppleScript support (the same "control Spotify" permission the other hotkeys use), and continue with their playlist or album when Jump knows it, [as on Windows](#jump-windows).
- **Restart Spotify with Jump support** (menu bar menu), or **Start Spotify with Jump support** in Settings, starts Spotify with the same local debugging port as on Windows (`127.0.0.1:9229`, with the same caveat: any program on your Mac could control Spotify while it's open). With it, Jump also learns each song's album and the playlist you played it from, the **Search Spotify for "…"** row plays Spotify's top song (without it, that row just opens Spotify's search), and **Import playlists into Jump** adds the songs in your playlists and Liked Songs.

**How it works:** Spotify Global Hotkeys registers system-wide hotkeys with Carbon's `RegisterEventHotKey` (no Accessibility permission needed) and sends Spotify's own `playpause`, `next track` and `previous track` commands as Apple Events, so they reach Spotify even when a browser owns the Mac's media controls. If Spotify isn't running, the hotkeys do nothing. macOS only reports a hotkey conflict when the other app also claimed the combination exclusively, so if a hotkey seems dead, another app or a system shortcut may have it.

## Building from source

Requires only Windows — it uses the C# compiler included with .NET Framework 4.

```bat
build.cmd
```

This draws the icon (`MakeIcon.cs` → `app.ico`) and compiles `SpotifyGlobalHotkeys.exe`. Set `APP_VERSION` (e.g. `set APP_VERSION=1.6.0`) to stamp a version; builds without one are 0.0.0 and never offer updates. To build the installer, install [Inno Setup 6](https://jrsoftware.org/isinfo.php) and run:

```bat
"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 installer\SpotifyGlobalHotkeys.iss
```

The installer is written to `dist\SpotifyGlobalHotkeysSetup.exe`.

### Building on macOS

Requires the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh
```

This builds a universal `Spotify Global Hotkeys.app` and `dist/SpotifyGlobalHotkeys-macOS.zip`. `"Spotify Global Hotkeys.app/Contents/MacOS/SpotifyGlobalHotkeys" --selftest` checks hotkey parsing and the config file.

### Releasing

GitHub Actions builds the Windows and macOS versions on every push. Pushing a version tag publishes them as a release, stamped with that version (which is what the apps compare when they check for updates):

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

[MIT](LICENSE). Spotify Global Hotkeys is not affiliated with or endorsed by Spotify. Spotify is a trademark of Spotify AB.
