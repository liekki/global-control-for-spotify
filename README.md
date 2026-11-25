<p align="center">
  <img src="docs/logo.png" alt="Global Control for Spotify logo" width="128">
</p>

<h1 align="center">Global Control for Spotify</h1>

Global hotkeys for Spotify on Windows and macOS. Play/pause, skip and go back from anywhere — in a fullscreen game, a browser, a meeting — without switching to Spotify.

Global Control for Spotify is a tiny tray / menu bar app with no dependencies beyond what ships with the OS. This page covers Windows first; see [macOS](#macos) for the Mac version. It used to be called Spotify Global Hotkeys; see [Moving from Spotify Global Hotkeys](#moving-from-spotify-global-hotkeys).

[Code signing policy](CODE_SIGNING_POLICY.md)

## Download

Get the latest version from the [Releases page](https://github.com/liekki/global-control-for-spotify/releases/latest):

- **GlobalControlForSpotify.exe** — Windows. Run it and choose:
  - **Install** — installs for your user only (no admin prompt) to `%LOCALAPPDATA%\Programs\Global Control for Spotify`, adds a Start menu entry, and can start Global Control for Spotify when you log in. Remove it from Settings → Apps → Installed apps.
  - **Just run it from here** — portable. It runs from the folder it's in and saves its settings next to it in `GlobalControlForSpotify.ini` (and won't ask again). Put it in a folder of its own first.
- **GlobalControlForSpotify-macOS.zip** — the Mac app. See [macOS](#macos).

The Windows exe is code-signed by SignPath Foundation ([code signing policy](CODE_SIGNING_POLICY.md)). Releases before signing started may make Windows SmartScreen warn about an unrecognized app: choose **More info → Run anyway**, or [build it yourself](#building-from-source).

## Default hotkeys

| Action     | Hotkey          |
|------------|-----------------|
| Play/Pause | `Ctrl+Shift+C` |
| Next       | `Ctrl+Shift+B` |
| Previous   | `Ctrl+Shift+Z` |
| Jump       | `Ctrl+Shift+J` |
| Volume up / down | `Ctrl+Shift+PageUp` / `Ctrl+Shift+PageDown` |

Volume changes Spotify's own volume, not your system's: on Windows Spotify's slider in the volume mixer, in 5% steps (hold the keys to keep going); on macOS Spotify's volume slider, in steps of 10. It works without Jump's setup.

The play/pause, next and previous keys are Winamp's classic global hotkeys. Note that they take over the same keys in other apps while Global Control for Spotify is running — for example Redo (`Ctrl+Shift+Z`) in many editors, and the element inspector (`Ctrl+Shift+C`) and bookmarks bar (`Ctrl+Shift+B`) in Chrome and Edge. Change them in Settings if that gets in your way.

## Changing hotkeys

Double-click the tray icon (or right-click → **Settings...**), click the box for an action and press the keys you want. Changes apply as soon as you save.

- **Clear** disables an action. **Defaults** restores the hotkeys above.
- A key without Ctrl, Alt, Shift or Win is only accepted if it's an F-key, a media key, Pause or Scroll Lock — otherwise it would stop working in every other app.
- If another app already owns a combination, Global Control for Spotify tells you which one couldn't be registered.

Settings live in `GlobalControlForSpotify.ini` next to `GlobalControlForSpotify.exe`, which you can also edit by hand (restart Global Control for Spotify afterwards):

```ini
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z
Jump=Ctrl+Shift+J
VolumeUp=Ctrl+Shift+PageUp
VolumeDown=Ctrl+Shift+PageDown

; true or false: launch Global Control for Spotify when you log in to Windows.
StartWithWindows=true

; true or false: Global Control for Spotify starts Spotify with the debugging port Jump needs (127.0.0.1 only).
StartSpotify=false

; true or false: once a day, ask GitHub whether there's a new version (it's only installed when you choose).
CheckForUpdates=true
```

Key names are the .NET [`Keys`](https://learn.microsoft.com/dotnet/api/system.windows.forms.keys) names, such as `F9`, `Space`, `OemPeriod` or `MediaPlayPause`. Leave a value empty to disable that action.

## Start with Windows

Toggle it from the tray menu, the Settings window, or `StartWithWindows` in `GlobalControlForSpotify.ini`. Global Control for Spotify adds itself to your user's startup list (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), so no admin rights are needed.

## Updates

Once a day Global Control for Spotify asks GitHub for the latest release (one request to `api.github.com`; nothing about you or your music is sent). When there's a newer version, **Update to version …** appears at the top of the tray menu; nothing pops up and nothing installs until you click it. **Check for updates** in the menu checks right away. To turn the daily check off, untick it in Settings or set `CheckForUpdates=false`.

- **Windows:** clicking Update downloads the new exe next to the running one, swaps it in, and starts the new version; your settings, Jump history and autostart stay as they are. No admin prompt. This works for installed and portable copies alike; a copy in a folder it can't write to opens the release page instead.
- **Mac:** the same menu items. Update downloads the new app, replaces the one in Applications and reopens it. If the app runs from somewhere it can't replace itself (straight from Downloads), Update opens the release page instead. Because the Mac app isn't signed with an Apple Developer ID, macOS may ask again whether Global Control for Spotify may control Spotify after an update.

Updates come from this repository's GitHub releases over HTTPS, so an update is exactly as trustworthy as downloading it from the Releases page yourself.

Versions before 1.5.1 don't update themselves, and Spotify Global Hotkeys 1.5.1 can't update to Global Control for Spotify (it looks for the old file names and opens the release page instead): download the new version once by hand.

## Moving from Spotify Global Hotkeys

- **Windows, installed:** download `GlobalControlForSpotify.exe` and run it. The window offers to update the existing install: it stops the old app, carries over your settings, Jump history and autostart choice, and removes Spotify Global Hotkeys (its folder, shortcuts and Installed apps entry).
- **Windows, portable:** put `GlobalControlForSpotify.exe` in the old copy's folder and run it; it renames `SpotifyGlobalHotkeys.ini` and the history to the new names. Delete `SpotifyGlobalHotkeys.exe` afterwards.
- **Mac:** move `Global Control for Spotify.app` to Applications and open it. It quits the old app, moves its settings and history over, and moves `Spotify Global Hotkeys.app` from Applications to the Trash.

## Jump (Windows)

Winamp's **J** for Spotify, from anywhere: press `Ctrl+Shift+J`, type a few letters of a song you've played, press **Enter**, and Spotify plays it — continuing with the rest of its playlist, or of its album. Your game or app keeps focus.

What plays next: if you last played the song from one of your playlists (or Liked Songs), Jump plays it there, so that playlist carries on after it. A song you've never played from a playlist plays in the first playlist **Import playlists into Jump** found it in, and anything else in its album. Songs you queued yourself still come first, and shuffle and repeat work as usual. If the playlist no longer has the song, Jump falls back to the album.

- Global Control for Spotify remembers every song that plays for at least 20 seconds, with how often and how recently you played it (`GlobalControlForSpotify-history.tsv` next to `GlobalControlForSpotify.exe`; nothing leaves your PC). **Clear history...** in Settings forgets it.
- Type words in any order (`doors storm`); matched letters are highlighted. **↑/↓** pick, **Enter** plays, **Esc** closes, **Ctrl+R** switches between *Recent* and *Most played*.
- The last row, **Search Spotify for "…"**, plays Spotify's top song for what you typed, even if you've never played it.
- **Import playlists into Jump** (tray menu) adds every song in your playlists and Liked Songs, so Jump finds them before you've played them. They're listed below the songs you've actually played, with the playlist they came from ("in Liked Songs"); once you play one it becomes a normal entry. The import runs in the background and reads your playlists straight from Spotify, without touching its window — about ten seconds for 90 playlists and 12,000 songs — and running it again only adds what's new. The history has no size limit.

**Jump needs Spotify started by Global Control for Spotify.** It plays songs by running a little JavaScript inside Spotify's own app through Chromium's debugging port, which is the only way to do it without the Spotify Web API and without Spotify jumping in front of your game. The first time you open Jump it offers to restart Spotify that way (press Enter; the music pauses for a few seconds and carries on). To have Jump ready after every login, tick **Start Spotify with Jump support** in the install window or in Settings. Global Control for Spotify then starts Spotify with Jump support, and if Spotify's own autostart got there first, restarts it (only while it's freshly opened and not yet playing).

Good to know:

- The debugging port (`127.0.0.1:9229`) only accepts connections from programs on your own PC, not from websites. While it's open, any program running on your PC could control Spotify and read its session, so only use Jump on a computer you trust.
- Jump relies on how Spotify's app is built (button labels such as "Play Lions by Dire Straits"); a Spotify update can break it until Global Control for Spotify is updated. It needs Spotify from spotify.com, not the Microsoft Store version, and Spotify's interface in English.

## How it works (Windows)

Global Control for Spotify registers system-wide hotkeys with `RegisterHotKey` and sends the matching `WM_APPCOMMAND` straight to Spotify's window. Unlike the keyboard media keys, this always reaches Spotify, even when a browser tab or game has taken over Windows' media controls. It works whether Spotify is in the foreground, minimized or closed to the tray. If Spotify isn't running, the hotkeys do nothing.

## macOS

Requires macOS 13 (Ventura) or later, on Apple silicon or Intel.

1. Download **GlobalControlForSpotify-macOS.zip** from the [Releases page](https://github.com/liekki/global-control-for-spotify/releases/latest), unzip it and move **Global Control for Spotify.app** to Applications.
2. The app isn't notarized by Apple, so the first time, **right-click Global Control for Spotify.app → Open** and confirm. (On newer macOS versions, if there's no Open button: try to open it once, then go to System Settings → Privacy & Security and click **Open Anyway**.) Or [build it yourself](#building-on-macos).
3. Global Control for Spotify appears in the menu bar (no Dock icon). The first time Spotify plays while Global Control for Spotify runs (Jump checks what is playing), macOS asks whether Global Control for Spotify may control Spotify — choose **Allow**. If you said no, turn it back on in System Settings → Privacy & Security → Automation → Global Control for Spotify.

The default hotkeys are the same as on Windows: `⌃⇧C` (Ctrl+Shift+C) play/pause, `⌃⇧B` next, `⌃⇧Z` previous, `⌃⇧J` [Jump](#jump-macos), `⌃⇧⇞` / `⌃⇧⇟` (Ctrl+Shift+Page Up/Down) volume. Mac apps use Cmd for their shortcuts, so these rarely get in the way.

**Don't see the icon?** On MacBooks with a notch, macOS hides menu bar icons that don't fit to the left of the notch, and new apps are the first to go. Open Global Control for Spotify.app again (from Spotlight or Finder) to bring up its Settings. To make room, hide some icons you don't need (System Settings → Control Centre, or the other apps' own settings), or use a menu bar manager such as [Ice](https://github.com/jordanbaird/Ice). Once Global Control for Spotify is visible, ⌘-drag it further right so it stays visible.

Click the menu bar icon → **Settings…** to change them. Click a box and press the combination; it needs Ctrl, Option or Cmd unless it's an F-key. **Start at Login** is in the same menu and adds Global Control for Spotify to System Settings → General → Login Items.

Settings live in `~/Library/Application Support/Global Control for Spotify/GlobalControlForSpotify.ini` (restart Global Control for Spotify after editing by hand):

```ini
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z
Jump=Ctrl+Shift+J
VolumeUp=Ctrl+Shift+PageUp
VolumeDown=Ctrl+Shift+PageDown

; true or false: launch Global Control for Spotify when you log in.
StartAtLogin=true

; true or false: start Spotify with the debugging port Jump uses for albums, search and playlist import (127.0.0.1 only).
StartSpotify=false

; true or false: once a day, ask GitHub whether there's a new version (it's only installed when you choose).
CheckForUpdates=true
```

Modifiers are `Ctrl`, `Option`, `Shift` and `Cmd` (`Alt` and `Win` work too). Keys are letters, digits, `F1`–`F20`, `Space`, `Return`, `Tab`, `Escape`, `Delete`, `ForwardDelete`, `Home`, `End`, `PageUp`, `PageDown`, `Left`, `Right`, `Up`, `Down`, and `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave`. Letters mean the key's position on a US layout. Leave a value empty to disable that action.

### Jump (macOS)

Works like [Jump on Windows](#jump-windows): press `⌃⇧J`, type a few letters of a song you've played, press **Enter**. The app you're in stays in front; the popup takes your typing without switching apps.

- Songs are remembered after 20 seconds of play, in `~/Library/Application Support/Global Control for Spotify/GlobalControlForSpotify-history.tsv`. **Clear History…** in Settings forgets them.
- **↑/↓** (or **⌃N/⌃P**) pick, **Enter** plays, **Esc** closes, **⌃R** switches between *Recent* and *Most played*, **⌃U** clears.
- It works with Spotify as you normally start it: songs you've played are started through Spotify's AppleScript support (the same "control Spotify" permission the other hotkeys use), and continue with their playlist or album when Jump knows it, [as on Windows](#jump-windows).
- **Restart Spotify with Jump support** (menu bar menu), or **Start Spotify with Jump support** in Settings, starts Spotify with the same local debugging port as on Windows (`127.0.0.1:9229`, with the same caveat: any program on your Mac could control Spotify while it's open). With it, Jump also learns each song's album and the playlist you played it from, the **Search Spotify for "…"** row plays Spotify's top song (without it, that row just opens Spotify's search), and **Import playlists into Jump** adds the songs in your playlists and Liked Songs.

**How it works:** Global Control for Spotify registers system-wide hotkeys with Carbon's `RegisterEventHotKey` (no Accessibility permission needed) and sends Spotify's own `playpause`, `next track` and `previous track` commands as Apple Events, so they reach Spotify even when a browser owns the Mac's media controls. If Spotify isn't running, the hotkeys do nothing. macOS only reports a hotkey conflict when the other app also claimed the combination exclusively, so if a hotkey seems dead, another app or a system shortcut may have it.

## Building from source

Requires only Windows — it uses the C# compiler included with .NET Framework 4.

```bat
build.cmd
```

This draws the icon (`MakeIcon.cs` → `app.ico`) and compiles `GlobalControlForSpotify.exe`, which is also the installer. Set `APP_VERSION` (e.g. `set APP_VERSION=1.6.0`) to stamp a version; builds without one are 0.0.0 and never offer updates. `GlobalControlForSpotify.exe --selftest` runs the self-tests.

### Building on macOS

Requires the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh
```

This builds a universal `Global Control for Spotify.app` and `dist/GlobalControlForSpotify-macOS.zip`. `"Global Control for Spotify.app/Contents/MacOS/GlobalControlForSpotify" --selftest` checks hotkey parsing and the config file.

### Releasing

GitHub Actions builds the Windows and macOS versions on every push. Pushing a version tag publishes them as a release, stamped with that version (which is what the apps compare when they check for updates):

```bash
git tag v1.0.0
git push origin v1.0.0
```

Once SignPath is set up (repository variable `SIGNPATH_ORGANIZATION_ID`, secret `SIGNPATH_API_TOKEN`), the tagged build sends the exe to SignPath and waits up to an hour for the signing request to be approved there before publishing. The artifact configuration is in [`.signpath/artifact-configuration.xml`](.signpath/artifact-configuration.xml).

## License

[MIT](LICENSE). Global Control for Spotify is not affiliated with or endorsed by Spotify. Spotify is a trademark of Spotify AB.
