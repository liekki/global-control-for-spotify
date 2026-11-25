// Jump - press a hotkey, type part of a song you've played, Enter plays it.
// Songs are recorded locally through Spotify's AppleScript interface. Songs with a track ID play through
// AppleScript too; with Spotify started with its debugging port, Jump can also play from album and
// search pages and import playlists, by running JavaScript inside Spotify (as on Windows).
// See docs/specs/2026-11-15-macos-jump-design.md.
import Cocoa

struct JumpError: Error { let message: String; init(_ message: String) { self.message = message } }

// MARK: - Songs and links

struct Song {
    var lastPlayed: Int64 = 0  // unix seconds; 0 for a song only imported from a playlist
    var count = 0              // 0 for a song only imported from a playlist
    var title = "", artist = "", album = "", link = ""
    // The playlist Jump plays the song in: the one you last played it from, else the first one it was
    // imported from. Name for showing, link (spotify:playlist:<id> or spotify:collection:tracks) for playing.
    var playlist = "", playlistLink = ""
    // Lower-case, accents removed, as UTF-16 with the same length as the originals (so matches map back).
    var foldTitle: [UInt16] = [], foldArtist: [UInt16] = [], foldAlbum: [UInt16] = []

    func folded() -> Song {
        var s = self
        s.foldTitle = Strings.fold(title)
        s.foldArtist = Strings.fold(artist)
        s.foldAlbum = Strings.fold(album)
        return s
    }

    var key: String { (title + "\t" + artist + "\t" + album).lowercased() }
}

// The link column holds up to two URIs: "spotify:track:<id> spotify:album:<id>".
enum Links {
    static func parse(_ link: String) -> (track: String?, album: String?) {
        var track: String?, album: String?
        for part in link.split(separator: " ").map(String.init) {
            if part.hasPrefix("spotify:track:"), track == nil { track = part }
            if part.hasPrefix("spotify:album:"), album == nil { album = part }
        }
        return (track, album)
    }

    static func make(track: String?, album: String?) -> String {
        [track, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Keeps what's already known, adds what's new.
    static func merge(_ old: String, _ new: String) -> String {
        let a = parse(old), b = parse(new)
        return make(track: a.track ?? b.track, album: a.album ?? b.album)
    }

    // "/album/2rCS6Xwx32V27pvgFzLzlT?x" -> "2rCS6Xwx32V27pvgFzLzlT"
    static func id(_ url: String?, kind: String) -> String? {
        guard let url, let r = url.range(of: "/\(kind)/") else { return nil }
        let id = url[r.upperBound...].prefix { $0 != "?" && $0 != "/" && $0 != "#" }
        return id.isEmpty ? nil : String(id)
    }

    static func uri(_ url: String?, kind: String) -> String? { id(url, kind: kind).map { "spotify:\(kind):\($0)" } }

    // Contexts Jump plays a song in: playlists and Liked Songs.
    static func isPlaylist(_ uri: String) -> Bool {
        uri == "spotify:collection:tracks" || (uri.hasPrefix("spotify:playlist:") && uri.count > "spotify:playlist:".count)
    }

    // Only what can appear in a Spotify URI, so it can go into an AppleScript string safely.
    static func safe(_ uri: String) -> Bool { !uri.isEmpty && uri.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ":") } }
}

enum Strings {
    static func fold(_ s: String) -> [UInt16] {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let whole = s.folding(options: opts, locale: nil)
        if whole.utf16.count == s.utf16.count { return Array(whole.utf16) }
        // Some character changed length (ß -> ss): fold one at a time, keeping any that would.
        var out: [UInt16] = []
        out.reserveCapacity(s.utf16.count)
        for ch in s {
            let o = String(ch), f = o.folding(options: opts, locale: nil)
            out += f.utf16.count == o.utf16.count ? Array(f.utf16) : Array(o.utf16)
        }
        return out
    }

    static func age(_ seconds: Int64) -> String {
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) m" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        if seconds < 86400 * 7 { return "\(seconds / 86400) d" }
        if seconds < 86400 * 60 { return "\(seconds / (86400 * 7)) w" }
        if seconds < 86400 * 365 { return "\(seconds / (86400 * 30)) mo" }
        return "\(seconds / (86400 * 365)) y"
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - History

// One line per song, newest first, imported-but-unplayed songs last:
// lastPlayed, count, title, artist, album, link, playlist, playlist link (tab-separated).
final class History {
    let url: URL?
    private let gate = NSLock(), saving = NSLock()
    private var songs: [Song] = []
    private var dirty = false

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Global Control for Spotify", isDirectory: true).appendingPathComponent("GlobalControlForSpotify-history.tsv")
    }

    init(url: URL?) {
        self.url = url
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) { songs = History.parse(text) }
    }

    var count: Int { gate.lock(); defer { gate.unlock() }; return songs.count }

    // Songs are values, so the copy can be used from any thread.
    func snapshot() -> [Song] { gate.lock(); defer { gate.unlock() }; return songs }

    // playlistLink: the playlist (or Liked Songs) it's playing from, "" for an album, radio, search...
    func record(title: String, artist: String, album: String, link: String, playlist: String = "", playlistLink: String = "", now: Int64) {
        gate.lock(); defer { gate.unlock() }
        var count = 0, keepLink = link, playlist = playlist, playlistLink = playlistLink
        let key = Song(title: title, artist: artist, album: album).key, track = Links.parse(link).track
        // The same track can be spelled differently (AppleScript's artist vs. the import's "A, B"), so its ID wins.
        if let i = songs.firstIndex(where: { (track != nil && Links.parse($0.link).track == track) || $0.key == key }) {
            count = songs[i].count
            keepLink = Links.merge(songs[i].link, link)
            // Played from an album or radio: it still belongs to the playlist it was last played from.
            if playlistLink.isEmpty { playlist = songs[i].playlist; playlistLink = songs[i].playlistLink }
            songs.remove(at: i)
        }
        songs.insert(Song(lastPlayed: now, count: count + 1, title: title, artist: artist, album: album, link: keepLink,
                          playlist: playlist, playlistLink: playlistLink).folded(), at: 0)
        dirty = true
    }

    // Adds playlist songs you haven't played yet, after everything you have. Returns how many were new.
    func importSongs(_ found: [Song]) -> Int {
        gate.lock(); defer { gate.unlock() }
        var known: [String: Int] = [:], knownTracks: [String: Int] = [:]
        for (i, s) in songs.enumerated() {
            known[s.key] = i
            if let t = Links.parse(s.link).track { knownTracks[t] = i }
        }
        var added = 0
        for f in found {
            let track = Links.parse(f.link).track
            if let i = track.flatMap({ knownTracks[$0] }) ?? known[f.key] {
                // Already known: just fill in what's missing. A song without a playlist link gets this one,
                // unless it already names another playlist (from before playlist links were kept).
                var s = songs[i]
                let link = Links.merge(s.link, f.link)
                let takePlaylist = s.playlistLink.isEmpty && !f.playlistLink.isEmpty && (s.playlist.isEmpty || s.playlist == f.playlist)
                if link != s.link || takePlaylist {
                    s.link = link
                    if takePlaylist { s.playlist = f.playlist; s.playlistLink = f.playlistLink }
                    songs[i] = s
                    dirty = true
                }
                continue
            }
            known[f.key] = songs.count
            if let track { knownTracks[track] = songs.count }
            songs.append(Song(title: f.title, artist: f.artist, album: f.album, link: f.link, playlist: f.playlist, playlistLink: f.playlistLink).folded())
            added += 1
        }
        if added > 0 { dirty = true }
        return added
    }

    func clear() {
        gate.lock(); songs.removeAll(); dirty = true; gate.unlock()
        saveIfDirty()
    }

    func saveIfDirty() {
        saving.lock(); defer { saving.unlock() } // the timer saves in the background; quitting saves on the main thread
        gate.lock()
        guard dirty, let url else { gate.unlock(); return }
        let text = History.format(songs)
        dirty = false
        gate.unlock()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic) // temp file + rename: a crash never leaves half a history
        } catch {
            NSLog("Global Control for Spotify: couldn't save Jump history: \(error)")
        }
    }

    static func parse(_ text: String) -> [Song] {
        var result: [Song] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let last = Int64(f[0]), let count = Int(f[1]), !f[2].isEmpty else { continue }
            result.append(Song(lastPlayed: last, count: count, title: f[2], artist: f[3], album: f[4], link: f[5],
                               playlist: f.count > 6 ? f[6] : "", playlistLink: f.count > 7 && Links.isPlaylist(f[7]) ? f[7] : "").folded())
        }
        return result
    }

    static func format(_ songs: [Song]) -> String {
        var s = ""
        for x in songs {
            s += "\(x.lastPlayed)\t\(x.count)\t\(Strings.clean(x.title))\t\(Strings.clean(x.artist))\t\(Strings.clean(x.album))\t\(Strings.clean(x.link))\t\(Strings.clean(x.playlist))\t\(Strings.clean(x.playlistLink))\n"
        }
        return s
    }
}

