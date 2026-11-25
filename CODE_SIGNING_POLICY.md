# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

The Windows release of Global Control for Spotify (`GlobalControlForSpotify.exe`) is signed. It is built from
the source in this repository by GitHub Actions ([release workflow](.github/workflows/release.yml)) on
GitHub-hosted runners, and each release is signed only after a team member approves the signing request.
The macOS app is not part of this signing.

## Team

| Role | Members |
|---|---|
| Authors (commit without further review) | [Matti Vakkilainen](https://github.com/liekki) |
| Reviewers (review changes from anyone else, such as pull requests) | [Matti Vakkilainen](https://github.com/liekki) |
| Approvers (approve each signing request) | [Matti Vakkilainen](https://github.com/liekki) |

## Privacy policy

This program will not transfer any information to other networked systems unless specifically requested by the
user or the person installing or operating it, with these exceptions:

- **Update check:** once a day at most, it asks GitHub (`api.github.com`) for the latest release of this project.
  The request carries no information about you or your music beyond what any web request does (your IP address,
  and the program's name as its user agent). Turn it off in Settings or with `CheckForUpdates=false`.
  Updating downloads the new version from GitHub only when you choose to.

Jump's history of songs you've played stays on your computer, next to the program. To control Spotify, the
program talks only to the Spotify app on the same computer (window messages, and Spotify's local debugging port
on `127.0.0.1` when Jump support is turned on).

## Uninstalling

Installed copies are removed from Windows Settings → Apps → Installed apps (or by running
`GlobalControlForSpotify.exe --uninstall`). A portable copy is removed by deleting its folder.
