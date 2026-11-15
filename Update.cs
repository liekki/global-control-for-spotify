// Updates - checks GitHub for a newer release and, when you choose to, installs it.
// One unauthenticated request to GitHub's API, once a day at most (CheckForUpdates=false turns it off).
// An installed copy downloads the release's installer and runs it silently, which updates in place and
// starts the new version; a copy run from anywhere else opens the release page instead.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Web.Script.Serialization;

class Release
{
    public Version Version;
    public string Tag = "", Page = "", Installer = "";  // Installer: the setup's download URL, "" if the release has none
}

static class Updates
{
    public const string Repo = "liekki/spotify-global-hotkeys";
    public const string InstallerName = "SpotifyGlobalHotkeysSetup.exe";

    // Stamped by build.cmd from APP_VERSION (CI: the release tag). Local builds are 0.0.0 and never offer updates.
    public static readonly Version Current = Normalize(typeof(Updates).Assembly.GetName().Version);

    public static bool IsDevelopmentBuild { get { return Current == new Version(0, 0, 0); } }

    // The installer leaves its uninstaller next to the exe; a copy run from a download folder has none.
    public static bool Installed { get { return File.Exists(Path.Combine(Program.Folder, "unins000.exe")); } }

    public static Release Latest()
    {
        // .NET Framework 4's defaults don't include TLS 1.2, which GitHub requires.
        ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
        // SGH_UPDATE_URL points the check elsewhere (a local file, for testing an update without publishing one).
        string url = Environment.GetEnvironmentVariable("SGH_UPDATE_URL");
        if (string.IsNullOrEmpty(url)) url = "https://api.github.com/repos/" + Repo + "/releases/latest";
        var request = WebRequest.Create(url);
        request.Timeout = 15000;
        var http = request as HttpWebRequest;
        if (http != null)
        {
            http.UserAgent = Program.FileName; // GitHub requires one
            http.Accept = "application/vnd.github+json";
        }
        using (var response = request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
            return Parse(reader.ReadToEnd());
    }

    public static Release Parse(string json)
    {
        var release = new JavaScriptSerializer().DeserializeObject(json) as Dictionary<string, object>;
        if (release == null) return null;
        object draft, pre;
        if ((release.TryGetValue("draft", out draft) && true.Equals(draft)) || (release.TryGetValue("prerelease", out pre) && true.Equals(pre))) return null;
        var result = new Release { Tag = Text(release, "tag_name"), Page = Text(release, "html_url") };
        result.Version = ParseVersion(result.Tag);
        if (result.Version == null) return null;
        object assets;
        if (release.TryGetValue("assets", out assets) && assets is object[])
            foreach (var a in (object[])assets)
            {
                var asset = a as Dictionary<string, object>;
                if (asset != null && Text(asset, "name") == InstallerName) result.Installer = Text(asset, "browser_download_url");
            }
        return result;
    }

    static string Text(Dictionary<string, object> d, string key)
    {
        object v;
        return d.TryGetValue(key, out v) && v is string ? (string)v : "";
    }

    // "v1.4.0" -> 1.4.0; anything else (including "v1.4.0-beta") -> null.
    public static Version ParseVersion(string tag)
    {
        if (tag == null) return null;
        string s = tag.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? tag.Substring(1) : tag;
        foreach (char c in s) if (!char.IsDigit(c) && c != '.') return null;
        Version v;
        return Version.TryParse(s, out v) ? Normalize(v) : null;
    }

    // 1.4 and 1.4.0.0 are both 1.4.0, so they compare equal.
    static Version Normalize(Version v) { return new Version(v.Major, v.Minor, Math.Max(0, v.Build)); }

    public static bool IsNewer(Release release) { return release != null && !IsDevelopmentBuild && release.Version > Current; }

    // Downloads the installer to the temp folder and starts it. The caller quits right after, so the setup
    // can replace the exe; the setup starts the new version when it's done.
    public static void Install(Release release)
    {
        if (release.Installer == "") throw new InvalidOperationException("This release has no installer.");
        string path = Path.Combine(Path.GetTempPath(), "SpotifyGlobalHotkeysSetup-" + release.Version + ".exe");
        ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
        using (var client = new WebClient())
        {
            client.Headers[HttpRequestHeader.UserAgent] = Program.FileName;
            client.DownloadFile(release.Installer, path);
        }
        // A truncated or wrong download isn't worth starting.
        using (var f = File.OpenRead(path))
            if (f.Length < 100000 || f.ReadByte() != 'M' || f.ReadByte() != 'Z') throw new InvalidDataException("The download doesn't look like the installer.");
        // /UPDATE: keep the current settings instead of the setup's own choices, and start the app afterwards.
        Process.Start(new ProcessStartInfo(path, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATE") { UseShellExecute = false });
    }
}
