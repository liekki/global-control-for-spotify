# Global Jump — design

## Goal

Winamp's **J** ("jump to file"), but global and for Spotify: press a hotkey anywhere — in a game, a browser, a meeting — type a few letters of a song you've played, press Enter, and Spotify plays it. Search feels like Atuin's Ctrl+R: instant, fuzzy, ranked by how recently and how often you played something, from a history that lives on your machine.

Constraint: **no Spotify Web API.** No developer app, no OAuth, no network calls. Everything goes through the Spotify desktop app on the same machine.

Success: with Spotify running, Ctrl+Shift+J → type `sult` → Enter starts "Sultans Of Swing" within about two seconds, continuing with the rest of its album, and focus returns to the app you were in.

## Revision: Windows playback through Spotify's debugging port

Built and tested the same day, the UI Automation approach below works but **brings Spotify to the front on every jump**: opening a `spotify:` link starts a short-lived Spotify.exe that activates the window, and even a UI Automation click inside Spotify activates it. Measured with a 10 ms focus sampler, every variant (plain link, minimized/no-activate launch flags, in-app link click, search box + posted keys) took the foreground. `LockSetForegroundWindow` and waiting for Enter to be released didn't prevent it; taking focus back afterwards only reduced it to a flash.

What does work, with Spotify never taking focus (also while minimized):

- Spoco starts Spotify with `--remote-debugging-port=9229` and talks Chrome DevTools Protocol to its `xpui.app.spotify.com` page over `127.0.0.1` (`ClientWebSocket` + `JavaScriptSerializer`, both in .NET Framework).
- Navigation: React Router's `history` object (found by walking React's fiber tree from any DOM node) `.push('/album/<id>')` or `.push('/search/<text>/tracks')`. Changing `location` directly does nothing.
- Playing: `.click()` on the row button `[data-testid="tracklist-row"] button[aria-label="Play <title> by <artist>"]`. Rows on screen before navigating are marked so a click can't hit the old page. The click starts playback directly.
- Recording: `[data-testid="now-playing-widget"] a[href*="/album/"]` gives the exact title and album id, which also tells where the artist ends in the window title.
- Spotify needs the flag: Jump's popup offers to (re)start Spotify (killed and relaunched `--minimized`, then Play resumes the song), and `StartSpotify=true` makes Spoco start it at login. The port only accepts local connections (Chromium rejects web-page origins), but any local program could control Spotify while it's open; the README says so.
- UI Automation, `spotify:` links and the focus guard are gone from the Windows code.

