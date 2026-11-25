# Self-installing exe, rename to Global Control for Spotify, SignPath signing

## Why

On Windows 11 with Smart App Control on, the Inno Setup installer fails with error 4551: the setup engine it
unpacks into `%TEMP%` is unsigned. Signing the finished setup afterwards doesn't sign that engine, and SignPath
Foundation (free signing for open-source projects) only signs files a GitHub Actions build uploads, with a manual
approval per request, so Inno's sign-during-compile hooks don't fit.

So the Windows release becomes one signed exe that installs, updates and uninstalls itself. At the same time the
app is renamed: names starting with "Spotify" go against Spotify's branding rules, and SignPath requires the
signed product name to equal the project name, so the rename happens before applying.

## Names

| | Old | New |
|---|---|---|
| Display name | Spotify Global Hotkeys | Global Control for Spotify |
| File base name (`Program.FileName`) | `SpotifyGlobalHotkeys` | `GlobalControlForSpotify` |
| Windows files | `SpotifyGlobalHotkeys.exe` / `.ini` / `-history.tsv` | `GlobalControlForSpotify.exe` / `.ini` / `-history.tsv` |
| Windows install folder | `%LOCALAPPDATA%\Programs\Spotify Global Hotkeys` | `%LOCALAPPDATA%\Programs\Global Control for Spotify` |
| Run key value | `SpotifyGlobalHotkeys` (and older `Spoco`) | `GlobalControlForSpotify` |
| Mac app | `Spotify Global Hotkeys.app` | `Global Control for Spotify.app` |
| Mac settings folder | `~/Library/Application Support/Spotify Global Hotkeys` | `~/Library/Application Support/Global Control for Spotify` |
| Mac download | `SpotifyGlobalHotkeys-macOS.zip` | `GlobalControlForSpotify-macOS.zip` |
| Repo | `liekki/spotify-global-hotkeys` | `liekki/global-control-for-spotify` |
| Source files | `SpotifyGlobalHotkeys.cs` / `.swift` | `GlobalControlForSpotify.cs` / `.swift` |

- The Mac bundle ID stays `io.github.liekki.spoco`: changing it would reset the "control Spotify" Automation
  permission and the login item. Users never see it.
- The repo is renamed on GitHub by the owner. GitHub redirects old URLs (including the API), so v1.5.1's update
  check still reaches the new repo.
- The single-instance mutex follows the new file name; the old app is stopped by process name during migration,
  so old and new never both run after an install.

## Windows: how the exe decides what to do on start

`Program.Main`, before the single-instance mutex:

1. `--selftest` → self-tests (unchanged). `--uninstall` → uninstall (below).
2. Clean up after an update: delete `GlobalControlForSpotify.exe.old` next to the exe if present.
3. Portable migration: if `SpotifyGlobalHotkeys.ini` / `SpotifyGlobalHotkeys-history.tsv` (or the Spoco names)
   sit next to the exe and the new names don't, rename them, as the Spoco migration does today.
4. Mode:
   - exe is in the install folder → run normally;
   - `GlobalControlForSpotify.ini` next to the exe → portable, run normally;
   - otherwise → show the install window.

The decision is a pure function (`Install.ModeFor(exeFolder, installFolder, fileExists)`) so self-tests cover it.

## Windows: install window

Small WinForms dialog in the app's existing style. Checkboxes, same wording as the old setup's tasks:

- Start Global Control for Spotify when I log in to Windows (default: on)
- Start Spotify with Jump support (… debugging port on 127.0.0.1 …) (default: off)
- Create a desktop shortcut (default: off)

