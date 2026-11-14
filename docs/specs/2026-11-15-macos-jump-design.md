# Jump on macOS — design

Ports Jump (see `2026-11-14-global-jump-design.md`) to the Mac app. This replaces that document's "macOS details" section. The popup behaviour, history format, ranking and config key stay as specified there, except where this document says otherwise.

## Goal

The same experience as on Windows: press `⌃⇧J` anywhere, type a few letters of a song, press Enter, and Spotify plays it without coming to the front. On the Mac this should work **without restarting Spotify**. Album continuation, "Search Spotify" that plays a result, and playlist import work too, once Spotify has been started with Jump support.

Success:
- With a normally started Spotify, `⌃⇧J` → `sult` → Enter plays "Sultans Of Swing" within about a second, continuing with its album whenever the album is known.
- The app you were in stays active the whole time.

## Approach: hybrid

| Capability | AppleScript (always) | Debugging port (when Spotify was started with it) |
|---|---|---|
| Record songs | `id`, `name`, `artist`, `album` of `current track` | adds the album link from the now-playing widget |
| Play a song with a track ID | `play track "<track>" in context "<album>"` | — |
| Play a song without a track ID | — | album page → click row; else search → click row |
| Search row | opens `spotify:search:<text>` (brings Spotify to front) | plays the top song result |
| Import playlists | — | same as Windows |

Why hybrid: AppleScript already covers recording and playback by ID, with the Automation permission the app already has, so Jump is useful from the first press. The port adds what AppleScript can't do. The port's page script is a copy of the Windows one, so its behaviour and its breakage risk are shared.

## Code layout

- New `Jump.swift`, next to `SpotifyGlobalHotkeys.swift`, holding history, ranking, recorder, popup, page connection, launcher, import and player. `build.sh` passes both files to `swiftc`.
- With two files, top-level code is no longer allowed outside `main.swift`, so the startup code at the bottom of `SpotifyGlobalHotkeys.swift` moves into a `@main enum Main { static func main() }`.
- `Action` gains `.jump` (`Jump`, label "Jump", default `Ctrl+Shift+J`). It isn't an Apple Event: `AppDelegate` routes it to the popup instead of `Spotify.send`.

## History

- File: `~/Library/Application Support/Spotify Global Hotkeys/SpotifyGlobalHotkeys-history.tsv`. Same 7 tab-separated columns, UTF-8, newest first, unplayed imports last: `lastPlayed, count, title, artist, album, link, playlist`.
- `link` on macOS holds zero, one or two space-separated URIs: `spotify:track:<id>` and/or `spotify:album:<id>`. Helpers parse out `trackURI` and `albumURI`. When a song is recorded or imported again, known URIs are merged, never dropped.
- Identity: case-insensitive title + artist + album, as on Windows. Unlike Windows, the Mac records the album name (AppleScript gives it), and the import reads the album name from each row's album link text, so recorded and imported copies of a song have the same identity.
- Saved at most every 30 s (off the main thread) and on quit, by writing a temp file and atomically replacing the original. A corrupt line is skipped on load.
- Ranking (`Ranker`) is a line-for-line port of `Jump.cs`: word prefix 100 / substring 60 / subsequence 20 (terms of 3+ letters), title bonus 20, all-in-title bonus 30, frecency halving every 30 days, top 500 kept, accent-folding that keeps character positions for highlighting.

## Recording

- A 2-second timer. Each tick, if Spotify is running (checked with `NSRunningApplication`, so AppleScript never launches it), runs this on `Spotify.queue`:
  `tell application id "com.spotify.client" to if player state is playing then return {id, name, artist, album} of current track`
- The same track ID seen playing for 20 s counts as one play. A different track resets the clock, a pause stops it, and the same track resumed after a pause isn't counted twice (as on Windows: `lastRecorded`).
- If the port is available, the recorder also reads the now-playing album link, whose title must match the AppleScript name, and stores it as the album URI.
- Local files (`spotify:local:…` IDs) are recorded without a track URI.
- If permission is denied, the existing `onPermissionDenied` alert is shown once. Otherwise errors are ignored.

## Playing (background queue, one at a time)

1. Spotify not running: HUD "Spotify isn't running."
2. Already playing this track: nothing. Paused on this track: AppleScript `play`.
3. Track URI known: `play track "<track>" in context "<album>"` (the `in context` part is omitted when no album URI is known).
4. Otherwise, if the port is available: the Windows flow. Go to `/album/<id>` and click `Play <title> by <artist>` (then the prefix fallbacks); if that fails, search `<artist> <title>` and click.
5. Otherwise: HUD "This song needs Jump support — choose Restart Spotify with Jump support in the menu."
6. Verify: within 3 s, AppleScript's current track `id` differs from before (or equals the wanted track) and the player is playing; if it's paused, send `play` once and wait again. On failure: HUD "Spotify didn't start “<title>”."

Search row (port available): the Windows flow, clicking the first `Play ` row on `/search/<text>/tracks`. Without the port the row is labelled "Open Spotify search for “<text>”" and opens `spotify:search:<escaped text>` with `NSWorkspace` (this brings Spotify to the front; accepted).

## Debugging port