// MARK: - Recording

// Asks Spotify what's playing every 2 seconds and records a song once it has played for 20 seconds.
final class Recorder {
    static let requiredSeconds: TimeInterval = 20
    let history: History
    private var timer: Timer?
    // Only touched on Spotify.queue.
    private var current: String?, lastRecorded: String?
    private var since = Date()

    init(history: History) {
        self.history = history
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard Spotify.isRunning else { return }
            Spotify.queue.async { self?.tick() }
        }
    }

    private func tick() {
        guard let state = Spotify.state(), state.playing, !state.id.isEmpty else { current = nil; return }
        if state.id != current { current = state.id; since = Date(); return }
        // Pausing and resuming the same song shouldn't count it twice.
        guard state.id != lastRecorded, Date().timeIntervalSince(since) >= Recorder.requiredSeconds else { return }
        lastRecorded = state.id
        let now = Strings.now()
        DispatchQueue.global().async { [history] in
            // With Jump support, Spotify's player also tells the album and the playlist it's playing from.
            var album: String?, playlist = "", playlistLink = ""
            if SpotifyPage.available(), let np = try? SpotifyPage.nowPlaying(), np.title == state.name, np.track.isEmpty || np.track == state.id {
                album = np.album
                playlist = np.playlist; playlistLink = np.playlistLink
            }
            let track = state.id.hasPrefix("spotify:track:") ? state.id : nil // local files have no usable ID
            history.record(title: state.name, artist: state.artist, album: state.album, link: Links.make(track: track, album: album),
                           playlist: playlist, playlistLink: playlistLink, now: now)
        }
    }
}

// MARK: - Ranking

struct Ranked {
    var song: Song
    var score: Int
    var order: Double // tie-breaker: last played or frecency, worked out once per search
}

enum Ranker {
    static let wordPrefix = 100, substring = 60, subsequence = 20, titleBonus = 20, allInTitleBonus = 30
    static let limit = 500 // more than anyone scrolls through; keeps big histories instant

    static func rank(_ songs: [Song], query: String, mostPlayed: Bool, now: Int64) -> [Ranked] {
        let t = terms(query)
        var result: [Ranked] = []
        for s in songs {
            let score = t.isEmpty ? 0 : self.score(s, t)
            if score >= 0 { result.append(Ranked(song: s, score: score, order: mostPlayed ? frecency(s, now: now) : Double(s.lastPlayed))) }
        }
        result.sort { $0.score != $1.score ? $0.score > $1.score : $0.order > $1.order }
        if result.count > limit { result.removeSubrange(limit...) }
        return result
    }

    static func terms(_ query: String) -> [[UInt16]] {
        Strings.fold(query).split(separator: 32).map(Array.init)
    }

    // Play count, halved for every 30 days since the song was last played.
    static func frecency(_ s: Song, now: Int64) -> Double {
        let days = Double(max(0, now - s.lastPlayed)) / 86400
        return Double(s.count) * pow(0.5, days / 30)
    }

    // Returns -1 if some term matches nowhere. markTitle/markArtist (if given) get the matched UTF-16 offsets.
    static func score(_ s: Song, _ terms: [[UInt16]], markTitle: ((Int) -> Void)? = nil, markArtist: ((Int) -> Void)? = nil) -> Int {
        var total = 0, allInTitle = true
        for term in terms {
            let t = match(s.foldTitle, term), a = match(s.foldArtist, term), b = match(s.foldAlbum, term)
            let best = max(t, a, b)
            if best == 0 { return -1 }
            if t == best {
                total += t + titleBonus
                if let markTitle { _ = match(s.foldTitle, term, mark: markTitle) }
            } else {
                allInTitle = false
                total += best
                if a == best, let markArtist { _ = match(s.foldArtist, term, mark: markArtist) }
            }
        }
        return !terms.isEmpty && allInTitle ? total + allInTitleBonus : total
    }

    // Word prefix ("sto" in "Riders On The Storm") beats substring ("orm") beats letters in order ("sltns").
    static func match(_ hay: [UInt16], _ term: [UInt16], mark: ((Int) -> Void)? = nil) -> Int {
        if hay.isEmpty || term.isEmpty { return 0 }
        var first = -1
        if term.count <= hay.count {
            var i = 0
            while i + term.count <= hay.count {
                if hay[i] == term[0] && hasTerm(hay, term, at: i) {
                    if first < 0 { first = i }
                    if i == 0 || !isWordChar(hay[i - 1]) {
                        if let mark { for k in i..<(i + term.count) { mark(k) } }
                        return wordPrefix
                    }
                }
                i += 1
            }
        }
        if first >= 0 {
            if let mark { for k in first..<(first + term.count) { mark(k) } }
            return substring
        }
        if term.count < 3 { return 0 }
        var positions: [Int] = [], p = 0
        for c in term {
            while p < hay.count && hay[p] != c { p += 1 }
            if p >= hay.count { return 0 }
            positions.append(p)
            p += 1
        }
        if let mark { positions.forEach(mark) }
        return subsequence
    }

    private static func hasTerm(_ hay: [UInt16], _ term: [UInt16], at i: Int) -> Bool {
        for k in 1..<max(1, term.count) where hay[i + k] != term[k] { return false }
        return true
    }

