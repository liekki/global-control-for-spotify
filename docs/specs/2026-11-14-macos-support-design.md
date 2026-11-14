# macOS support — design

## Goal

Ship Spoco for macOS with the same promise as on Windows: global hotkeys that play/pause, skip and go back in Spotify from anywhere, always reaching Spotify even when another app owns the system media controls. Keep the project's character: tiny, native, no dependencies, built from a single source file.

Success: a user downloads `Spoco-macOS.zip` from the GitHub release, opens `Spoco.app`, approves the one-time "control Spotify" prompt, and Ctrl+Shift+C/B/Z control Spotify system-wide. Settings, start-at-login and hand-editable config work like on Windows.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Language/toolkit | Swift + AppKit, one file `Spoco.swift`, compiled by `swiftc` from `build.sh` | Mirrors `Spoco.cs` + `build.cmd`; no Xcode project or packages; builds on stock `macos-latest`. |
| Global hotkeys | Carbon `RegisterEventHotKey` | System-wide, no Accessibility permission, reports conflicts (`eventHotKeyExistsErr`) like `RegisterHotKey`. |
| Controlling Spotify | Apple Events via `NSAppleScript`: `playpause`, `next track`, `previous track` | Goes straight to Spotify regardless of who owns Now Playing. Sent only if Spotify is running (checked via `NSRunningApplication`, bundle id `com.spotify.client`), so hotkeys never launch it. Costs a one-time Automation prompt; `NSAppleEventsUsageDescription` explains it. |
| Default hotkeys | Ctrl+Shift+C / Ctrl+Shift+B / Ctrl+Shift+Z | Same as Windows (Winamp layout); Mac apps use Cmd, so these rarely collide. |
| Minimum OS | macOS 13 Ventura | Needed for `SMAppService` login items. |
| Architectures | Universal (arm64 + x86_64) | One download for all Macs; `swiftc -target` twice + `lipo`. |
| Distribution | Unsigned (ad-hoc signed by `codesign -s -`) `.app`, zipped with `ditto`, attached to the existing GitHub release | No Apple Developer account. README explains right-click → Open (or System Settings → Privacy & Security → Open Anyway). |

## Components (all in `Spoco.swift`)

- **`main`** — single instance: if another process with our bundle id is running, activate nothing and exit. Sets activation policy `.accessory` (also `LSUIElement` in Info.plist) and runs `NSApplication`. `--selftest` runs the self-tests and exits with status 0/1 before any UI is created.
- **`AppDelegate`** — owns the status item, hotkey registry, settings window and current config. `apply()` sets login item state, re-registers all hotkeys, rebuilds the menu and returns the labels that failed to register. On launch, failures are shown in an alert (no balloon equivalent worth the complexity).
- **Menu** — `Play/Pause`, `Next`, `Previous` (each shows its hotkey as text, e.g. `⌃⇧C`, or `(none)`; clicking sends the command), separator, `Settings…` (Cmd+,), `Start at Login` (checkmark toggle), separator, `Quit Spoco`.
- **Status item icon** — a template image drawn in code (a small play-triangle-in-circle glyph) so it adapts to light/dark menu bars.
- **`HotkeyCenter`** — wraps Carbon: installs one `kEventHotKeyPressed` handler on the application event target, `register(id:keyCode:modifiers:command:) -> Bool`, `unregisterAll()`. Dispatches pressed IDs to `Spotify.send`.
- **`Spotify`** — `enum Command { playPause, next, previous }`, `send(_:)`: no-op if Spotify isn't running; otherwise runs the AppleScript off the main thread so a slow or prompting Spotify never blocks the menu.
- **`SettingsWindow`** — `NSWindow` with an explanation label, three rows (label, `HotkeyField`, Clear), a "Start at Login" checkbox, and Defaults / Cancel / Save buttons (Save is default, Esc cancels when no field is recording). Hotkeys are unregistered while it is open and re-applied when it closes. Save rejects duplicates with an alert naming both actions. After closing, any hotkeys that failed to register are reported in an alert.
- **`HotkeyField`** — an `NSView` subclass that becomes first responder on click, draws a focus ring and the current hotkey text, and records via `keyDown`/`flagsChanged`. While modifiers are held it shows the partial combo (`Ctrl+Shift+`); on key-up without a key it reverts. A key without Ctrl/Option/Cmd is only accepted if it's an F-key (Shift alone is not enough, as on Windows Shift+letter would swallow capitals) — otherwise it shows "Add Ctrl, Option or Cmd". Tab moves focus normally.
- **`Config`** — load/save ini, parse/format hotkeys (below).
- **`LoginItem`** — `SMAppService.mainApp` `status == .enabled` / `register()` / `unregister()`; errors are ignored except that the menu checkmark reflects the real status.