- `SpotifyPage`: GET `http://127.0.0.1:9229/json/list` (400 ms timeout for `available`), pick the `page` whose URL starts with `https://xpui.app.spotify.com`, then connect with `URLSessionWebSocketTask` and send `Runtime.evaluate` with `awaitPromise` and `returnByValue`. One connection is reused and redialled once on failure. Calls are synchronous to the caller, using a semaphore on a background queue, never on the main thread.
- The helper script is a Swift copy of `Jump.cs`'s `__sgh` (its own version number). Changes for the Mac: `collect()` also returns the album name (album link text) and the track link (`a[href*="/track/"]`) when present. `nowPlaying()` is unchanged.
- `SpotifyLauncher`:
  - `start()`: if Spotify is running, note whether it's playing, quit it (`NSRunningApplication.terminate`, wait up to 10 s, then `forceTerminate`), then launch `/Applications/Spotify.app` (found by bundle ID) with `NSWorkspace.openApplication`, `activates = false` and the arguments `--remote-debugging-port=9229 --disable-backgrounding-occluded-windows --disable-renderer-backgrounding`. Wait up to 30 s for the port, then resume with AppleScript `play` if it was playing.
  - The last two flags keep Chromium rendering while Spotify's window is hidden or covered, so import scrolling loads rows. This replaces the Windows off-screen trick, which has no Mac equivalent without Accessibility. **To verify during implementation**; if they don't help, the import asks for Spotify's window to be visible.
  - `ensureAtStartup()` (when `StartSpotify=true`): as on Windows. If the port is available, do nothing. If Spotify isn't running, start it. If it's running, restart it only if its `launchDate` is under 3 minutes ago and it isn't playing.
- The port only accepts local connections. The README carries the same warning as on Windows.

## Popup

- `JumpPanel`: borderless `NSPanel`, `.nonactivatingPanel`, `canBecomeKey = true`, level `.floating`, collection behaviour `[.canJoinAllSpaces, .fullScreenAuxiliary]`. Content is an `NSVisualEffectView` (`.popover` material) with rounded corners, so it follows dark/light mode.
- Because the panel doesn't activate the app, the app you were in stays frontmost and gets its keyboard back as soon as the panel closes. Nothing needs restoring.
- Shown centred horizontally, a fifth of the way down the screen with the mouse, about 640 pt wide. The search field sits over up to 10 rows, and the height fits the row count.
- Rows are drawn by one custom `NSView`: title (matched letters in green), artist · album dimmed, and on the right the age and `N×`, or "in <playlist>" for imports. These match `JumpForm.OnPaint`.
- Keys, handled in the field's `control(_:textView:doCommandBy:)` and a key-down override: ↑/↓, ⌃N/⌃P, PageUp/PageDown, Enter, Esc, ⌃R (Recent ↔ Most played; the hint on the right reads "Recent ⌃R"), ⌃U clears. ⌥⌫ word delete is native.
- Mouse: click a row to play it; the scroll wheel moves the selection.
- Closes on Esc, after Enter, when pressing the hotkey again, or on losing key status (clicked elsewhere).
- Empty states: "Spotify isn't running. Press Enter to start it with Jump support." Or, with an empty history: "Play some songs. Jump remembers each one after 20 seconds."
- `HUD`: a small non-activating borderless panel at the top centre of the same screen with one line of text. It fades out after 4 s and is used for every Jump and import message.

## Settings and menu

- Settings window: the Jump hotkey row comes from the `Action` loop. Below Start at Login there's a **Start Spotify with Jump support** checkbox and a **Clear history…** button (confirmation sheet).
- Ini: `Jump=Ctrl+Shift+J` (missing → default, empty → disabled; recording continues) and `StartSpotify=false`, with a comment.
- Menu, after the actions: **Import playlists into Jump** (while running, its title shows "Importing <name> (3/80)…" and it is disabled) and **Restart Spotify with Jump support**. Then come Settings, Start at Login and Quit as now.
- Import without the port: an alert offering to restart Spotify with Jump support, then import.

## Import

Same as Windows, with these Mac-specific details:
- `library()` → playlists and Liked Songs (`pagePath` as on Windows).
- One playlist per turn of the player's lock.
- Returns to the original path at the end.
- Imported songs get count 0, lastPlayed 0, the playlist name, album name, and album and track URIs.

## Testing

- `--selftest` (run in CI) gains the Windows Jump checks, ported:
  - folding
  - album ID from link
  - "doors storm" / "sltns" / "storm" ranking
  - non-matches excluded
  - empty query by recency and by frecency
  - highlight mask
  - history round-trip with tabs and newlines stripped, a corrupt line skipped, and same-song-any-case merged
  - 6,000-song growth
  - import adds only new songs and fills in missing links
  - played songs ranked above imports
  - `pagePath`, `baseTitle`
  - Jump hotkey and `StartSpotify` config round-trip
- New checks:
  - the two-URI link column parses and merges, and keeps existing URIs
- Manual, by me:
  - build both architectures
  - recording via AppleScript against the running Spotify
  - `play track … in context …`
  - then, with the user's OK, restart Spotify with the port and check the page script on the Mac build: router found, album click, search click, `collect()` with the window hidden
- Manual, by the user:
  - popup over a full-screen app: focus stays, typing works, and the app gets its keys back

## Out of scope

Same as the main spec, plus Accessibility-based UI scripting of any kind.