    static func isWordChar(_ u: UInt16) -> Bool {
        if u < 128 { return (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) }
        guard let scalar = Unicode.Scalar(u) else { return false } // half of a surrogate pair
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

// MARK: - Talking to Spotify's page (debugging port)

// Spotify's desktop app is a web page in an embedded Chromium. Started with --remote-debugging-port,
// it lets this app run JavaScript inside that page (Chrome DevTools Protocol, 127.0.0.1 only).
// Navigating and clicking from inside the page never brings Spotify to the front.
enum SpotifyPage {
    static let port = 9229
    private static let gate = NSLock()
    private static var socket: URLSessionWebSocketTask?
    private static var nextId = 0
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    // Mostly a copy of Jump.cs's helper. library()/songs() read Spotify's own services; Spotify navigates with
    // React Router's history object, which isn't on window, so find it in React's component tree. Rows on
    // screen before navigating are marked, so a click can't land on the previous page while the new one renders.
    static let helper = #"""
    if (!window.__sgh || window.__sgh.v !== 107) window.__sgh = (() => {
      // Depth-first through React's component tree for the first props that pass `test`.
      const findProps = test => {
        const host = [...document.querySelectorAll('body *')].find(e => Object.keys(e).some(k => k.startsWith('__reactFiber$')));
        if (!host) return null;
        let f = host[Object.keys(host).find(k => k.startsWith('__reactFiber$'))];
        while (f.return) f = f.return;
        const stack = [f];
        while (stack.length) {
          const x = stack.pop(), p = x.memoizedProps;
          if (p && test(p)) return p;
          if (x.sibling) stack.push(x.sibling);
          if (x.child) stack.push(x.child);
        }
        return null;
      };
      let nav = null, registry = null;
      const router = () => {
        if (!nav) { const p = findProps(p => p.history && typeof p.history.push === 'function'); nav = p && p.history; }
        return nav;
      };
      // Spotify's internal services (player, playlists, library), registered under Symbol(<name>).
      const service = name => {
        if (!registry) { const p = findProps(p => p.platform && typeof p.platform.getRegistry === 'function'); registry = p && p.platform.getRegistry(); }
        const key = registry && registry._map && [...registry._map.keys()].find(k => typeof k === 'symbol' && k.description === name);
        return key ? registry.resolve(key) : null;
      };
      const rows = () => [...document.querySelectorAll('[data-testid="tracklist-row"] button[aria-label]')];
      return {
        v: 107,
        // Your playlists (folders flattened) and Liked Songs, as [uri, name] pairs.
        async library() {
          const root = service('RootlistAPI');
          if (!root) return 'no-api';
          const out = [];
          const walk = items => (items || []).forEach(i => i.type === 'folder' ? walk(i.items) : i.type === 'playlist' && out.push([i.uri, i.name || '']));
          walk((await root.getContents()).items);
          if (service('LibraryAPI')) out.push(['spotify:collection:tracks', 'Liked Songs']);
          return JSON.stringify(out);
        },
        // A playlist's (or Liked Songs') songs as [title, artists, album name, album uri, track uri]. No UI involved.
        async songs(uri) {
          let items;
          if (uri === 'spotify:collection:tracks') {
            const lib = service('LibraryAPI');
            if (!lib) return 'no-api';
            const first = await lib.getTracks({ limit: 1 });
            items = (await lib.getTracks({ limit: Math.max(1, first.totalLength || 0) })).items;
          } else {
            const pl = service('PlaylistAPI');
            if (!pl) return 'no-api';
            items = (await pl.getContents(uri)).items;
          }
          return JSON.stringify((items || []).filter(t => t && t.type === 'track' && !t.isLocal && t.album && t.album.uri)
            .map(t => [t.name || '', (t.artists || []).map(a => a.name).join(', '), t.album.name || '', t.album.uri, t.uri || '']));
        },
        go(path) {
          const h = router();
          if (!h) return 'no-router';
          if (h.location.pathname === path) return 'ok'; // already there: the rows on screen are the right ones
          rows().forEach(b => b.dataset.sghOld = '1');
          h.push(path);
          return 'ok';
        },
        click(wanted) {
          const fresh = rows().filter(b => !b.dataset.sghOld);
          for (const [exact, text] of wanted) {
            const t = text.toLowerCase();
            const b = fresh.find(b => { const l = b.getAttribute('aria-label').toLowerCase(); return exact ? l === t : l.startsWith(t); });
            if (b) { b.click(); return 'clicked'; }
          }
          return fresh.length ? 'no-match' : 'loading';
        },
        // Through Spotify's player service, which (unlike AppleScript's play track) leaves Spotify's window in the background.
        // Tries each context (playlist, album) until the player really plays the track (it quietly starts another
        // song when the context doesn't have it), then the track alone.
        async play(track, contexts) {
          const p = service('PlayerAPI');
          if (!p) return 'no-api';
          for (const context of contexts.concat([''])) {
            try { await p.play({ uri: context || track }, {}, { skipTo: { uri: track } }); } catch (e) { continue; }
            for (let i = 0; i < 20; i++) {
              await new Promise(r => setTimeout(r, 100));
              const item = p.getState().item;
              if (item && item.uri === track) return 'ok';
            }
          }
          return 'other';
        },
        // [title, track, album, playlist name, playlist uri] from the player; the playlist only when the song
        // plays from one (not from the queue or autoplay). Without the player, [title, album link] from the widget.
        async nowPlaying() {
          const p = service('PlayerAPI'), s = p && p.getState(), item = s && s.item;
          if (!item) {
            const w = document.querySelector('[data-testid="now-playing-widget"]');
            const a = w && w.querySelector('a[href*="/album/"]');
            return a ? JSON.stringify([a.textContent.trim(), a.getAttribute('href')]) : '';
          }
          const c = s.context || {}, m = c.metadata || {};
          let name = '', list = '';
          if (item.provider === 'context') {
            // Liked Songs plays as a playlist of Spotify's own; keep the URI the library import uses.
            if (m.format_list_type === 'liked-songs' || c.uri === p._likedSongsUri) { list = 'spotify:collection:tracks'; name = 'Liked Songs'; }
            else if (/^spotify:playlist:/.test(c.uri || '')) {
              list = c.uri;
              name = m.context_description || '';
              const pl = service('PlaylistAPI');
              if (!name && pl) try { name = (await pl.getMetadata(list)).name || ''; } catch (e) { }
            }
          }
          return JSON.stringify([item.name || '', item.uri || '', (item.album && item.album.uri) || '', name, list]);
        }
      };
    })();
    """#

    static func available() -> Bool { (try? pageURL(timeout: 0.4)) != nil }

    private static func pageURL(timeout: TimeInterval) throws -> URL? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json/list")!)
        request.timeoutInterval = timeout
        let data = try fetch(request, timeout: timeout + 0.2)
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for t in targets where t["type"] as? String == "page" {
            if let url = t["url"] as? String, url.hasPrefix("https://xpui.app.spotify.com"),
               let ws = t["webSocketDebuggerUrl"] as? String { return URL(string: ws) }
        }
        return nil
    }

    private static func fetch(_ request: URLRequest, timeout: TimeInterval) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Data?, failure: Error?
        let task = session.dataTask(with: request) { data, _, error in result = data; failure = error; done.signal() }
        task.resume()
        if done.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); throw JumpError("Spotify didn't answer.") }
        if let failure { throw failure }
        return result ?? Data()
    }

    static func go(_ path: String) throws -> String { try eval("__sgh.go(\(js(path)))") }

    // wanted: (exact, label) pairs in order of preference, e.g. (true, "Play Lions by Dire Straits").
    static func click(_ wanted: [(Bool, String)]) throws -> String {
        try eval("__sgh.click(\(js(wanted.map { [$0.0, $0.1] as [Any] })))")
    }

    // Plays the track in the first of the contexts (playlist, album) that has it, else on its own, without
    // bringing Spotify forward. False when the player service is missing.
    static func play(track: String, contexts: [String]) throws -> Bool {
        try eval("__sgh.play(\(js(track)), \(js(contexts)))", timeout: 15) != "no-api"
    }

    struct NowPlaying {
        var title = "", track = "", album: String?  // track is empty when only the page's widget answered
        var playlist = "", playlistLink = ""        // empty unless it plays from a playlist or Liked Songs
    }

    static func nowPlaying() throws -> NowPlaying? { parseNowPlaying(try eval("__sgh.nowPlaying()")) }

    // [title, track uri, album uri, playlist name, playlist uri] from the player, or [title, album link] from the widget.
    static func parseNowPlaying(_ json: String) -> NowPlaying? {
        guard let f = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String], f.count >= 2, !f[0].isEmpty else { return nil }
        if f.count == 2 {
            guard let album = Links.uri(f[1], kind: "album") else { return nil }
            return NowPlaying(title: f[0], album: album)
        }
        guard f.count >= 5 else { return nil }
        var now = NowPlaying(title: f[0])
        if Links.parse(f[1]).track == f[1] { now.track = f[1] }
        if Links.parse(f[2]).album == f[2] { now.album = f[2] }
        if Links.isPlaylist(f[4]) { now.playlist = f[3]; now.playlistLink = f[4] }
        return now
    }

    static let changed = "Spotify's page didn't understand this app (Spotify may have changed)."

    // Your playlists and Liked Songs as (uri, name), in library order.
    static func library() throws -> [(uri: String, name: String)] {
        let result = try eval("__sgh.library()", timeout: 30)
        if result == "no-api" { throw JumpError(changed) }
        let pairs = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [[String]] ?? []
        return pairs.filter { $0.count == 2 }.map { ($0[0], $0[1]) }
    }

    // A playlist's songs, straight from Spotify's playlist service (about 0.1 s for a playlist).
    static func songs(uri: String, playlist: String) throws -> [Song] {
        let result = try eval("__sgh.songs(\(js(uri)))", timeout: 60)
        if result == "no-api" { throw JumpError(changed) }
        return parseSongs(result, playlist: playlist, playlistLink: uri)
    }

    static func parseSongs(_ json: String, playlist: String, playlistLink: String = "") -> [Song] {
        let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String]] ?? []
        let link = Links.isPlaylist(playlistLink) ? playlistLink : ""
        return rows.filter { $0.count == 5 && !$0[0].isEmpty }.map {
            Song(title: $0[0], artist: $0[1], album: $0[2],
                 link: Links.make(track: $0[4].hasPrefix("spotify:track:") ? $0[4] : nil, album: $0[3].hasPrefix("spotify:album:") ? $0[3] : nil),
                 playlist: playlist, playlistLink: link)
        }
    }

    private static func js(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])) ?? Data("[null]".utf8)
        let s = String(decoding: data, as: UTF8.self)
        return String(s.dropFirst().dropLast()) // unwrap the array, which JSONSerialization needs at the top level
    }

    static func eval(_ expression: String, timeout: TimeInterval = 5) throws -> String {
        precondition(!Thread.isMainThread, "SpotifyPage blocks; call it off the main thread")
        gate.lock(); defer { gate.unlock() }
        for attempt in 0..<2 {
            do {
                if socket == nil || socket?.state != .running { try connect() }
                return try send(helper + expression, timeout: timeout)
            } catch let e as JumpError where e.message == changed {
                throw e
            } catch {
                socket?.cancel(); socket = nil
                if attempt == 1 { throw JumpError("Couldn't reach Spotify: \((error as? JumpError)?.message ?? error.localizedDescription)") }
            }
        }
        throw JumpError("Couldn't reach Spotify.")
    }

    private static func connect() throws {
        guard let url = try pageURL(timeout: 1) else { throw JumpError("Spotify's page isn't ready yet.") }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024 // a big playlist comes back as one message
        task.resume()
        socket = task
    }

    private static func send(_ expression: String, timeout: TimeInterval) throws -> String {
        guard let socket else { throw JumpError("Not connected.") }
        nextId += 1
        let id = nextId
        let message: [String: Any] = ["id": id, "method": "Runtime.evaluate",
                                      "params": ["expression": expression, "returnByValue": true, "awaitPromise": true]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let deadline = DispatchTime.now() + timeout

        let sent = DispatchSemaphore(value: 0)
        var sendError: Error?
        socket.send(.string(text)) { sendError = $0; sent.signal() }
        if sent.wait(timeout: deadline) == .timedOut { throw JumpError("Spotify didn't answer.") }
        if let sendError { throw sendError }

        while true {
            let got = DispatchSemaphore(value: 0)
            var reply: Result<URLSessionWebSocketTask.Message, Error>?
            socket.receive { reply = $0; got.signal() }
            if got.wait(timeout: deadline) == .timedOut { throw JumpError("Spotify didn't answer.") }
            let data: Data
            switch reply! {
            case .failure(let e): throw e
            case .success(.string(let s)): data = Data(s.utf8)
            case .success(.data(let d)): data = d
            case .success: continue
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["id"] as? Int == id else { continue } // an event, not our answer
            let outer = obj["result"] as? [String: Any] ?? [:]
            if outer["exceptionDetails"] != nil { throw JumpError(changed) }
            let result = outer["result"] as? [String: Any] ?? [:]
            if let v = result["value"] as? String { return v }
            if let v = result["value"] { return "\(v)" }
            return ""
        }
    }
}

// MARK: - Starting Spotify with Jump support

enum SpotifyLauncher {
    // The last two keep Chromium rendering while Spotify's window is hidden or covered, so an import's scrolling loads rows.
    static let arguments = ["--remote-debugging-port=\(SpotifyPage.port)", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]

    // StartSpotify=true: when this app starts (usually at login), make sure Spotify has Jump support.
    // A Spotify that started in the last few minutes and isn't playing yet is restarted; anything else is
    // left alone (the menu has a restart).
    static func ensureAtStartup() throws {
        if SpotifyPage.available() { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Spotify.bundleID).first {
            let recent = app.launchDate.map { Date().timeIntervalSince($0) < 180 } ?? false
            if !recent || Spotify.stateSync()?.playing == true { return }
        }
        try start()
    }

    static func start() throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Spotify.bundleID) else {
            throw JumpError("Couldn't find Spotify. Install it from spotify.com.")
        }
        var resume = false
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Spotify.bundleID)
        if !running.isEmpty {
            resume = Spotify.stateSync()?.playing == true
            // Never force it: Spotify can be installing an update as it quits, and killing it then leaves an empty
            // Spotify.app behind. A minute covers an update; past that, leave Spotify be and say so.
            running.forEach { $0.terminate() }
            if !waitUntil(60, { !Spotify.isRunning }) {
                throw JumpError("Spotify didn't quit, so it couldn't be restarted with Jump support. Quit Spotify yourself and try again.")
            }
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = false // don't pull you out of what you're doing
        config.createsNewApplicationInstance = false
        let opened = DispatchSemaphore(value: 0)
        var openError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in openError = error; opened.signal() }
        _ = opened.wait(timeout: .now() + 30)
        if let openError { throw JumpError("Couldn't start Spotify: \(openError.localizedDescription)") }

        if !waitUntil(30, { SpotifyPage.available() }) { throw JumpError("Spotify started, but Jump couldn't connect to it.") }
        if resume {
            // Spotify reopens on the same song, paused; carry on where it was.
            Thread.sleep(forTimeInterval: 1.5)
            Spotify.runSync("play")
        }
    }

    @discardableResult
    static func waitUntil(_ seconds: TimeInterval, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return done()
    }
}

// MARK: - Playing

enum Player {
    private static let gate = NSLock() // one jump (or one playlist of an import) at a time

    static func exclusive<T>(_ work: () throws -> T) rethrows -> T { gate.lock(); defer { gate.unlock() }; return try work() }

    static func play(_ song: Song) throws {
        try exclusive {
            guard Spotify.isRunning else { throw JumpError("Spotify isn't running.") }
            let before = Spotify.stateSync()
            let link = Links.parse(song.link)
            let page = SpotifyPage.available()

            if let track = link.track, before?.id == track {
                if before?.playing == false { Spotify.runSync("play"); try started(before, song.title) }
                return
            }
            // Paused on this very song (known only by name): resume it.
            if link.track == nil, let before, !before.playing, before.name.caseInsensitiveCompare(song.title) == .orderedSame,
               before.artist.caseInsensitiveCompare(song.artist) == .orderedSame {
                Spotify.runSync("play")
                try started(nil, song.title)
                return
            }
            if let track = link.track, Links.safe(track) {
                let album = link.album.flatMap { Links.safe($0) ? $0 : nil }
                // In its playlist, so the rest of the playlist follows, else in its album.
                let contexts = [song.playlistLink, album ?? ""].filter { !$0.isEmpty }
                if page, (try? SpotifyPage.play(track: track, contexts: contexts)) == true {
                    try started(before, song.title)
                    return
                }
                // Without Jump support: AppleScript can bring Spotify forward, so hand the front back afterwards.
                let front = NSWorkspace.shared.frontmostApplication
                defer { giveBackFront(front) }
                // A playlist that no longer has the song starts another one: then the album it is.
                var playing = false
                if song.playlistLink.hasPrefix("spotify:playlist:"), Links.safe(song.playlistLink) {
                    Spotify.runSync("play track \"\(track)\" in context \"\(song.playlistLink)\"")
                    playing = SpotifyLauncher.waitUntil(2) { Spotify.stateSync()?.id == track }
                }
                if !playing {
                    var command = "play track \"\(track)\""
                    if let album { command += " in context \"\(album)\"" }
                    Spotify.runSync(command)
                }
                try started(before, song.title)
                return
            }
            guard page else {
                throw JumpError("“\(song.title)” needs Jump support: choose Restart Spotify with Jump support in the menu.")
            }
            let wanted = [(true, "Play \(song.title) by \(song.artist)"), (false, "Play \(song.title) by "), (false, "Play \(baseTitle(song.title))")]
            // From its album page the rest of the album follows; search covers songs recorded without one.
            var clicked = false
            if let album = link.album {
                clicked = try goAndClick("/album/" + album.dropFirst("spotify:album:".count), wanted)
            }
            if !clicked { clicked = try goAndClick(searchPath("\(song.artist) \(song.title)"), wanted) }
            if !clicked { throw JumpError("Couldn't find “\(song.title)” in Spotify.") }
            try started(before, song.title)
        }
    }

    // With Jump support, plays Spotify's top song for the text. Returns false when that isn't available.
    static func search(_ text: String) throws -> Bool {
        try exclusive {
            guard Spotify.isRunning else { throw JumpError("Spotify isn't running.") }
            guard SpotifyPage.available() else { return false }
            let before = Spotify.stateSync()
            if !(try goAndClick(searchPath(text), [(false, "Play ")])) { throw JumpError("Spotify found no songs for “\(text)”.") }
            try started(before, text)
            return true
        }
    }

    static func searchPath(_ text: String) -> String {
        "/search/" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text) + "/tracks"
    }

    private static func goAndClick(_ path: String, _ wanted: [(Bool, String)]) throws -> Bool {
        if try SpotifyPage.go(path) != "ok" { throw JumpError("Couldn't find the way around Spotify (Spotify may have changed).") }
        let start = Date()
        var noMatchSince: Date?
        while Date().timeIntervalSince(start) < 5 {
            let result = try SpotifyPage.click(wanted)
            if result == "clicked" { return true }
            // Rows keep appearing while the page loads; give up a second after the first ones showed without a match.
            if result == "no-match" {
                if let since = noMatchSince { if Date().timeIntervalSince(since) > 1 { return false } } else { noMatchSince = Date() }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func giveBackFront(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Spotify.bundleID else { return }
        DispatchQueue.main.async {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Spotify.bundleID { app.activate() }
        }
    }

    // Normally the song just starts; if Spotify ends up paused, press Play.
    private static func started(_ before: Spotify.State?, _ what: String) throws {
        let done = { () -> Bool in
            guard let s = Spotify.stateSync(), s.playing else { return false }
            return before == nil || s.id != before!.id || !before!.playing
        }
        if SpotifyLauncher.waitUntil(2.5, done) { return }
        Spotify.runSync("play")
        if SpotifyLauncher.waitUntil(2.5, done) { return }
        throw JumpError("Spotify didn't start “\(what)”.")
    }

    // "Riders On The Storm - 2021 Remaster" -> "Riders On The Storm", "Lions (Live)" -> "Lions"
    static func baseTitle(_ title: String) -> String {
        var cut = title.endIndex
        for marker in [" - ", " (", " ["] {
            if let r = title.range(of: marker), r.lowerBound > title.startIndex, r.lowerBound < cut { cut = r.lowerBound }
        }
        return String(title[..<cut])
    }
}

// MARK: - Importing playlists

enum PlaylistImport {
    // Reads playlists from Spotify's own services: Spotify's window doesn't move, navigate or scroll.
    static func run(_ history: History, progress: @escaping (String) -> Void) throws -> String {
        guard Spotify.isRunning else { throw JumpError("Spotify isn't running.") }
        guard SpotifyPage.available() else { throw JumpError("Spotify is running without Jump support.") }
        var lists = 0, found = 0, added = 0
        let library = try Player.exclusive { try SpotifyPage.library() }
        for list in library {
            lists += 1
            progress("Importing \(list.name) (\(lists)/\(library.count))…")
            // One playlist per turn, so a Jump in the meantime doesn't wait; one retry, since a call occasionally
            // fails, inside Spotify's page too (seen once in 92 playlists, fine the next time).
            let songs = try Player.exclusive { () -> [Song] in
                do { return try SpotifyPage.songs(uri: list.uri, playlist: list.name) }
                catch { return try SpotifyPage.songs(uri: list.uri, playlist: list.name) }
            }
            found += songs.count
            added += history.importSongs(songs)
        }
        return "Added \(added) new songs to Jump (\(found) songs in \(lists) playlists)."
    }
}

// MARK: - HUD

// A one-line message at the top of the screen that fades away. Never takes focus, so it's safe over a game.
final class HUD {
    static let shared = HUD()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)
        panel.contentView = effect
    }

    static func show(_ text: String) {
        DispatchQueue.main.async { shared.present(text) }
    }

    private func present(_ text: String) {
        generation += 1
        let mine = generation
        label.stringValue = text
        let screen = Screens.withMouse()
        let width = min(label.fittingSize.width + 32, screen.visibleFrame.width - 40)
        label.frame = NSRect(x: 16, y: 11, width: width - 32, height: 18)
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - 40 - 20, width: width, height: 40), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == mine else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; self.panel.animator().alphaValue = 0 }) {
                if self.generation == mine { self.panel.orderOut(nil) }
            }
        }
    }
}

enum Screens {
    static func withMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

// MARK: - Popup

// Takes keyboard input without activating this app, so the app you were in stays in front.
final class JumpPanel: NSPanel {
    var onControlKey: ((String) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           let chars = event.charactersIgnoringModifiers?.lowercased(), onControlKey?(chars) == true { return }
        super.sendEvent(event)
    }
}

final class JumpController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 640, headerHeight: CGFloat = 52, rowHeight: CGFloat = 46, maxRows = 10

    let history: History
    var onStartSpotify: (() -> Void)?
    private let panel: JumpPanel
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")
    private let list = JumpRowsView()
    private let separator = NSBox()

    private var all: [Song] = []
    fileprivate var results: [Ranked] = []
    fileprivate var selected = 0, top = 0
    fileprivate var now: Int64 = 0
    private var mostPlayed = false
    fileprivate var spotifyRunning = false
    fileprivate var pageReady = false
    private var anchorTop: CGFloat = 0
    private var opening = 0

    var isOpen: Bool { panel.isVisible }

    init(history: History) {
        self.history = history
        panel = JumpPanel(contentRect: NSRect(x: 0, y: 0, width: JumpController.width, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onControlKey = { [weak self] key in self?.controlKey(key) ?? false }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = "Jump to a song"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.autoresizingMask = [.width, .minYMargin]

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        hint.autoresizingMask = [.minXMargin, .minYMargin]

        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]

        list.controller = self
        list.autoresizingMask = [.width, .height]

        effect.addSubview(field)
        effect.addSubview(hint)
        effect.addSubview(separator)
        effect.addSubview(list)
        panel.contentView = effect
    }

    func toggle() { isOpen ? dismiss() : open() }

    func open() {
        all = history.snapshot()
        now = Strings.now()
        spotifyRunning = Spotify.isRunning
        pageReady = false
        field.stringValue = ""
        selected = 0; top = 0
        opening += 1
        let mine = opening
        // Checking the debugging port takes a moment; don't hold up the popup for it.
        DispatchQueue.global().async {
            let ready = SpotifyPage.available()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.opening == mine else { return }
                self.pageReady = ready
                self.list.needsDisplay = true
            }
        }

        let screen = Screens.withMouse().visibleFrame
        anchorTop = screen.maxY - screen.height / 5
        panel.setFrameOrigin(NSPoint(x: screen.midX - JumpController.width / 2, y: anchorTop - 200))
        refilter()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func dismiss() {
        opening += 1
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { dismiss() } // clicked somewhere else
    }

    fileprivate var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }
    fileprivate var hasSearchRow: Bool { spotifyRunning && !query.isEmpty }
    fileprivate var rowCount: Int { spotifyRunning ? results.count + (hasSearchRow ? 1 : 0) : 0 }

    private func refilter() {
        results = Ranker.rank(all, query: field.stringValue, mostPlayed: mostPlayed, now: now)
        hint.stringValue = (mostPlayed ? "Most played" : "Recent") + "  ⌃R"
        let rows = max(1, min(JumpController.maxRows, rowCount))
        let height = JumpController.headerHeight + CGFloat(rows) * JumpController.rowHeight + 8
        var frame = panel.frame
        frame.origin.y = anchorTop - height
        frame.size = NSSize(width: JumpController.width, height: height)
        panel.setFrame(frame, display: true)
        layout(height: height)
        list.needsDisplay = true
        panel.invalidateShadow()
    }

    private func layout(height: CGFloat) {
        let w = JumpController.width, header = JumpController.headerHeight
        hint.sizeToFit()
        hint.frame = NSRect(x: w - 16 - hint.frame.width, y: height - header + (header - hint.frame.height) / 2, width: hint.frame.width, height: hint.frame.height)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 16, y: height - header + (header - fieldHeight) / 2, width: hint.frame.minX - 28, height: fieldHeight)
        separator.frame = NSRect(x: 0, y: height - header, width: w, height: 1)
        list.frame = NSRect(x: 0, y: 4, width: w, height: height - header - 4)
    }

    func controlTextDidChange(_ obj: Notification) {
        selected = 0; top = 0
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(JumpController.maxRows)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-JumpController.maxRows)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): break
        default: return false
        }
        return true
    }

    // ⌃R switches ranking, ⌃U clears, ⌃N/⌃P move (also bound by the text system, but not in every layout).
    private func controlKey(_ key: String) -> Bool {
        switch key {
        case "r": mostPlayed.toggle(); selected = 0; top = 0; refilter()
        case "u": field.stringValue = ""; selected = 0; top = 0; refilter()
        case "n": move(1)
        case "p": move(-1)
        default: return false
        }
        return true
    }

    fileprivate func move(_ delta: Int) {
        guard rowCount > 0 else { return }
        selected = max(0, min(rowCount - 1, selected + delta))
        if selected < top { top = selected }
        if selected >= top + JumpController.maxRows { top = selected - JumpController.maxRows + 1 }
        list.needsDisplay = true
    }

    fileprivate func choose(_ index: Int? = nil) {
        if !spotifyRunning {
            dismiss()
            onStartSpotify?()
            return
        }
        let i = index ?? selected
        guard i < rowCount else { return }
        let text = query, song = i < results.count ? results[i].song : nil
        dismiss()
        DispatchQueue.global().async {
            do {
                if let song { try Player.play(song) }
                else if !(try Player.search(text)) {
                    // Without Jump support, all that's possible is opening the search in Spotify.
                    let escaped = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
                    if let url = URL(string: "spotify:search:" + escaped) { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                }
            } catch let e as JumpError {
                HUD.show(e.message)
            } catch {
                HUD.show("Something went wrong: \(error.localizedDescription)")
            }
        }
    }
}

final class JumpRowsView: NSView {
    weak var controller: JumpController?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let index = c.top + Int(p.y / JumpController.rowHeight)
        if index < c.rowCount { c.selected = index; needsDisplay = true; c.choose(index) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { controller?.move(event.scrollingDeltaY > 0 ? -1 : 1) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller else { return }
        let left: CGFloat = 16, right = bounds.width - 16, rh = JumpController.rowHeight
        let titleFont = NSFont.systemFont(ofSize: 14), subFont = NSFont.systemFont(ofSize: 11.5)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail

        if c.rowCount == 0 {
            let message = !c.spotifyRunning ? "Spotify isn't running. Press Enter to start it with Jump support."
                : "Play some songs. Jump remembers each one after 20 seconds."
            message.draw(in: NSRect(x: left, y: (rh - 16) / 2, width: right - left, height: 18),
                         withAttributes: [.font: subFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncating])
            return
        }

        let terms = Ranker.terms(c.query)
        for row in 0..<JumpController.maxRows {
            let index = c.top + row
            if index >= c.rowCount { break }
            let y = CGFloat(row) * rh
            if index == c.selected {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 6, y: y, width: bounds.width - 12, height: rh), xRadius: 6, yRadius: 6).fill()
            }

            if index >= c.results.count {
                let text = (c.pageReady ? "Search Spotify for “" : "Open Spotify search for “") + c.query + "”"
                text.draw(in: NSRect(x: left, y: y + (rh - 18) / 2, width: right - left, height: 20),
                          withAttributes: [.font: titleFont, .foregroundColor: NSColor.systemGreen, .paragraphStyle: truncating])
                continue
            }

            let s = c.results[index].song
            let meta = s.count == 0 ? "in " + (s.playlist.isEmpty ? "a playlist" : s.playlist)
                : Strings.age(c.now - s.lastPlayed) + (s.count > 1 ? "  ·  \(s.count)×" : "")
            let metaAttrs: [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: NSColor.secondaryLabelColor]
            let metaWidth = min((meta as NSString).size(withAttributes: metaAttrs).width, 200)
            (meta as NSString).draw(in: NSRect(x: right - metaWidth, y: y + 8, width: metaWidth, height: 16), withAttributes: metaAttrs)

            let title = NSMutableAttributedString(string: s.title, attributes: [.font: titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating])
            let sub = NSMutableAttributedString(string: s.artist + (s.album.isEmpty ? "" : "  ·  " + s.album),
                                                attributes: [.font: subFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncating])
            if !terms.isEmpty {
                let green = NSColor.systemGreen, titleLength = title.length, artistLength = (s.artist as NSString).length
                _ = Ranker.score(s, terms,
                                 markTitle: { i in if i < titleLength { title.addAttribute(.foregroundColor, value: green, range: NSRange(location: i, length: 1)) } },
                                 markArtist: { i in if i < artistLength { sub.addAttribute(.foregroundColor, value: green, range: NSRange(location: i, length: 1)) } })
            }
            let width = right - left - metaWidth - 16
            title.draw(with: NSRect(x: left, y: y + 6, width: width, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            sub.draw(with: NSRect(x: left, y: y + 25, width: width, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

// MARK: - Self-test

enum JumpSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(Strings.fold("Communiqué") == Array("communique".utf16), "accents fold away")
        check(Strings.fold("Straße").count == "Straße".utf16.count, "folding keeps the length")
        check(Links.uri("https://xpui.app.spotify.com/album/2rCS6Xwx32V27pvgFzLzlT", kind: "album") == "spotify:album:2rCS6Xwx32V27pvgFzLzlT", "album id from link")
        check(Links.uri("https://xpui.app.spotify.com/artist/0WwSkZ7LtFUFjGjMZBMt6T", kind: "album") == nil, "artist link has no album id")
        check(Links.uri("/track/4Mfy?si=x", kind: "track") == "spotify:track:4Mfy", "track id from link")
        let both = Links.make(track: "spotify:track:T1", album: "spotify:album:A1")
        check(both == "spotify:track:T1 spotify:album:A1" && Links.parse(both).track == "spotify:track:T1" && Links.parse(both).album == "spotify:album:A1", "two-URI link parses")
        check(Links.merge("spotify:track:T1", "spotify:track:T2 spotify:album:A2") == "spotify:track:T1 spotify:album:A2", "merging keeps known URIs, adds new ones")
        check(Links.merge("", "") == "" && Links.parse("").track == nil, "empty link")
        check(Links.safe("spotify:track:4Mfy") && !Links.safe("spotify:track:\" & quit"), "only plain URIs go into AppleScript")

        let now: Int64 = 1_800_000_000
        let songs = [
            Song(lastPlayed: now - 600, count: 1, title: "Sultans Of Swing", artist: "Dire Straits").folded(),
            Song(lastPlayed: now - 60, count: 2, title: "Riders On The Storm - 2021 Remaster", artist: "The Doors").folded(),
            Song(lastPlayed: now - 30, count: 1, title: "Storm Front", artist: "Billy Joel").folded(),
            Song(lastPlayed: now - 10, count: 1, title: "Brainstorm", artist: "Hawkwind").folded(),
            Song(lastPlayed: now - 86400 * 90, count: 40, title: "Lions", artist: "Dire Straits").folded(),
        ]
        func titles(_ r: [Ranked]) -> String { r.map { $0.song.title }.joined(separator: "|") }
        check(titles(Ranker.rank(songs, query: "doors storm", mostPlayed: false, now: now)) == "Riders On The Storm - 2021 Remaster", "terms in any order across title and artist")
        check(titles(Ranker.rank(songs, query: "sltns", mostPlayed: false, now: now)) == "Sultans Of Swing", "letters in order match")
        check(titles(Ranker.rank(songs, query: "storm", mostPlayed: false, now: now)) == "Storm Front|Riders On The Storm - 2021 Remaster|Brainstorm",
              "word prefix beats substring, then most recent first")
        check(Ranker.rank(songs, query: "xyzzy", mostPlayed: false, now: now).isEmpty, "non-matches are left out")
        check(Ranker.rank(songs, query: "", mostPlayed: false, now: now).first?.song.title == "Brainstorm", "empty query: most recent first")
        check(Ranker.rank(songs, query: "", mostPlayed: true, now: now).first?.song.title == "Lions", "most played: frecency ranks the old favourite first")
        check(Ranker.frecency(songs[4], now: now) < 40 && Ranker.frecency(songs[1], now: now) > 1.9, "frecency fades with age")
        var marked = Set<Int>()
        _ = Ranker.score(songs[0], [Array("swing".utf16)], markTitle: { marked.insert($0) })
        check(marked.contains(11) && marked.contains(15) && !marked.contains(0), "match highlights the right letters")
        check(Ranker.rank([Song(title: "Été", artist: "X").folded()], query: "ete", mostPlayed: false, now: now).count == 1, "accented titles match plain letters")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sgh-selftest-\(getpid()).tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        let h = History(url: url)
        h.record(title: "Sultans Of Swing", artist: "Dire Straits", album: "Dire Straits", link: "spotify:track:T1", now: 100)
        h.record(title: "Tab\there", artist: "New\nline", album: "", link: "", now: 200)
        h.record(title: "sultans of swing", artist: "dire straits", album: "dire straits", link: "spotify:album:A1", now: 300)
        h.saveIfDirty()
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data("not a valid line\n".utf8)); handle.closeFile() }
        let loaded = History(url: url).snapshot()
        check(loaded.count == 2, "same song (any case) is one entry")
        check(loaded.count == 2 && loaded[0].count == 2 && loaded[0].lastPlayed == 300 && loaded[0].link == "spotify:track:T1 spotify:album:A1",
              "replay bumps count and time, merges links")
        check(loaded.count == 2 && loaded[1].title == "Tab here" && loaded[1].artist == "New line", "tabs and newlines are stripped")
        for i in 0..<6000 { h.record(title: "Song \(i)", artist: "Artist", album: "", link: "", now: 1000 + Int64(i)) }
        check(h.count == 6002 && h.snapshot().first?.title == "Song 5999", "history keeps growing past 5000 songs")

        let p = History(url: nil)
        p.record(title: "Lions", artist: "Dire Straits", album: "Dire Straits", link: "spotify:track:L1", now: 500)
        let added = p.importSongs([
            Song(title: "Lions", artist: "Dire Straits", album: "Dire Straits", link: "spotify:track:L1 spotify:album:A1", playlist: "Rock"),
            Song(title: "Jolene - Piano Version", artist: "Pianaura", album: "Piano", link: "spotify:album:A2", playlist: "Liked Songs"),
            Song(title: "Jolene - Piano Version", artist: "Pianaura", album: "Piano", link: "", playlist: "Piano"),
        ])
        let imported = p.snapshot()
        check(added == 1 && imported.count == 2, "import adds only new songs, once")
        check(imported[0].title == "Lions" && imported[0].count == 1 && imported[0].link == "spotify:track:L1 spotify:album:A1" && imported[0].playlist == "",
              "import fills in a played song's album link but leaves its plays alone")
        check(imported[1].count == 0 && imported[1].lastPlayed == 0 && imported[1].playlist == "Liked Songs", "imported song is unplayed, from its first playlist")
        check(Ranker.rank(imported, query: "", mostPlayed: false, now: now).first?.song.title == "Lions"
              && Ranker.rank(imported, query: "", mostPlayed: true, now: now).first?.song.title == "Lions", "played songs rank above imported ones")
        p.record(title: "Jolene - Piano Version", artist: "Pianaura", album: "Piano", link: "spotify:track:J1", now: 600)
        let after = p.snapshot()
        check(after[0].title == "Jolene - Piano Version" && after[0].count == 1 && after[0].link == "spotify:track:J1 spotify:album:A2",
              "playing an imported song makes it a normal one")
        let round = History.parse(History.format(imported))
        check(round.count == 2 && round[1].playlist == "Liked Songs" && History.parse("5\t1\tOld\tFormat\t\t\n").first?.playlist == "",
              "playlist survives saving; 6-column lines still load")
        let parsed = SpotifyPage.parseSongs(#"[["Lions","Dire Straits","Dire Straits","spotify:album:A1","spotify:track:L1"],["","x","y","spotify:album:A2","spotify:track:T"],["Odd","Someone","","not-a-uri",""]]"#, playlist: "Rock")
        check(parsed.count == 2 && parsed[0].link == "spotify:track:L1 spotify:album:A1" && parsed[0].album == "Dire Straits" && parsed[0].playlist == "Rock"
              && parsed[1].link == "", "imported songs parse; untitled rows and odd URIs are dropped")
        let t = History(url: nil)
        t.record(title: "Under Pressure", artist: "Queen", album: "Hot Space", link: "spotify:track:U1", now: 700)
        check(t.importSongs([Song(title: "Under Pressure", artist: "Queen, David Bowie", album: "Hot Space", link: "spotify:track:U1 spotify:album:H1", playlist: "Rock")]) == 0
              && t.snapshot()[0].link == "spotify:track:U1 spotify:album:H1", "import matches a played song by track ID even when artists are spelled differently")
        t.record(title: "Under Pressure", artist: "Queen, David Bowie", album: "Hot Space", link: "spotify:track:U1", now: 800)
        check(t.count == 1 && t.snapshot()[0].count == 2, "recording matches by track ID too")

        check(Links.isPlaylist("spotify:playlist:P1") && Links.isPlaylist("spotify:collection:tracks") && !Links.isPlaylist("spotify:album:A1")
              && !Links.isPlaylist("spotify:playlist:") && !Links.isPlaylist(""), "only playlists and Liked Songs are playlist links")
        let q = History(url: nil)
        q.record(title: "Lions", artist: "Dire Straits", album: "Dire Straits", link: "spotify:track:L1", now: 500)
        _ = q.importSongs([
            Song(title: "Lions", artist: "Dire Straits", album: "Dire Straits", link: "spotify:track:L1 spotify:album:A1", playlist: "Rock", playlistLink: "spotify:playlist:R1"),
            Song(title: "Jolene", artist: "Pianaura", album: "Piano", link: "spotify:track:J1", playlist: "Liked Songs", playlistLink: "spotify:collection:tracks"),
            Song(title: "Jolene", artist: "Pianaura", album: "Piano", link: "spotify:track:J1", playlist: "Piano", playlistLink: "spotify:playlist:P1"),
        ])
        var s = q.snapshot()
        check(s.count == 2 && s[0].playlist == "Rock" && s[0].playlistLink == "spotify:playlist:R1", "a played song without a playlist gets the imported one")
        check(s.count == 2 && s[1].playlist == "Liked Songs" && s[1].playlistLink == "spotify:collection:tracks", "an imported song keeps its first playlist")
        let saved = History.parse(History.format(s))
        check(saved.count == 2 && saved[1].playlistLink == "spotify:collection:tracks" && saved[0].playlistLink == "spotify:playlist:R1",
              "playlist links survive saving")
        q.record(title: "Jolene", artist: "Pianaura", album: "Piano", link: "spotify:track:J1", now: 600)
        check(q.snapshot()[0].title == "Jolene" && q.snapshot()[0].playlistLink == "spotify:collection:tracks", "playing it from elsewhere keeps its playlist")
        q.record(title: "Lions", artist: "Dire Straits, Someone", album: "Dire Straits", link: "spotify:track:L1 spotify:album:X",
                 playlist: "Road trip", playlistLink: "spotify:playlist:T1", now: 700)
        s = q.snapshot()
        check(q.count == 2 && s[0].count == 2 && s[0].link == "spotify:track:L1 spotify:album:A1" && s[0].playlist == "Road trip" && s[0].playlistLink == "spotify:playlist:T1",
              "playing it from a playlist moves it to that playlist")
        _ = q.importSongs([Song(title: "Lions", artist: "Dire Straits", album: "Dire Straits", link: "spotify:track:L1", playlist: "Rock", playlistLink: "spotify:playlist:R1")])
        check(q.snapshot()[0].playlistLink == "spotify:playlist:T1", "importing again doesn't take a song away from where it was played")
        let old = History(url: nil)
        _ = old.importSongs([Song(title: "Old", artist: "Import", playlist: "Piano")])
        _ = old.importSongs([Song(title: "Old", artist: "Import", playlist: "Rock", playlistLink: "spotify:playlist:R1"),
                             Song(title: "Old", artist: "Import", playlist: "Piano", playlistLink: "spotify:playlist:P1")])
        check(old.snapshot().first?.playlist == "Piano" && old.snapshot().first?.playlistLink == "spotify:playlist:P1",
              "re-importing an older history fills in the link of the playlist it already names")
        let legacy = History.parse("6\t1\tSeven\tColumns\t\tspotify:album:A1\tRock\n7\t1\tBad\tLink\t\t\tX\tnot-a-uri\n")
        check(legacy.count == 2 && legacy[0].playlist == "Rock" && legacy[0].playlistLink == "" && legacy[1].playlistLink == "",
              "7-column lines still load; odd playlist links are dropped")
        let withList = SpotifyPage.parseSongs(#"[["Lions","Dire Straits","Dire Straits","spotify:album:A1","spotify:track:L1"]]"#, playlist: "Rock", playlistLink: "spotify:playlist:R1")
        check(withList.first?.playlistLink == "spotify:playlist:R1", "imported songs know their playlist's link")
        let np = SpotifyPage.parseNowPlaying(#"["Lions","spotify:track:L1","spotify:album:A1","Rock","spotify:playlist:R1"]"#)
        check(np?.title == "Lions" && np?.track == "spotify:track:L1" && np?.album == "spotify:album:A1" && np?.playlist == "Rock" && np?.playlistLink == "spotify:playlist:R1",
              "the player's now playing parses")
        check(SpotifyPage.parseNowPlaying(#"["Lions","spotify:track:L1","spotify:album:A1","Lions Radio","spotify:artist:X"]"#)?.playlistLink == "",
              "playing from something other than a playlist records no playlist")
        let widget = SpotifyPage.parseNowPlaying(#"["Lions","/album/A1?x"]"#)
        check(widget?.album == "spotify:album:A1" && widget?.track == "" && SpotifyPage.parseNowPlaying("") == nil, "the widget's now playing still parses")
        check(Player.baseTitle("Riders On The Storm - 2021 Remaster") == "Riders On The Storm"
              && Player.baseTitle("Lions (Live)") == "Lions" && Player.baseTitle("Lions") == "Lions", "base title drops version suffixes")
        check(Player.searchPath("sultans of swing") == "/search/sultans%20of%20swing/tracks", "search path is escaped")
    }
}