If an old install exists (new or old install folder), the defaults come from its `.ini` and the Run key, and
the window says it will replace/update it. Buttons: **Install** and **Just run it from here**. The latter runs
the exe in place as a portable copy (it writes its `.ini` there, so it won't ask again).

**Install**, in order (all per-user, no admin):

1. Stop running copies: kill processes named `GlobalControlForSpotify`, `SpotifyGlobalHotkeys`, `Spoco`
   other than this one, wait up to 5 s.
2. Create the install folder; copy this exe to `GlobalControlForSpotify.exe` there (overwrite).
3. Migrate from an old Inno install at `%LOCALAPPDATA%\Programs\Spotify Global Hotkeys` if present:
   move `SpotifyGlobalHotkeys.ini` → `GlobalControlForSpotify.ini` and the history (+ `.tmp`) likewise, unless the
   new files already exist (also the Spoco names); delete the old folder (its exe, `unins000.exe`/`.dat`);
   delete Inno's uninstall key `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6C1F3E0A-8B2D-4E7A-9F4C-2D5B7A1E9C33}_is1`;
   delete the old Start menu and desktop shortcuts (`Spotify Global Hotkeys.lnk`, `Spoco.lnk`).
   Inno's uninstaller is never run: it would delete the settings and history.
4. Write `StartWithWindows` and `StartSpotify` into the new `.ini`, keeping its other lines (same approach as
   the old setup's `WriteSettings`). Set the Run key value `GlobalControlForSpotify`; delete `SpotifyGlobalHotkeys`
   and `Spoco` values.
5. Shortcuts: Start menu `Global Control for Spotify.lnk`; desktop one if ticked (else delete it). Created with
   the `WScript.Shell` COM object via `dynamic`-free late binding (`Type.GetTypeFromProgID` + `InvokeMember`),
   since csc has no WSH reference here.
6. Register in Installed apps: `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\GlobalControlForSpotify`
   with `DisplayName`, `DisplayVersion`, `Publisher` (Matti Vakkilainen), `DisplayIcon` (the exe),
   `InstallLocation`, `UninstallString` (`"<exe>" --uninstall`), `URLInfoAbout`, `NoModify`=1, `NoRepair`=1,
   `EstimatedSize`.
7. Start the installed exe and exit.

Errors (file in use, access denied) show a message box and leave the window open; nothing half-done is
rolled back beyond what a re-run of Install fixes, because each step is idempotent.

## Windows: uninstall (`--uninstall`)

Confirm ("Remove Global Control for Spotify and its settings and history?"). Then: stop the running app (kill
by name except self), delete the Run value, the Start menu and desktop shortcuts, the Uninstall key, the
`.ini`, history and `.tmp` (as the old setup's `[UninstallDelete]`). Finally a hidden
`cmd /c ping -n 3 127.0.0.1 >nul & rmdir /s /q "<install folder>"` removes the exe and folder after this
process exits. Uninstall from a portable copy only removes that copy's own files and Run value.

## Windows: updater

`Updates.Parse` looks for the asset `GlobalControlForSpotify.exe`. `Install(release)` for any copy whose folder
is writable (installed or portable):

1. Download to `<folder>\GlobalControlForSpotify.exe.new`; check size > 100 KB and `MZ` header (as now).
2. Rename the running exe to `.old` (allowed while running), move `.new` to the exe name. If the move fails,
   rename `.old` back and report the error.
3. Start the new exe and quit. The new copy deletes `.old` on start (see above).

A copy whose folder isn't writable opens the release page, as today's non-installed copies do. `Updates.Installed`
(the `unins000.exe` check) goes away.

## macOS

- `build.sh` produces `Global Control for Spotify.app` and `dist/GlobalControlForSpotify-macOS.zip`; display
  strings and `NSAppleEventsUsageDescription` use the new name.
- `Config`/`History` default folders use the new settings folder. On start, if the old folder exists and the
  new one doesn't, move it (as the Spoco migration does).
- If `/Applications/Spotify Global Hotkeys.app` exists and this app isn't it, move it to the Trash
  (`FileManager.trashItem`); ignore failures.
- The login item: after migration, if `StartAtLogin=true`, register `SMAppService.mainApp` again for the new
  bundle path (the app already syncs this from the `.ini` on launch; verify it covers this).
- `Update.swift`: `zipName` = `GlobalControlForSpotify-macOS.zip`; the "zip holds this app" check uses the new
  app name.

## Release workflow and signing

- Remove the `installer/` folder, the Inno Setup step, and `SpotifyGlobalHotkeysSetup.exe` from the release.
- Windows job: build → self-test → if signing is configured, sign → upload `GlobalControlForSpotify.exe`.
- Signing is configured when repository variable `SIGNPATH_ORGANIZATION_ID` is set and the ref is a tag.
  Steps: `actions/upload-artifact@v4` (`id: unsigned`, `name: windows-unsigned`, the exe only) →
  `signpath/github-action-submit-signing-request@v3` with `api-token: secrets.SIGNPATH_API_TOKEN`,
  `organization-id: vars.SIGNPATH_ORGANIZATION_ID`, `project-slug: global-control-for-spotify`,
  `signing-policy-slug: release-signing`, `github-artifact-id: steps.unsigned.outputs.artifact-id`,
  `parameters: version: "<x.y.z>"`, `wait-for-completion-timeout-in-seconds: 3600`,
  `output-artifact-directory: signed` → copy `signed\GlobalControlForSpotify.exe` over the unsigned one.
- `.signpath/artifact-configuration.xml` (pasted into SignPath's project; kept in the repo for reference):
  zip root, `pe-file path="GlobalControlForSpotify.exe"` with `product-name="Global Control for Spotify"`,
  `product-version="${version}"`, `<authenticode-sign/>`; `version` parameter required.
- `build.cmd` stamps `AssemblyProduct("Global Control for Spotify")` and the version (it already stamps both).
- `CODE_SIGNING_POLICY.md`: SignPath attribution ("Free code signing provided by SignPath.io, certificate by
  SignPath Foundation", linked), roles (Matti Vakkilainen: author, reviewer, approver), privacy (the app contacts
  only GitHub, to check for updates, once a day at most, which can be turned off; Jump's history stays on the
  computer; nothing else leaves it). Linked as "Code signing policy" from the top of the README and from the
  Download section.

## README

Rewritten for the new name, the single Windows download, the install window, portable use ("Just run it from
here"), uninstalling from Installed apps, and moving from Spotify Global Hotkeys (automatic; v1.5.1 users
download once by hand). Building-from-source drops Inno Setup.

## Testing

- Self-tests (`--selftest`, run by CI on Windows and locally on macOS) gain:
  - `Install.ModeFor`: installed / portable / ask cases;
  - old → new file name mapping (both Spoco and SpotifyGlobalHotkeys names);
  - `Updates.Parse` finds `GlobalControlForSpotify.exe` and ignores the old setup name;
  - macOS: `Updates` finds `GlobalControlForSpotify-macOS.zip`; settings-folder migration mapping.
- Not testable here (no Windows machine): the install window, migration from a real Inno install, uninstall,
  and the self-update swap. A manual checklist goes in the PR/summary for the owner to run on Windows before
  tagging.

## Out of scope

- Jump and the Microsoft Store version of Spotify (separate decision).
- Verifying the downloaded update's signature (possible once releases are signed).
