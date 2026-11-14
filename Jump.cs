// Jump - press a hotkey, type part of a song you've played, Enter plays it.
// Songs are recorded locally while Spotify plays; playback runs JavaScript inside Spotify
// through its debugging port (no Spotify Web API, no window activation). See docs/specs/2026-11-14-global-jump-design.md.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Net;
using System.Net.WebSockets;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// ---------------------------------------------------------------- history

class Song
{
    public long LastPlayed;  // unix seconds; 0 for a song only imported from a playlist
    public int Count;        // 0 for a song only imported from a playlist
    public string Title = "", Artist = "", Album = "", Link = "";
    public string Playlist = "";  // where an imported song came from (first playlist seen)
    public string FoldTitle, FoldArtist, FoldAlbum;  // lower-case, accents removed, same length as the originals

    public Song Fold()
    {
        FoldTitle = Strings.Fold(Title);
        FoldArtist = Strings.Fold(Artist);
        FoldAlbum = Strings.Fold(Album);
        return this;
    }

    public bool SameSong(string title, string artist, string album)
    {
        return string.Equals(Title, title, StringComparison.OrdinalIgnoreCase)
            && string.Equals(Artist, artist, StringComparison.OrdinalIgnoreCase)
            && string.Equals(Album, album, StringComparison.OrdinalIgnoreCase);
    }
}

// One line per song, newest first, imported-but-unplayed songs last:
// lastPlayed, count, title, artist, album, link, playlist (tab-separated).
class History
{
    readonly string path;
    readonly object gate = new object(), saving = new object();
    List<Song> songs = new List<Song>();
    bool dirty;

    public History(string path)
    {
        this.path = path;
        if (path != null && File.Exists(path))
        {
            try { songs = Parse(File.ReadAllLines(path, Encoding.UTF8)); }
            catch (IOException) { }
        }
    }

    public int Count { get { lock (gate) return songs.Count; } }

    // Songs are never changed in place, so callers can use the copy from any thread.
    public List<Song> Snapshot() { lock (gate) return new List<Song>(songs); }

    public void Record(string title, string artist, string album, string link, long now)
    {
        lock (gate)
        {
            int count = 0;
            string keepLink = link, playlist = "";
            int i = songs.FindIndex(s => s.SameSong(title, artist, album));
            if (i >= 0)
            {
                count = songs[i].Count;
                if (keepLink == "") keepLink = songs[i].Link;
                playlist = songs[i].Playlist;
                songs.RemoveAt(i);
            }
            songs.Insert(0, new Song { LastPlayed = now, Count = count + 1, Title = title, Artist = artist, Album = album, Link = keepLink, Playlist = playlist }.Fold());
            dirty = true;
        }
    }

    // Adds playlist songs you haven't played yet, after everything you have. Returns how many were new.
    public int Import(IEnumerable<Song> found)
    {
        lock (gate)
        {
            var known = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < songs.Count; i++) known[Key(songs[i])] = i;
            int added = 0;
            foreach (var f in found)
            {
                int i;
                if (known.TryGetValue(Key(f), out i))
                {
                    // Already known: just fill in what's missing.
                    Song s = songs[i];
                    if ((s.Link == "" && f.Link != "") || (s.Playlist == "" && s.Count == 0))
                        songs[i] = new Song { LastPlayed = s.LastPlayed, Count = s.Count, Title = s.Title, Artist = s.Artist, Album = s.Album,
                            Link = s.Link != "" ? s.Link : f.Link, Playlist = s.Playlist != "" ? s.Playlist : f.Playlist }.Fold();
                    continue;
                }
                known[Key(f)] = songs.Count;
                songs.Add(new Song { Title = f.Title, Artist = f.Artist, Album = f.Album, Link = f.Link, Playlist = f.Playlist }.Fold());
                added++;
            }
            if (added > 0) dirty = true;
            return added;
        }
    }

    static string Key(Song s) { return s.Title + "\t" + s.Artist + "\t" + s.Album; }

    public void Clear()
    {
        lock (gate) { songs.Clear(); dirty = true; }
        SaveIfDirty();
    }

    public void SaveIfDirty()
    {
        lock (saving) // the timer saves in the background; quitting saves on the main thread
        {
            string[] lines;
            lock (gate)
            {
                if (!dirty || path == null) return;
                lines = Format(songs);
                dirty = false;
            }
            // Write a temp file and swap it in, so a crash never leaves half a history.
            string temp = path + ".tmp";
            File.WriteAllLines(temp, lines, new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temp, path, null);
            else File.Move(temp, path);
        }
    }

    public static List<Song> Parse(IEnumerable<string> lines)
    {
        var result = new List<Song>();
        foreach (var line in lines)
        {
            string[] f = line.Split('\t');
            long last; int count;
            if (f.Length < 6 || !long.TryParse(f[0], out last) || !int.TryParse(f[1], out count) || f[2] == "") continue;
            result.Add(new Song { LastPlayed = last, Count = count, Title = f[2], Artist = f[3], Album = f[4], Link = f[5],
                Playlist = f.Length > 6 ? f[6] : "" }.Fold());
        }
        return result;
    }

    public static string[] Format(List<Song> songs)
    {
        var lines = new string[songs.Count];
        for (int i = 0; i < songs.Count; i++)
        {
            Song s = songs[i];
            lines[i] = s.LastPlayed + "\t" + s.Count + "\t" + Clean(s.Title) + "\t" + Clean(s.Artist) + "\t" + Clean(s.Album) + "\t" + Clean(s.Link) + "\t" + Clean(s.Playlist);
        }
        return lines;
    }

    static string Clean(string s) { return s.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '); }
}

static class Strings
{
    // Lower-case and strip accents one character at a time, so match positions map back onto the original.
    public static string Fold(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            string d = c.ToString().Normalize(NormalizationForm.FormD);
            sb.Append(char.ToLowerInvariant(d.Length > 0 ? d[0] : c));
        }
        return sb.ToString();
    }

    // Spotify's window title is "Artist - Title" while playing and "Spotify Premium" etc. while paused.
    // Song titles often contain " - " too ("Riders On The Storm - 2021 Remaster"), so split at the first one.
    public static bool SplitTitle(string windowTitle, out string artist, out string title)
    {
        artist = title = null;
        int i = windowTitle == null ? -1 : windowTitle.IndexOf(" - ", StringComparison.Ordinal);
        if (i <= 0 || i + 3 >= windowTitle.Length) return false;
        artist = windowTitle.Substring(0, i);
        title = windowTitle.Substring(i + 3);
        return true;
    }

    public static string Age(long seconds)
    {
        if (seconds < 60) return "now";
        if (seconds < 3600) return seconds / 60 + " m";
        if (seconds < 86400) return seconds / 3600 + " h";
        if (seconds < 86400 * 7) return seconds / 86400 + " d";
        if (seconds < 86400 * 60) return seconds / (86400 * 7) + " w";
        if (seconds < 86400 * 365) return seconds / (86400 * 30) + " mo";
        return seconds / (86400 * 365) + " y";
    }

    public static long Now() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds; }
}

