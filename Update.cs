// Updates - checks GitHub for a newer release and, when you choose to, installs it.
// One unauthenticated request to GitHub's API, once a day at most (CheckForUpdates=false turns it off).
// The new exe is downloaded next to the running one and swapped in (installed and portable copies alike);
// a copy in a folder it can't write to opens the release page instead.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Web.Script.Serialization;

class Release
{
    public Version Version;
    public string Tag = "", Page = "", Exe = "";  // Exe: the Windows download's URL, "" if the release has none
}

static class Updates
{
    public const string Repo = "liekki/global-control-for-spotify";
    public const string ExeName = Program.FileName + ".exe";

    // Stamped by build.cmd from APP_VERSION (CI: the release tag). Local builds are 0.0.0 and never offer updates.
    public static readonly Version Current = Normalize(typeof(Updates).Assembly.GetName().Version);

    public static bool IsDevelopmentBuild { get { return Current == new Version(0, 0, 0); } }

    // Updating writes the new exe next to this one.
    public static bool CanReplace
    {
        get
        {
            try
            {
                string probe = Path.Combine(Program.Folder, Program.FileName + ".write-test");
                File.WriteAllText(probe, "");
                File.Delete(probe);
                return true;
            }
            catch (Exception) { return false; }
        }
    }

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
                if (asset != null && Text(asset, "name") == ExeName) result.Exe = Text(asset, "browser_download_url");
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

    // Downloads the new exe next to this one and swaps it in: a running exe can be renamed, so this one becomes .old
    // (deleted by the new copy once this one has quit). Starts the new copy; the caller quits right after.
    public static void Install(Release release)
    {
        if (release.Exe == "") throw new InvalidOperationException("This release has no Windows download.");
        string exe = System.Reflection.Assembly.GetEntryAssembly().Location, fresh = exe + ".new", old = exe + ".old";
        ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
        using (var client = new WebClient())
        {
            client.Headers[HttpRequestHeader.UserAgent] = Program.FileName;
            client.DownloadFile(release.Exe, fresh);
        }
        // A truncated or wrong download isn't worth starting.
        using (var f = File.OpenRead(fresh))
            if (f.Length < 100000 || f.ReadByte() != 'M' || f.ReadByte() != 'Z') { f.Close(); File.Delete(fresh); throw new InvalidDataException("The download doesn't look like " + Program.Name + "."); }

        if (File.Exists(old)) File.Delete(old);
        File.Move(exe, old);
        try { File.Move(fresh, exe); }
        catch (Exception) { File.Move(old, exe); throw; }
        Process.Start(new ProcessStartInfo(exe, "--updated") { WorkingDirectory = Program.Folder });
    }
}