## Config file

Path: `~/Library/Application Support/Spoco/Spoco.ini` (directory created on demand). Same line format as Windows (`;` comments, `Name=Value`, case-insensitive keys):

```ini
; Spoco hotkeys. Easiest to change from the menu bar icon: Settings...
; Modifiers: Ctrl, Option, Shift, Cmd. Leave empty to disable.
PlayPause=Ctrl+Shift+C
Next=Ctrl+Shift+B
Previous=Ctrl+Shift+Z

; true or false: launch Spoco when you log in.
StartAtLogin=true
```

- Missing file → defaults written out, `StartAtLogin` = current login-item status (false on first run).
- Missing key → default hotkey. Unparseable value → alert "Can't understand hotkey for X: …" and that action is disabled.
- No Play/Pause migration (that was for old Windows versions).

## Hotkey text format

- `Modifier+...+Key`, modifiers written in order `Ctrl`, `Option`, `Shift`, `Cmd`. Parsing is case-insensitive and accepts aliases `Control`, `Alt`, `Opt`, `Command`, `Win`.
- Key names: `A`–`Z`, `0`–`9`, `F1`–`F20`, `Space`, `Return`, `Tab`, `Escape`, `Delete`, `ForwardDelete`, `Home`, `End`, `PageUp`, `PageDown`, `Left`, `Right`, `Up`, `Down`, and punctuation `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave`. These map to ANSI virtual key codes (`kVK_*`), i.e. physical key positions, which is what `RegisterEventHotKey` uses. Keys outside this table can't be recorded (the field shows "Unsupported key").
- The menu shows the symbol form (`⌃⌥⇧⌘` + key, e.g. `⌃⇧C`) via `NSMenuItem` text, not a real key equivalent (a key equivalent would only fire when our menu is open and would confuse the display).

## Build (`build.sh`)

1. `swiftc -O` for `arm64-apple-macos13` and `x86_64-apple-macos13`, `lipo` into one binary.
2. Assemble `Spoco.app/Contents/{MacOS/Spoco, Info.plist, Resources/Spoco.icns}`. Info.plist: bundle id `io.github.liekki.spoco`, `LSUIElement`, `LSMinimumSystemVersion` 13.0, `NSAppleEventsUsageDescription`, version from `SPOCO_VERSION` env (default `0.0.0`).
3. Icon: `sips` resizes `docs/logo.png` into an `.iconset`, `iconutil` makes `Spoco.icns`.
4. `codesign --force --deep -s -` (ad-hoc; required for arm64 and for the Automation permission to stick across launches of the same build).
5. `ditto -c -k --keepParent Spoco.app dist/Spoco-macOS.zip`.

Build outputs (`Spoco.app`, `dist/`, intermediates under `build/`) are git-ignored.

## CI

`.github/workflows/release.yml` gains a `macos` job on `macos-latest`: checkout, `SPOCO_VERSION=<tag or 0.0.0> ./build.sh`, `Spoco.app/Contents/MacOS/Spoco --selftest`, upload `dist/Spoco-macOS.zip` as an artifact. Release publishing moves to a `release` job that `needs: [build, macos]`, downloads both artifacts and runs `gh release create` with all three files. Windows job keeps building and uploading as now.

## Error handling

- Spotify not running → command silently does nothing (same as Windows).
- Automation permission denied → AppleScript returns error -1743; the first time this happens per launch, show an alert explaining how to allow it in System Settings → Privacy & Security → Automation.
- Hotkey already taken → reported by label and text, at launch and after saving settings.
- Config write failure → alert with the error; in-memory settings still apply.

## Testing

- `--selftest`: parse/format round-trip for every key name and modifier combo, alias parsing, rejection of malformed text (`Ctrl+`, `Foo`, `C+Ctrl`), ini load of a sample with comments/missing/invalid keys, save→load round-trip to a temp file. Runs in CI.
- Manual on this machine: hotkeys control Spotify in foreground/background/hidden; no-op when Spotify is closed; settings recording, Clear, Defaults, duplicate rejection; conflict reporting (register a combo twice); start-at-login toggle reflected in System Settings; light/dark menu bar icon.

## README

Rename the intro to cover Windows and macOS; add a "macOS" section: download zip, move to Applications, first open via right-click → Open, the "control Spotify" prompt, defaults, config location, start at login, build with `./build.sh`. Note that `How it works` differs per platform.

## Out of scope

Signing/notarization, Homebrew cask, auto-update, media keys as hotkeys, sharing code between the C# and Swift versions.