// Watches Spotify's window title and records a song once it has played for 20 seconds.
class Recorder
{
    const int RequiredSeconds = 20;
    readonly History history;
    readonly Timer timer = new Timer { Interval = 1000 };
    string current, lastRecorded;
    DateTime since;
    volatile bool busy;

    public Recorder(History history)
    {
        this.history = history;
        timer.Tick += delegate { Tick(); };
        timer.Start();
    }

    public void Stop() { timer.Stop(); }

    void Tick()
    {
        IntPtr hwnd = Spotify.MainWindow();
        string title = hwnd == IntPtr.Zero ? null : Spotify.Title(hwnd);
        string artist, song;
        if (!Strings.SplitTitle(title, out artist, out song)) { current = null; return; }
        if (title != current) { current = title; since = DateTime.UtcNow; return; }
        // Pausing and resuming the same song shouldn't count it twice.
        if (busy || title == lastRecorded || (DateTime.UtcNow - since).TotalSeconds < RequiredSeconds) return;

        busy = true;
        lastRecorded = title;
        long now = Strings.Now();
        System.Threading.ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                // With Jump support the now-playing widget gives the exact title and the album; it also
                // tells where the artist ends, since either can contain " - ".
                NowPlaying info = null;
                if (SpotifyPage.Available())
                {
                    try { info = SpotifyPage.ReadNowPlaying(""); } catch (JumpException) { }
                    if (info != null && title.EndsWith(" - " + info.Title, StringComparison.Ordinal))
                        info.Artist = title.Substring(0, title.Length - info.Title.Length - 3);
                    else info = null;
                }
                if (info == null) info = new NowPlaying { Title = song, Artist = artist, Link = "" };
                history.Record(info.Title, info.Artist, "", info.Link, now);
            }
            catch (Exception) { } // Spotify closed mid-way: nothing worth recording
            finally { busy = false; }
        });
    }
}

// ---------------------------------------------------------------- ranking

class Ranked
{
    public Song Song;
    public int Score;
    public double Order; // tie-breaker: last played or frecency, worked out once per search
}

static class Ranker
{
    const int WordPrefix = 100, Substring = 60, Subsequence = 20, TitleBonus = 20, AllInTitleBonus = 30;
    public const int Limit = 500; // more than anyone scrolls through; keeps big histories instant

    public static List<Ranked> Rank(List<Song> songs, string query, bool mostPlayed, long now)
    {
        string[] terms = Terms(query);
        var result = new List<Ranked>();
        foreach (var s in songs)
        {
            int score = terms.Length == 0 ? 0 : Score(s, terms, null, null);
            if (score >= 0) result.Add(new Ranked { Song = s, Score = score, Order = mostPlayed ? Frecency(s, now) : s.LastPlayed });
        }
        result.Sort(delegate(Ranked a, Ranked b)
        {
            if (a.Score != b.Score) return b.Score.CompareTo(a.Score);
            return b.Order.CompareTo(a.Order);
        });
        if (result.Count > Limit) result.RemoveRange(Limit, result.Count - Limit);
        return result;
    }

    public static string[] Terms(string query)
    {
        return Strings.Fold(query ?? "").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
    }

    // Play count, halved for every 30 days since the song was last played.
    public static double Frecency(Song s, long now)
    {
        double days = Math.Max(0, now - s.LastPlayed) / 86400.0;
        return s.Count * Math.Pow(0.5, days / 30);
    }

    // Returns -1 if some term matches nowhere. Masks (if given) get the matched characters.
    public static int Score(Song s, string[] terms, bool[] titleMask, bool[] artistMask)
    {
        int total = 0;
        bool allInTitle = true;
        foreach (string term in terms)
        {
            int t = Match(s.FoldTitle, term, null);
            int a = Match(s.FoldArtist, term, null);
            int b = Match(s.FoldAlbum, term, null);
            int best = Math.Max(t, Math.Max(a, b));
            if (best == 0) return -1;
            if (t == best)
            {
                total += t + TitleBonus;
                if (titleMask != null) Match(s.FoldTitle, term, titleMask);
            }
            else
            {
                allInTitle = false;
                total += best;
                if (a == best && artistMask != null) Match(s.FoldArtist, term, artistMask);
            }
        }
        return terms.Length > 0 && allInTitle ? total + AllInTitleBonus : total;
    }

    // Word prefix ("sto" in "Riders On The Storm") beats substring ("orm") beats letters in order ("sltns").
    public static int Match(string hay, string term, bool[] mask)
    {
        if (hay.Length == 0) return 0;
        int first = -1;
        for (int i = hay.IndexOf(term, StringComparison.Ordinal); i >= 0; i = hay.IndexOf(term, i + 1, StringComparison.Ordinal))
        {
            if (first < 0) first = i;
            if (i == 0 || !char.IsLetterOrDigit(hay[i - 1]))
            {
                Mark(mask, i, term.Length);
                return WordPrefix;
            }
        }
        if (first >= 0)
        {
            Mark(mask, first, term.Length);
            return Substring;
        }
        if (term.Length < 3) return 0;
        var positions = new List<int>();
        int p = 0;
        foreach (char c in term)
        {
            p = hay.IndexOf(c, p);
            if (p < 0) return 0;
            positions.Add(p++);
        }
        if (mask != null) foreach (int i in positions) mask[i] = true;
        return Subsequence;
    }

    static void Mark(bool[] mask, int start, int length)
    {
        if (mask != null) for (int i = start; i < start + length; i++) mask[i] = true;
    }
}

// ---------------------------------------------------------------- popup

class JumpForm : Form
{
    const int MaxRows = 10;
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    readonly History history;
    readonly Action<Song> play;
    readonly Action<string> search;
    readonly Action startSpotify;
    readonly TextBox box = new TextBox();
    readonly Font titleFont, subFont, boxFont, hintFont;
    readonly int rowHeight, headerHeight, pad;
    Color back, fore, dim, accent, selection, border;