The rest of this document (popup, history, ranking, macOS) stands; the "Windows details" section is kept for the record.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Hotkey | `Jump=Ctrl+Shift+J`, configurable like the others | Winamp's J, next to the existing Ctrl+Shift+C/B/Z. |
| Where songs come from | Spoco's own history, recorded while Spotify plays | Spotify's local files have track IDs but no names; the Web API is ruled out. Recording ourselves gives names, counts and recency, Atuin-style. |
| Capturing on Windows | Window title change (`Artist - Title`) as the trigger; UI Automation reads the now-playing bar for exact title, artist and album link | Title changes are cheap to watch. The now-playing bar's title link exposes the album (`…/album/<id>`), which is what playback needs. Verified by hand against Spotify 1.3.9. |
| Playing on Windows | Open `spotify:album:<id>`, press the row button `Play <title> by <artist>` via UI Automation, then send `APPCOMMAND_MEDIA_PLAY` | Opening a `spotify:` link only navigates; the row button loads the song in its album context but leaves it paused; Play starts it. All three verified by hand. Opening links doesn't steal focus (checked with WoW in the foreground). |
| Capturing and playing on macOS | AppleScript: `current track`'s `id`, `name`, `artist`, `album`; `play track "spotify:track:<id>"` | Spotify's scripting dictionary has real track IDs and direct playback. No UI automation, no Accessibility permission. |
| Matching | Fuzzy, space-separated terms in any order, ranked by match quality then frecency | Matches the Atuin feel: `doors storm` finds "Riders On The Storm". |
| Search beyond history | Last row "Search Spotify for '<text>'" (Windows: plays the best matching song result; macOS: opens Spotify's search) | Reaches songs you've never played without the Web API. |
| Code layout | Stays one file per platform (`Spoco.cs`, `Spoco.swift`) | Keeps `build.cmd` / `build.sh` unchanged. |
| Order | Windows first, then macOS | Windows is the harder, riskier half; macOS reuses the popup design and history format. |

## The Jump popup (both platforms)

- Borderless, topmost window centred on the monitor of the foreground window, roughly 600×360 px: a search box over a list of up to 10 rows. Dark/light follows the system.
- Each row: **title**, artist · album in a dimmer colour, and on the right how long ago it was last played (`3 m`, `2 h`, `5 d`) and the play count when above 1.
- Opening: Spoco remembers the foreground window, then activates the popup (on Windows the `WM_HOTKEY` message grants the right to call `SetForegroundWindow`). Pressing the hotkey again while open closes it.
- Keys:
  - typing filters live; **Backspace**, **Ctrl+Backspace** (delete word), **Ctrl+U** (clear)
  - **↑/↓**, **Ctrl+P/Ctrl+N**, **PageUp/PageDown** move the selection
  - **Enter** plays the selected row and closes the popup
  - **Ctrl+R** cycles the ranking: *Recent* → *Most played* → *Recent* (the current mode is shown at the right of the search box, like Atuin's filter mode)
  - **Esc** or clicking outside closes it
- Closing always restores focus to the remembered window, so a game gets its input back.
- Empty search box: the history in the current ranking. No matches: a single "Search Spotify for '<text>'" row. With matches, that row is still last in the list.
- Spotify not running: the list is replaced with "Spotify isn't running" and Enter does nothing.
- The popup never blocks on Spotify: Enter closes it at once and playback runs on a background thread. Failures are reported as a tray balloon (Windows) or notification-style alert (macOS), never a modal dialog over a game.

## History

One line per distinct song, tab-separated, UTF-8, newest first, so the file is readable and easy to clear by hand:

```
<lastPlayedUnix>\t<playCount>\t<title>\t<artist>\t<album>\t<link>
```

- `link` is `spotify:album:<id>` on Windows and `spotify:track:<id>` on macOS (empty if unknown). The history isn't shared between platforms, so the difference doesn't matter.
- Identity of a song: case-insensitive `title + artist + album`. Playing it again bumps `playCount` and `lastPlayed` and moves it to the top.
- A play counts when the same song has been the current song for **20 seconds** while playing, so skipping through a playlist doesn't fill the history.
- No limit: the history keeps every song ever played (one line each, about 65 bytes), so it grows by a few thousand songs a year at most.
- Location:
  - Windows: `SpocoHistory.tsv` next to `Spoco.exe` (same rule as `Spoco.ini`; the installer's uninstaller deletes it).
  - macOS: `~/Library/Application Support/Spoco/history.tsv`.
- Written at most every 30 seconds and on quit, via write-to-temp-then-rename so a crash never leaves a half file.
- Settings window gets a **Clear history…** button (with a confirmation). The menu gets **Jump…** (shows its hotkey) above Settings.
- Recording is always on while Spoco runs; nothing leaves the machine.

## Ranking

- Query split on spaces into terms. Each term must match `title`, `artist` or `album`:
  - word-prefix match (term starts a word): best
  - substring match: good
  - subsequence match (letters in order, e.g. `sltns`): weak, only for terms of 3+ letters
- Score = sum of per-term match scores, plus a bonus when all terms hit the title.
- Ties, and the empty query, are ordered by the current mode:
  - *Recent*: `lastPlayed` descending
  - *Most played*: frecency = `playCount × decay(lastPlayed)`, with `decay` halving every 30 days, so an old favourite still ranks but this week's songs win.
- Matched letters are highlighted in the row.
- Must stay instant: measured on Windows with 100,000 songs (6.5 MB), loading takes 0.2 s and every keystroke 12–29 ms, with no index. The tie-breaker is computed once per song per search, and only the best 500 results are kept (more than anyone scrolls). Saving 100,000 songs takes about 90 ms, so it runs off the UI thread.

## Windows details

### Capture

- A 1-second timer (the tray app already has a message loop) reads Spotify's window title using the existing `Spotify.FindWindow()` (cached handle, re-found if it goes stale).
- `Spotify Premium` / `Spotify Free` / `Spotify` means paused or idle; anything else is `Artist - Title`.
- When the title changes to a new song, start the 20-second timer. When it fires and the title is unchanged, read the now-playing bar with UI Automation (`UIAutomationClient.dll`, `UIAutomationTypes.dll`, both part of .NET Framework):
  - find the `Hyperlink` whose name equals the title part and whose `ValuePattern` value contains `/album/` → album id, title
  - the `Hyperlink` whose value contains `/artist/` next to it → artist
  - album name: the album page isn't open, so take it from the `aria` label of the cover art link if exposed, otherwise leave it empty (it only helps matching)
- If UI Automation finds nothing (Spotify changed its UI), record title and artist split from the window title with an empty link. Such songs play through the search fallback.

### Playing a song

Runs on a background thread; total time limit 8 seconds.

1. If the song has a `spotify:album:` link: `ShellExecute` it, then poll the Spotify window's UI Automation tree every 150 ms for a `Button` named exactly `Play <title> by <artist>`. Fallback match: case-insensitive, then a button whose name starts with `Play <title>`.
2. Otherwise, or if step 1 times out after 4 seconds: open `spotify:search:<uri-escaped "artist title">` and look for a `Button` named `Play <title>` in the song results (the search page labels rows without "by"); prefer the one whose row also contains the artist name.
3. `InvokePattern.Invoke()` the button. This loads the song but may leave it paused.
4. Send `APPCOMMAND_MEDIA_PLAY` (idempotent, already used by the Play hotkey).
5. Verify: within 3 seconds the window title becomes `<artist> - <title>`. If not, show a balloon: "Couldn't start '<title>' — Spotify's page didn't have it."

The "Search Spotify for '<text>'" row does step 2 with the typed text and plays the first song result.

Side effect, by design: Spotify's window ends up showing that album or search page. It is not brought to the front.

### Known limits

- Depends on Spotify's English interface labels ("Play … by …") and page structure. Other UI languages or a Spotify redesign can break steps 1–2; the verify step turns that into a clear message rather than silence.
- A popup over a game in **exclusive** fullscreen may minimise the game when it takes focus. Borderless windowed is fine.
- Spotify's own `list_player_play_history` file (song and context IDs, no names) is not imported; see Out of scope.

## macOS details

Superseded by `2026-11-15-macos-jump-design.md` (hybrid AppleScript + debugging port).

- Capture: a 2-second timer runs (off the main thread) `tell application "Spotify" to if player state is playing then get {id, name, artist, album} of current track`, only when Spotify is running. Same 20-second rule. Uses the Automation permission Spoco already asks for.
- Play: `tell application "Spotify" to play track "<spotify:track:id>"`. AppleScript doesn't expose the album or playlist the song came from, so playback continues the way Spotify does for a single song (autoplay/radio) rather than with the album. Accepted.
- "Search Spotify for …": `open location "spotify:search:<escaped text>"`. It can't start a result without the Accessibility permission, so on macOS this row just opens the search in Spotify (and brings it to the front). Labelled "Open Spotify search for '<text>'" there.
- Popup: a regular (activating) `NSPanel` at `.floating` level, since it must take keyboard focus; it closes when it loses key status, and focus returns to the previous app with `NSRunningApplication.activate`.

## Config additions

Both platforms gain one line in `Spoco.ini`:

```ini
Jump=Ctrl+Shift+J
```

Missing key → default (existing installs get Jump automatically). Empty → Jump disabled, and history recording continues so it's ready if re-enabled.

## Testing

- Add `--selftest` to the Windows build (macOS already has it) and run it in CI for both:
  - window-title parsing (`Artist - Title - 2021 Remaster` splits at the first ` - `; paused titles detected)
  - fuzzy scoring: word-prefix beats substring beats subsequence; `doors storm` finds "Riders On The Storm"; non-matches excluded
  - frecency ordering and the history growing past 5000 songs
  - history file round-trip, including tabs/newlines in names being stripped, and a corrupt line being skipped
- Manual, Windows, against a running Spotify:
  - capture: songs appear after 20 s; skipped songs don't; paused time doesn't count
  - Jump from WoW (borderless): popup appears, Enter plays, WoW gets focus back, the album continues afterwards
  - a song captured without an album link plays via search
  - "Search Spotify for …" plays a song never played before
  - Spotify closed → "Spotify isn't running"; Spotify UI language switched → clear failure balloon
- Manual, macOS: capture, play by ID, search row opens Spotify search, focus returns.

## Out of scope

- The Spotify Web API, in any form (including the public oEmbed endpoint for names).
- Importing Spotify's local `list_player_play_history` file (IDs without names).
- Add to queue (needs the "More options" context menu on Windows; not available via AppleScript).
- Playlists, liked songs or albums as search scopes beyond what you've played.
- Syncing history between machines.

## Addendum: importing playlists (Windows)

Built after the revision above, through the same debugging-port connection:

- **Import playlists into Jump** (tray menu) reads Your Library's list (`[role="grid"][aria-label="Your Library"]`, rows `[aria-labelledby^="listrow-title-spotify:…"]`), keeps `spotify:playlist:*` and Liked Songs (`…:collection` → `/collection/tracks`), and opens each through Spotify's router.
- Lists are virtualised, so the page scrolls its own scroll container in steps of 80% of a screen every 80 ms and collects rows by `aria-rowindex`: title and artist from the "Play <title> by <artist>" button, album from the row's `/album/` link. Rows without an album link (podcast episodes, local files) are skipped.
- Chromium doesn't render a minimized or tray-hidden window, and then scrolling loads nothing (measured: 34 of 317 rows). The import therefore shows Spotify without activation, off-screen at the bottom of the z-order, and restores its exact placement afterwards.
- Imported songs get `count = 0`, `lastPlayed = 0` and a seventh column, the first playlist they were seen in. They sort below everything played and show "in <playlist>" in the popup. Re-importing only adds new songs and fills in missing album links. Playing one turns it into a normal entry.
- Jumps and imports take turns per playlist (`Player.Exclusive`), so a jump during an import waits a few seconds at most.
- Measured on the author's library: 82 playlists, 3,629 songs (3,334 new) in 88 seconds, Spotify never in front.

Superseded by "Revision: importing through Spotify's own services" in `2026-11-15-macos-jump-design.md`: the import now reads playlists from Spotify's internal services instead of scrolling its window.
