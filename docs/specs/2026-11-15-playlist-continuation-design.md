# Jump: continue the playlist — design

## Goal

Jumping to a song continues with the playlist it belongs to, not only its album. Both platforms, with Spotify started with Jump support.

## Which playlist

1. The playlist (or Liked Songs) you last played the song from.
2. Otherwise the first playlist **Import playlists into Jump** found it in.
3. Otherwise its album, as before.

Playing a song from an album, radio, search or the queue keeps the playlist it already had.

## Verified against Spotify 1.3.9 (Windows, by hand through the debugging port)

- `PlayerAPI.getState()` has `item` (`uri`, `name`, `album.uri`, `provider`: `context`, `queue` or `autoplay`) and `context` (`uri`, `metadata.context_description` = playlist name, `metadata.format_list_type`).
- Liked Songs plays as `spotify:playlist:<Spotify's own id>` (also `PlayerAPI._likedSongsUri`) with `format_list_type: liked-songs`. It is stored as `spotify:collection:tracks`, the URI the import uses; `PlayerAPI.play({ uri: 'spotify:collection:tracks' }, {}, { skipTo: { uri: track } })` plays the track in Liked Songs.
- `PlayerAPI.play({ uri: playlist }, {}, { skipTo: { uri: track } })` plays the track in the playlist. When the playlist doesn't have the track it doesn't fail: it quietly plays another song of the playlist.

## History

An eighth column, the playlist link: `spotify:playlist:<id>` or `spotify:collection:tracks`. The seventh column (playlist name) now means the playlist Jump plays the song in. Older lines load with an empty link; re-importing fills it in for songs whose seventh column already names that playlist, and gives songs without a playlist the first one found.

Windows now stores the track URI too, in the same two-URI link format as macOS (`spotify:track:<id> spotify:album:<id>`), and matches songs by track URI first.

## Recording

With Jump support, `__sgh.nowPlaying()` returns `[title, track, album, playlist name, playlist link]` from the player. The playlist is filled in only when `item.provider` is `context` and the context is a playlist or Liked Songs. Without the player service it falls back to the now-playing widget's `[title, album link]`.

## Playing

`__sgh.play(track, contexts)` tries each context in order (playlist, album), waiting up to two seconds for `getState().item.uri` to be the track, then plays the track on its own. Songs without a track URI keep the old album-page / search clicks.

macOS without Jump support: AppleScript `play track … in context <playlist>` (playlists only), checked through AppleScript's current track, then the album as before.