    List<Song> all = new List<Song>();
    List<Ranked> results = new List<Ranked>();
    int selected, top;
    bool mostPlayed, spotifyRunning, jumpReady;
    IntPtr previous;
    long now;

    public JumpForm(History history, Action<Song> play, Action<string> search, Action startSpotify)
    {
        this.history = history;
        this.play = play;
        this.search = search;
        this.startSpotify = startSpotify;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        DoubleBuffered = true;
        Text = "Jump";

        string face = SystemFonts.MessageBoxFont.Name;
        boxFont = new Font(face, 14f);
        titleFont = new Font(face, 11f);
        subFont = new Font(face, 9f);
        hintFont = new Font(face, 8.5f);
        pad = boxFont.Height / 2;
        headerHeight = boxFont.Height + pad * 2;
        rowHeight = titleFont.Height + subFont.Height + pad;
        using (var g = CreateGraphics()) Width = (int)(640 * g.DpiX / 96);

        ApplyTheme();
        box.BorderStyle = BorderStyle.None;
        box.Font = boxFont;
        box.BackColor = back;
        box.ForeColor = fore;
        box.Location = new Point(pad * 2, pad);
        box.Width = Width - pad * 5 - TextRenderer.MeasureText("Most played  Ctrl+R", hintFont).Width;
        box.TextChanged += delegate { selected = 0; top = 0; Refilter(); };
        box.KeyDown += OnBoxKeyDown;
        Controls.Add(box);
    }

    void ApplyTheme()
    {
        bool dark = false;
        using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            dark = key != null && (key.GetValue("AppsUseLightTheme") as int?) == 0;
        back = dark ? Color.FromArgb(32, 32, 32) : Color.FromArgb(250, 250, 250);
        fore = dark ? Color.FromArgb(240, 240, 240) : Color.FromArgb(20, 20, 20);
        dim = dark ? Color.FromArgb(150, 150, 150) : Color.FromArgb(110, 110, 110);
        accent = dark ? Color.FromArgb(0x1E, 0xD7, 0x60) : Color.FromArgb(0x10, 0x8A, 0x3E);
        selection = dark ? Color.FromArgb(55, 55, 55) : Color.FromArgb(228, 228, 228);
        border = dark ? Color.FromArgb(70, 70, 70) : Color.FromArgb(200, 200, 200);
        BackColor = back;
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int round = 2; // DWMWCP_ROUND: rounded corners on Windows 11, ignored elsewhere
        try { DwmSetWindowAttribute(Handle, 33, ref round, sizeof(int)); } catch (DllNotFoundException) { }
    }

    public void Open()
    {
        previous = GetForegroundWindow();
        all = history.Snapshot();
        spotifyRunning = Spotify.MainWindow() != IntPtr.Zero;
        jumpReady = spotifyRunning && SpotifyPage.Available();
        now = Strings.Now();
        box.Text = "";
        selected = top = 0;
        Refilter();

        Rectangle area = (previous != IntPtr.Zero ? Screen.FromHandle(previous) : Screen.PrimaryScreen).WorkingArea;
        Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + area.Height / 5);
        Show();
        Activate();
        SetForegroundWindow(Handle);
        box.Focus();
    }

    public void Dismiss(bool restoreFocus)
    {
        Hide();
        if (restoreFocus && previous != IntPtr.Zero) SetForegroundWindow(previous);
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (Visible) Dismiss(false); // clicked somewhere else: that window keeps the focus
    }

    void Refilter()
    {
        results = Ranker.Rank(all, box.Text, mostPlayed, now);
        int rows = Math.Max(1, Math.Min(MaxRows, RowCount));
        Height = headerHeight + rows * rowHeight + pad;
        Invalidate();
    }

    bool HasSearchRow { get { return jumpReady && box.Text.Trim() != ""; } }
    int RowCount { get { return jumpReady ? results.Count + (HasSearchRow ? 1 : 0) : 0; } }

    void MoveSelection(int delta)
    {
        if (RowCount == 0) return;
        selected = Math.Max(0, Math.Min(RowCount - 1, selected + delta));
        if (selected < top) top = selected;
        if (selected >= top + MaxRows) top = selected - MaxRows + 1;
        Invalidate();
    }

    void Choose()
    {
        if (!jumpReady)
        {
            // Enter on the "needs Spotify" message (re)starts Spotify with Jump support.
            Dismiss(true);
            startSpotify();
            return;
        }
        if (selected >= RowCount) return;
        Dismiss(true);
        if (selected < results.Count) play(results[selected].Song);
        else search(box.Text.Trim());
    }

    void OnBoxKeyDown(object sender, KeyEventArgs e)
    {
        bool handled = true;
        switch (e.KeyData)
        {
            case Keys.Down: case Keys.Control | Keys.N: MoveSelection(1); break;
            case Keys.Up: case Keys.Control | Keys.P: MoveSelection(-1); break;
            case Keys.PageDown: MoveSelection(MaxRows); break;
            case Keys.PageUp: MoveSelection(-MaxRows); break;
            case Keys.Enter: Choose(); break;
            case Keys.Escape: Dismiss(true); break;
            case Keys.Control | Keys.R: mostPlayed = !mostPlayed; selected = top = 0; Refilter(); break;
            case Keys.Control | Keys.U: box.Clear(); break;
            case Keys.Control | Keys.Back:
                int end = box.SelectionStart, start = end;
                while (start > 0 && box.Text[start - 1] == ' ') start--;
                while (start > 0 && box.Text[start - 1] != ' ') start--;
                box.Text = box.Text.Remove(start, end - start);
                box.SelectionStart = start;
                break;
            default: handled = false; break;
        }
        if (handled) { e.Handled = true; e.SuppressKeyPress = true; }
    }

    protected override void OnMouseWheel(MouseEventArgs e) { MoveSelection(e.Delta > 0 ? -1 : 1); }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        if (e.Y < headerHeight) return;
        int index = top + (e.Y - headerHeight) / rowHeight;
        if (index >= RowCount) return;
        selected = index;
        Choose();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        var flags = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
        using (var pen = new Pen(border)) g.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);

        string hint = (mostPlayed ? "Most played" : "Recent") + "  Ctrl+R";
        Size hintSize = TextRenderer.MeasureText(hint, hintFont);
        TextRenderer.DrawText(g, hint, hintFont, new Point(Width - pad * 2 - hintSize.Width, (headerHeight - hintSize.Height) / 2), dim, flags);
        using (var pen = new Pen(border)) g.DrawLine(pen, 0, headerHeight - 1, Width, headerHeight - 1);

        if (RowCount == 0)
        {
            string message = !spotifyRunning ? "Spotify isn't running. Press Enter to start it with Jump support."
                : !jumpReady ? "Jump needs Spotify started with Jump support. Press Enter to restart Spotify (a few seconds' pause)."
                : "Play some songs. Jump remembers each one after 20 seconds.";
            TextRenderer.DrawText(g, message, subFont, new Rectangle(pad * 2, headerHeight, Width - pad * 4, rowHeight), dim,
                flags | TextFormatFlags.VerticalCenter);
            return;
        }

        string[] terms = Ranker.Terms(box.Text);
        int left = pad * 2, right = Width - pad * 2;
        for (int row = 0; row < MaxRows && top + row < RowCount; row++)
        {
            int index = top + row, y = headerHeight + row * rowHeight;
            if (index == selected) using (var b = new SolidBrush(selection)) g.FillRectangle(b, 1, y, Width - 2, rowHeight);

            if (index >= results.Count)
            {
                TextRenderer.DrawText(g, "Search Spotify for “" + box.Text.Trim() + "”", titleFont,
                    new Rectangle(left, y, right - left, rowHeight), accent, flags | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                continue;
            }

            Song s = results[index].Song;
            int titleY = y + pad / 2, subY = titleY + titleFont.Height;
            string meta = s.Count == 0 ? "in " + (s.Playlist != "" ? s.Playlist : "a playlist")
                : Strings.Age(now - s.LastPlayed) + (s.Count > 1 ? "  ·  " + s.Count + "×" : "");
            int metaWidth = TextRenderer.MeasureText(meta, subFont).Width;
            TextRenderer.DrawText(g, meta, subFont, new Point(right - metaWidth, titleY + (titleFont.Height - subFont.Height) / 2), dim, flags);

            var titleMask = new bool[s.Title.Length];
            var artistMask = new bool[s.Artist.Length];
            if (terms.Length > 0) Ranker.Score(s, terms, titleMask, artistMask);
            int width = right - left - metaWidth - pad * 2;
            DrawHighlighted(g, s.Title, titleMask, titleFont, left, titleY, width, fore);
            DrawHighlighted(g, s.Artist + (s.Album != "" ? "  ·  " + s.Album : ""), artistMask, subFont, left, subY, width, dim);
        }
    }

    // Draws matched characters in the accent colour; falls back to plain text with an ellipsis when it doesn't fit.
    void DrawHighlighted(Graphics g, string text, bool[] mask, Font font, int x, int y, int width, Color color)
    {
        var flags = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
        if (TextRenderer.MeasureText(g, text, font, Size.Empty, flags).Width > width)
        {
            TextRenderer.DrawText(g, text, font, new Rectangle(x, y, width, font.Height), color, flags | TextFormatFlags.EndEllipsis);
            return;
        }
        int i = 0;
        while (i < text.Length)
        {
            bool hit = i < mask.Length && mask[i];
            int j = i;
            while (j < text.Length && (j < mask.Length && mask[j]) == hit) j++;
            string part = text.Substring(i, j - i);
            TextRenderer.DrawText(g, part, font, new Point(x, y), hit ? accent : color, flags);
            x += TextRenderer.MeasureText(g, part, font, Size.Empty, flags).Width;
            i = j;
        }
    }
}

// ---------------------------------------------------------------- talking to Spotify's page

class JumpException : Exception
{
    public JumpException(string message) : base(message) { }
}

class NowPlaying
{
    public string Title, Artist, Link;
}

// Spotify's desktop app is a web page in an embedded Chromium. Started with --remote-debugging-port,
// it lets this app run JavaScript inside that page (Chrome DevTools Protocol, 127.0.0.1 only). Navigating
// and clicking from inside the page never activates Spotify's window, so Jump doesn't pull you out of
// a game the way opening spotify: links or UI Automation clicks do.
static class SpotifyPage
{
    public const int Port = 9229;
    static readonly object gate = new object();
    static readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    static ClientWebSocket socket;
    static int nextId;

    // Installed into the page on demand. Spotify navigates with React Router's history object, which
    // isn't on window, so find it in React's component tree. Rows on screen before navigating are
    // marked, so a click can't land on the previous page while the new one renders.
    const string Helper = @"
if (!window.__sgh || window.__sgh.v !== 2) window.__sgh = (() => {
  let nav = null;
  const router = () => {
    if (nav) return nav;
    const host = [...document.querySelectorAll('body *')].find(e => Object.keys(e).some(k => k.startsWith('__reactFiber$')));
    if (!host) return null;
    let f = host[Object.keys(host).find(k => k.startsWith('__reactFiber$'))];
    while (f.return) f = f.return;
    const stack = [f];
    while (stack.length) {
      const x = stack.pop(), p = x.memoizedProps;
      if (p && p.history && typeof p.history.push === 'function') return nav = p.history;
      if (x.sibling) stack.push(x.sibling);
      if (x.child) stack.push(x.child);
    }
    return null;
  };
  const rows = () => [...document.querySelectorAll('[data-testid=""tracklist-row""] button[aria-label]')];
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const scrollerOf = e => {
    while (e && !(/(auto|scroll)/.test(getComputedStyle(e).overflowY) && e.scrollHeight > e.clientHeight)) e = e.parentElement;
    return e;
  };
  // Spotify only renders the rows in view, so step through a list and collect as it goes.
  const scrollAll = async (scroller, grab) => {
    if (scroller) scroller.scrollTop = 0;
    await sleep(150); grab();
    for (let i = 0; scroller && i < 5000 && scroller.scrollTop + scroller.clientHeight < scroller.scrollHeight - 2; i++) {
      scroller.scrollTop += scroller.clientHeight * 0.8;
      await sleep(80); grab();
    }
    await sleep(200); grab();
  };
  return {
    v: 2,
    path() {
      const h = router();
      return h ? h.location.pathname + (h.location.search || '') : '/';
    },
    // Every playlist in Your Library, as [uri, name] pairs.
    async library() {
      const grid = document.querySelector('[role=""grid""][aria-label=""Your Library""]');
      if (!grid) return 'no-library';
      const scroller = scrollerOf(grid), start = scroller ? scroller.scrollTop : 0, seen = new Map();
      await scrollAll(scroller, () => grid.querySelectorAll('[aria-labelledby^=""listrow-title-spotify:""]').forEach(e => {
        const id = e.getAttribute('aria-labelledby').split(' ')[0], uri = id.slice('listrow-title-'.length);
        const title = document.getElementById(id);
        if (!seen.has(uri)) seen.set(uri, title ? title.textContent.trim() : '');
      }));
      if (scroller) scroller.scrollTop = start;
      return JSON.stringify([...seen]);
    },
    // The songs on the page just navigated to, as [title, artist, album link] triples.
    async collect() {
      const fresh = () => [...document.querySelectorAll('[data-testid=""tracklist-row""]')].filter(r => {
        const b = r.querySelector('button[aria-label]');
        return b && !b.dataset.sghOld;
      });
      for (let i = 0; i < 60 && !fresh().length; i++) await sleep(100);
      if (!fresh().length) return '[]';
      const seen = new Map();
      await scrollAll(scrollerOf(fresh()[0]), () => fresh().forEach(r => {
        const row = r.closest('[role=""row""]'), key = row && row.getAttribute('aria-rowindex');
        const play = r.querySelector('button[aria-label^=""Play ""]'), album = r.querySelector('a[href*=""/album/""]');
        if (!key || !play || !album || seen.has(key)) return; // podcast episodes and local files have no album
        const label = play.getAttribute('aria-label').slice(5), by = label.lastIndexOf(' by ');
        if (by <= 0) return;
        seen.set(key, [label.slice(0, by), label.slice(by + 4), album.getAttribute('href')]);
      }));
      return JSON.stringify([...seen.values()]);
    },
    go(path) {
      const h = router();
      if (!h) return 'no-router';
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
    nowPlaying() {
      const w = document.querySelector('[data-testid=""now-playing-widget""]');
      const a = w && w.querySelector('a[href*=""/album/""]');
      return a ? a.textContent.trim() + '\n' + a.getAttribute('href') : '';
    }
  };
})();
";

    public static bool Available()
    {
        try { return PageUrl(400) != null; }
        catch (WebException) { return false; }
    }

    static string PageUrl(int timeoutMs)
    {
        var request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + Port + "/json/list");
        request.Timeout = timeoutMs;
        request.Proxy = null;
        using (var response = request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
            foreach (Dictionary<string, object> target in (object[])json.DeserializeObject(reader.ReadToEnd()))
                if ((string)target["type"] == "page" && ((string)target["url"]).StartsWith("https://xpui.app.spotify.com", StringComparison.Ordinal))
                    return (string)target["webSocketDebuggerUrl"];
        return null;
    }

    public static string Go(string path) { return Eval("__sgh.go(" + json.Serialize(path) + ")"); }

    // wanted: (exact, label) pairs in order of preference, e.g. (true, "Play Lions by Dire Straits").
    public static string Click(params object[][] wanted) { return Eval("__sgh.click(" + json.Serialize(wanted) + ")"); }

    public static NowPlaying ReadNowPlaying(string artist)
    {
        string[] parts = Eval("__sgh.nowPlaying()").Split('\n');
        string id = parts.Length == 2 ? AlbumId(parts[1]) : null;
        if (id == null) return null;
        return new NowPlaying { Title = parts[0], Artist = artist, Link = "spotify:album:" + id };
    }

    public static string AlbumId(string url)
    {
        int i = url == null ? -1 : url.IndexOf("/album/", StringComparison.Ordinal);
        if (i < 0) return null;
        string id = url.Substring(i + 7);
        int end = id.IndexOfAny(new[] { '?', '/', '#' });
        return end >= 0 ? id.Substring(0, end) : id;
    }

    public static string CurrentPath() { return Eval("__sgh.path()"); }

    // Your Library's playlists (and Liked Songs) as uri -> name, in library order.
    public static List<KeyValuePair<string, string>> Library()
    {
        string result = Eval("__sgh.library()", 60000);
        if (result == "no-library") throw new JumpException("Open Your Library in Spotify's sidebar, then import again.");
        var lists = new List<KeyValuePair<string, string>>();
        foreach (object[] pair in (object[])json.DeserializeObject(result))
            lists.Add(new KeyValuePair<string, string>((string)pair[0], (string)pair[1]));
        return lists;
    }

    // The songs on the page Go() just opened. Big playlists take a while: about 3 seconds per 300 songs.
    public static List<Song> Collect(string playlist)
    {
        var songs = new List<Song>();
        foreach (object[] row in (object[])json.DeserializeObject(Eval("__sgh.collect()", 300000)))
        {
            string id = AlbumId((string)row[2]);
            songs.Add(new Song { Title = (string)row[0], Artist = (string)row[1], Link = id == null ? "" : "spotify:album:" + id, Playlist = playlist });
        }
        return songs;
    }

    static string Eval(string expression) { return Eval(expression, 5000); }

    static string Eval(string expression, int timeoutMs)
    {
        lock (gate)
        {
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    if (socket == null || socket.State != WebSocketState.Open) Connect();
                    return Send(Helper + expression, timeoutMs);
                }
                catch (Exception e)
                {
                    if (e is JumpException) throw;
                    Drop();
                    if (attempt == 1) throw new JumpException("Couldn't reach Spotify: " + e.GetBaseException().Message);
                }
            }
        }
    }

    static void Connect()
    {
        string url = PageUrl(1000);
        if (url == null) throw new JumpException("Spotify's page isn't ready yet.");
        socket = new ClientWebSocket();
        using (var cts = new System.Threading.CancellationTokenSource(3000))
            socket.ConnectAsync(new Uri(url), cts.Token).Wait();
    }

    static void Drop()
    {
        if (socket != null) socket.Dispose();
        socket = null;
    }

    static string Send(string expression, int timeoutMs)
    {
        int id = ++nextId;
        string message = json.Serialize(new Dictionary<string, object>
        {
            { "id", id },
            { "method", "Runtime.evaluate" },
            { "params", new Dictionary<string, object> { { "expression", expression }, { "returnByValue", true }, { "awaitPromise", true } } }
        });
        using (var cts = new System.Threading.CancellationTokenSource(timeoutMs))
        {
            socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(message)), WebSocketMessageType.Text, true, cts.Token).Wait();
            var buffer = new byte[64 * 1024];
            while (true)
            {
                // Decode once at the end: a character can be split across two chunks.
                var bytes = new MemoryStream();
                WebSocketReceiveResult part;
                do
                {
                    part = socket.ReceiveAsync(new ArraySegment<byte>(buffer), cts.Token).Result;
                    bytes.Write(buffer, 0, part.Count);
                } while (!part.EndOfMessage);

                var reply = (Dictionary<string, object>)json.DeserializeObject(Encoding.UTF8.GetString(bytes.ToArray()));
                if (!reply.ContainsKey("id") || (int)reply["id"] != id) continue; // an event, not our answer
                var outer = (Dictionary<string, object>)reply["result"];
                if (outer.ContainsKey("exceptionDetails")) throw new JumpException("Spotify's page didn't understand this app (Spotify may have changed).");
                var result = (Dictionary<string, object>)outer["result"];
                return result.ContainsKey("value") ? Convert.ToString(result["value"]) : "";
            }
        }
    }
}

// Starts Spotify with the debugging port Jump needs, or restarts it if it's running without.
static class SpotifyLauncher
{
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    // StartSpotify=true: when this app starts (usually at login), make sure Spotify has Jump support.
    // Spotify's own autostart often wins the race and starts it without the port; a Spotify that
    // started in the last few minutes and isn't playing yet is restarted, anything else is left alone
    // (Jump offers a restart when you use it).
    public static void EnsureAtStartup()
    {
        for (int attempt = 0; attempt < 2; attempt++)
        {
            if (SpotifyPage.Available()) return;
            IntPtr hwnd = Spotify.MainWindow();
            if (hwnd != IntPtr.Zero)
            {
                string artist, title;
                if (Strings.SplitTitle(Spotify.Title(hwnd), out artist, out title) || !StartedRecently(hwnd)) return;
            }
            try { Start(); return; }
            catch (JumpException)
            {
                // Spotify's own autostart may have launched a copy without the port at the same moment; try once more.
                if (attempt == 1) throw;
            }
        }
    }

    static bool StartedRecently(IntPtr hwnd)
    {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try
        {
            using (var p = Process.GetProcessById((int)pid))
                return DateTime.Now - p.StartTime < TimeSpan.FromMinutes(3);
        }
        catch (Exception) { return false; }
    }

    public static string ExePath()
    {
        foreach (var p in Process.GetProcessesByName("Spotify"))
        {
            try { return p.MainModule.FileName; }
            catch (Exception) { }
            finally { p.Dispose(); }
        }
        string classic = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Spotify\Spotify.exe");
        return File.Exists(classic) ? classic : null;
    }

    public static void Start()
    {
        string exe = ExePath();
        if (exe == null) throw new JumpException("Couldn't find Spotify. Jump works with Spotify installed from spotify.com.");
        if (exe.IndexOf(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase) >= 0)
            throw new JumpException("The Microsoft Store version of Spotify can't be started with Jump support. Install Spotify from spotify.com.");

        bool resume = false;
        IntPtr hwnd = Spotify.MainWindow();
        if (hwnd != IntPtr.Zero)
        {
            string artist, title;
            resume = Strings.SplitTitle(Spotify.Title(hwnd), out artist, out title);
            foreach (var p in Process.GetProcessesByName("Spotify"))
            {
                try { p.Kill(); p.WaitForExit(5000); }
                catch (Exception) { } // helper processes exit with the main one
                finally { p.Dispose(); }
            }
        }

        // Minimized, so a restart in the middle of a game doesn't bring Spotify to the front.
        Process.Start(new ProcessStartInfo(exe, "--minimized --remote-debugging-port=" + SpotifyPage.Port) { UseShellExecute = false });
        var sw = Stopwatch.StartNew();
        while (!SpotifyPage.Available())
        {
            if (sw.ElapsedMilliseconds > 30000) throw new JumpException("Spotify started, but Jump couldn't connect to it.");
            System.Threading.Thread.Sleep(500);
        }
        if (resume)
        {
            // Spotify reopens on the same song, paused; carry on where it was.
            sw.Restart();
            while (Spotify.MainWindow() == IntPtr.Zero && sw.ElapsedMilliseconds < 10000) System.Threading.Thread.Sleep(200);
            System.Threading.Thread.Sleep(1500);
            Spotify.Send(Spotify.Play);
        }
    }
}

// While Spotify is minimized or hidden in the tray, Chromium stops rendering it and scrolling loads
// nothing. For an import, show it without activating it, off-screen and behind everything, then put
// it back exactly as it was.
class OffScreen : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct WINDOWPLACEMENT { public int length, flags, showCmd; public POINT min, max; public RECT normal; }
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    const int SW_HIDE = 0, SW_SHOWMINIMIZED = 2, SW_SHOWNOACTIVATE = 4, SW_SHOWMINNOACTIVE = 7;
    const uint SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOACTIVATE = 0x10;

    readonly IntPtr hwnd;
    readonly bool moved, wasHidden;
    WINDOWPLACEMENT original;

    public OffScreen(IntPtr hwnd)
    {
        this.hwnd = hwnd;
        wasHidden = !IsWindowVisible(hwnd);
        if (!wasHidden && !IsIconic(hwnd)) return; // on screen already: it renders, leave it alone
        original = new WINDOWPLACEMENT();
        original.length = Marshal.SizeOf(original);
        GetWindowPlacement(hwnd, ref original);
        var away = original;
        int width = original.normal.Right - original.normal.Left, height = original.normal.Bottom - original.normal.Top;
        away.normal = new RECT { Left = -32000, Top = -32000, Right = -32000 + width, Bottom = -32000 + height };
        away.showCmd = SW_SHOWNOACTIVATE;
        away.flags = 0;
        SetWindowPlacement(hwnd, ref away);
        SetWindowPos(hwnd, (IntPtr)1 /* HWND_BOTTOM */, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
        moved = true;
    }

    public void Dispose()
    {
        if (!moved) return;
        if (original.showCmd == SW_SHOWMINIMIZED) original.showCmd = SW_SHOWMINNOACTIVE;
        SetWindowPlacement(hwnd, ref original);
        if (wasHidden) ShowWindow(hwnd, SW_HIDE);
    }
}

// Fills the Jump history with the songs in your playlists and Liked Songs, as never-played songs.
static class PlaylistImport
{
    public static string Run(History history, Action<string> progress)
    {
        IntPtr hwnd = Spotify.MainWindow();
        if (hwnd == IntPtr.Zero) throw new JumpException("Spotify isn't running.");
        if (!SpotifyPage.Available()) throw new JumpException("Spotify is running without Jump support. Open Jump and press Enter to restart it, then import again.");

        int lists = 0, found = 0, added = 0;
        using (new OffScreen(hwnd))
        {
            string back = null;
            var library = new List<KeyValuePair<string, string>>();
            Player.Exclusive(delegate { back = SpotifyPage.CurrentPath(); library = SpotifyPage.Library(); });
            var playlists = library.FindAll(l => PagePath(l.Key) != null);
            foreach (var list in playlists)
            {
                progress("Importing " + list.Value + " (" + (++lists) + "/" + playlists.Count + ")");
                // One playlist at a time, so a Jump in the meantime waits only seconds.
                List<Song> songs = null;
                Player.Exclusive(delegate
                {
                    SpotifyPage.Go(PagePath(list.Key));
                    songs = SpotifyPage.Collect(list.Value);
                });
                found += songs.Count;
                added += history.Import(songs);
            }
            Player.Exclusive(delegate { SpotifyPage.Go(back); });
        }
        return "Added " + added + " new songs to Jump (" + found + " songs in " + lists + " playlists).";
    }

    // Playlists and Liked Songs; albums, artists and podcasts in the library are left out.
    public static string PagePath(string uri)
    {
        if (uri.StartsWith("spotify:playlist:", StringComparison.Ordinal)) return "/playlist/" + uri.Substring(17);
        if (uri == "spotify:collection" || uri == "spotify:collection:tracks" || uri.EndsWith(":collection", StringComparison.Ordinal)) return "/collection/tracks";
        return null;
    }
}

static class Player
{
    static readonly object gate = new object(); // one jump (or one playlist of an import) at a time

    public static void Exclusive(Action work) { lock (gate) work(); }

    public static void Play(Song song)
    {
        lock (gate)
        {
            IntPtr hwnd = RequireSpotify();
            string before = Spotify.Title(hwnd);
            if (before == song.Artist + " - " + song.Title) { Spotify.Send(Spotify.Play); return; }

            var wanted = new[]
            {
                new object[] { true, "Play " + song.Title + " by " + song.Artist },
                new object[] { false, "Play " + song.Title + " by " },
                new object[] { false, "Play " + BaseTitle(song.Title) },
            };
            // From its album page the rest of the album follows; search covers songs recorded without one.
            string album = SpotifyPage.AlbumId(song.Link);
            bool clicked = album != null && GoAndClick("/album/" + album, wanted);
            if (!clicked) clicked = GoAndClick(SearchPath(song.Artist + " " + song.Title), wanted);
            if (!clicked) throw new JumpException("Couldn't find “" + song.Title + "” in Spotify.");
            Started(hwnd, before, song.Title);
        }
    }

    public static void Search(string text)
    {
        lock (gate)
        {
            IntPtr hwnd = RequireSpotify();
            string before = Spotify.Title(hwnd);
            if (!GoAndClick(SearchPath(text), new object[] { false, "Play " }))
                throw new JumpException("Spotify found no songs for “" + text + "”.");
            Started(hwnd, before, text);
        }
    }

    static string SearchPath(string text) { return "/search/" + Uri.EscapeDataString(text) + "/tracks"; }

    static IntPtr RequireSpotify()
    {
        IntPtr hwnd = Spotify.MainWindow();
        if (hwnd == IntPtr.Zero) throw new JumpException("Spotify isn't running.");
        if (!SpotifyPage.Available()) throw new JumpException("Spotify is running without Jump support. Open Jump and press Enter to restart it.");
        return hwnd;
    }

    static bool GoAndClick(string path, params object[][] wanted)
    {
        if (SpotifyPage.Go(path) != "ok") throw new JumpException("Couldn't find the way around Spotify (Spotify may have changed).");
        var sw = Stopwatch.StartNew();
        long noMatchSince = -1;
        while (sw.ElapsedMilliseconds < 5000)
        {
            string result = SpotifyPage.Click(wanted);
            if (result == "clicked") return true;
            // Rows keep appearing while the page loads; give up a second after the first ones showed without a match.
            if (result == "no-match")
            {
                if (noMatchSince < 0) noMatchSince = sw.ElapsedMilliseconds;
                else if (sw.ElapsedMilliseconds - noMatchSince > 1000) return false;
            }
            System.Threading.Thread.Sleep(100);
        }
        return false;
    }

    // Clicking a row normally starts the song; if Spotify ends up paused, press Play.
    static void Started(IntPtr hwnd, string before, string what)
    {
        if (WaitForTitle(hwnd, 2500, t => t != before && IsPlaying(t))) return;
        Spotify.Send(Spotify.Play);
        if (WaitForTitle(hwnd, 2500, t => t != before && IsPlaying(t))) return;
        throw new JumpException("Spotify didn't start “" + what + "”.");
    }

    // "Riders On The Storm - 2021 Remaster" -> "Riders On The Storm", "Lions (Live)" -> "Lions"
    public static string BaseTitle(string title)
    {
        int cut = title.Length;
        foreach (string marker in new[] { " - ", " (", " [" })
        {
            int i = title.IndexOf(marker, StringComparison.Ordinal);
            if (i > 0 && i < cut) cut = i;
        }
        return title.Substring(0, cut);
    }

    static bool IsPlaying(string windowTitle)
    {
        string artist, title;
        return Strings.SplitTitle(windowTitle, out artist, out title);
    }

    static bool WaitForTitle(IntPtr hwnd, int timeoutMs, Func<string, bool> done)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            if (done(Spotify.Title(hwnd))) return true;
            System.Threading.Thread.Sleep(100);
        }
        return false;
    }
}

// ---------------------------------------------------------------- self-test (SpotifyGlobalHotkeys.exe --selftest)

static class SelfTest
{
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);
    static int failures;

    public static int Run()
    {
        AttachConsole(-1);
        Console.WriteLine();

        string artist, title;
        Check(Strings.SplitTitle("The Doors - Riders On The Storm - 2021 Remaster", out artist, out title)
            && artist == "The Doors" && title == "Riders On The Storm - 2021 Remaster", "window title splits at the first ' - '");
        Check(!Strings.SplitTitle("Spotify Premium", out artist, out title), "paused title isn't a song");
        Check(!Strings.SplitTitle("Spotify", out artist, out title), "idle title isn't a song");
        Check(Strings.Fold("Communiqué") == "communique", "accents fold away");
        Check(SpotifyPage.AlbumId("https://xpui.app.spotify.com/album/2rCS6Xwx32V27pvgFzLzlT") == "2rCS6Xwx32V27pvgFzLzlT", "album id from link");
        Check(SpotifyPage.AlbumId("https://xpui.app.spotify.com/artist/0WwSkZ7LtFUFjGjMZBMt6T") == null, "artist link has no album id");

        long now = 1800000000;
        var songs = new List<Song>
        {
            new Song { Title = "Sultans Of Swing", Artist = "Dire Straits", LastPlayed = now - 600, Count = 1 }.Fold(),
            new Song { Title = "Riders On The Storm - 2021 Remaster", Artist = "The Doors", LastPlayed = now - 60, Count = 2 }.Fold(),
            new Song { Title = "Storm Front", Artist = "Billy Joel", LastPlayed = now - 30, Count = 1 }.Fold(),
            new Song { Title = "Brainstorm", Artist = "Hawkwind", LastPlayed = now - 10, Count = 1 }.Fold(),
            new Song { Title = "Lions", Artist = "Dire Straits", LastPlayed = now - 86400 * 90, Count = 40 }.Fold(),
        };
        Check(Titles(Ranker.Rank(songs, "doors storm", false, now)) == "Riders On The Storm - 2021 Remaster", "terms in any order across title and artist");
        Check(Titles(Ranker.Rank(songs, "sltns", false, now)) == "Sultans Of Swing", "letters in order match");
        Check(Titles(Ranker.Rank(songs, "storm", false, now)) == "Storm Front|Riders On The Storm - 2021 Remaster|Brainstorm",
            "word prefix beats substring, then most recent first");
        Check(Ranker.Rank(songs, "xyzzy", false, now).Count == 0, "non-matches are left out");
        Check(Ranker.Rank(songs, "", false, now)[0].Song.Title == "Brainstorm", "empty query: most recent first");
        Check(Ranker.Rank(songs, "", true, now)[0].Song.Title == "Lions", "most played: frecency ranks the old favourite first");
        Check(Ranker.Frecency(songs[4], now) < 40 && Ranker.Frecency(songs[1], now) > 1.9, "frecency fades with age");
        var mask = new bool[songs[0].Title.Length];
        Ranker.Score(songs[0], new[] { "swing" }, mask, null);
        Check(mask[11] && mask[15] && !mask[0], "match highlights the right letters");

        string path = Path.Combine(Path.GetTempPath(), "sgh-selftest-" + Process.GetCurrentProcess().Id + ".tsv");
        try
        {
            var h = new History(path);
            h.Record("Sultans Of Swing", "Dire Straits", "", "spotify:album:2rCS6Xwx32V27pvgFzLzlT", 100);
            h.Record("Tab\there", "New\nline", "", "", 200);
            h.Record("sultans of swing", "dire straits", "", "", 300);
            h.SaveIfDirty();
            File.AppendAllText(path, "not a valid line\n");
            var loaded = new History(path).Snapshot();
            Check(loaded.Count == 2, "same song (any case) is one entry");
            Check(loaded.Count == 2 && loaded[0].Count == 2 && loaded[0].LastPlayed == 300 && loaded[0].Link == "spotify:album:2rCS6Xwx32V27pvgFzLzlT",
                "replay bumps count and time, keeps the album link");
            Check(loaded.Count == 2 && loaded[1].Title == "Tab here" && loaded[1].Artist == "New line", "tabs and newlines are stripped");
            for (int i = 0; i < 6000; i++) h.Record("Song " + i, "Artist", "", "", 1000 + i);
            Check(h.Count == 6002 && h.Snapshot()[0].Title == "Song 5999", "history keeps growing past the old 5000 limit");

            var p = new History(null);
            p.Record("Lions", "Dire Straits", "", "", 500);
            int added = p.Import(new[]
            {
                new Song { Title = "Lions", Artist = "Dire Straits", Link = "spotify:album:2rCS6Xwx32V27pvgFzLzlT", Playlist = "Rock" },
                new Song { Title = "Jolene - Piano Version", Artist = "Pianaura", Link = "spotify:album:6cM30O4QxjHvhu0GM1ELZe", Playlist = "Liked Songs" },
                new Song { Title = "Jolene - Piano Version", Artist = "Pianaura", Link = "", Playlist = "Piano" },
            });
            var imported = p.Snapshot();
            Check(added == 1 && imported.Count == 2, "import adds only new songs, once");
            Check(imported[0].Title == "Lions" && imported[0].Count == 1 && imported[0].Link == "spotify:album:2rCS6Xwx32V27pvgFzLzlT",
                "import fills in a played song's album link but leaves its plays alone");
            Check(imported[1].Count == 0 && imported[1].LastPlayed == 0 && imported[1].Playlist == "Liked Songs", "imported song is unplayed, from its first playlist");
            Check(Ranker.Rank(imported, "", false, now)[0].Song.Title == "Lions" && Ranker.Rank(imported, "", true, now)[0].Song.Title == "Lions",
                "played songs rank above imported ones");
            p.Record("Jolene - Piano Version", "Pianaura", "", "", 600);
            Check(p.Snapshot()[0].Title == "Jolene - Piano Version" && p.Snapshot()[0].Count == 1 && p.Snapshot()[0].Link != "",
                "playing an imported song makes it a normal one");
            var round = History.Parse(History.Format(imported));
            Check(round[1].Playlist == "Liked Songs" && History.Parse(new[] { "5\t1\tOld\tFormat\t\t" })[0].Playlist == "", "playlist survives saving; old 6-column lines still load");
            Check(PlaylistImport.PagePath("spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ") == "/playlist/37i9dQZF1F5p3rmiWPIYgZ"
                && PlaylistImport.PagePath("spotify:user:liekki:collection") == "/collection/tracks"
                && PlaylistImport.PagePath("spotify:collection:your-episodes") == null
                && PlaylistImport.PagePath("spotify:album:2rCS6Xwx32V27pvgFzLzlT") == null, "only playlists and Liked Songs are imported");
        }
        finally { File.Delete(path); }

        Check(Player.BaseTitle("Riders On The Storm - 2021 Remaster") == "Riders On The Storm"
            && Player.BaseTitle("Lions (Live)") == "Lions" && Player.BaseTitle("Lions") == "Lions", "base title drops version suffixes");

        uint mods; Keys key;
        Check(Config.Parse("Ctrl+Shift+J", out mods, out key) && key == Keys.J && mods == 6, "Jump hotkey parses");

        Console.WriteLine(failures == 0 ? "All self-tests passed." : failures + " self-test(s) FAILED.");
        return failures == 0 ? 0 : 1;
    }

    static string Titles(List<Ranked> r) { return string.Join("|", r.ConvertAll(x => x.Song.Title).ToArray()); }

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "  ok    " : "  FAIL  ") + what);
        if (!ok) failures++;
    }
}
