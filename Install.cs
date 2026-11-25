// Install - the exe installs, moves over and uninstalls itself, so the release is one signed file.
// Run from anywhere else, it offers to install into %LOCALAPPDATA%\Programs\Global Control for Spotify (per user, no
// admin), or to run where it is as a portable copy. It also takes over an install of the app's old name
// (Spotify Global Hotkeys, installed by an Inno Setup installer) and the files of the names before that.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

enum StartMode { Run, Ask }

static class Install
{
    const string OldName = "Spotify Global Hotkeys", OldFileName = "SpotifyGlobalHotkeys";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + Program.FileName;
    // The old Inno Setup installer's entry in Installed apps (its AppId).
    const string OldUninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{6C1F3E0A-8B2D-4E7A-9F4C-2D5B7A1E9C33}_is1";

    static string Programs { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"); } }
    public static string Folder { get { return Path.Combine(Programs, Program.Name); } }
    static string OldFolder { get { return Path.Combine(Programs, OldName); } }
    static string Exe { get { return Path.Combine(Folder, Program.FileName + ".exe"); } }
    static string StartMenuShortcut(string name) { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), name + ".lnk"); }
    static string DesktopShortcut(string name) { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), name + ".lnk"); }

    // Files saved under older names, in the order they're tried: the newer old name wins over Spoco.
    public static readonly string[,] OldFiles =
    {
        { OldFileName + ".ini", Program.FileName + ".ini" },
        { OldFileName + "-history.tsv", Program.FileName + "-history.tsv" },
        { OldFileName + "-history.tsv.tmp", Program.FileName + "-history.tsv.tmp" },
        { "Spoco.ini", Program.FileName + ".ini" },
        { "SpocoHistory.tsv", Program.FileName + "-history.tsv" },
    };

    // Installed, or a portable copy (it has settings next to it): run. Anything else, e.g. straight from Downloads: ask.
    public static StartMode ModeFor(string exeFolder, string installFolder, Func<string, bool> fileExists)
    {
        if (SameFolder(exeFolder, installFolder)) return StartMode.Run;
        return fileExists(Path.Combine(exeFolder, Program.FileName + ".ini")) ? StartMode.Run : StartMode.Ask;
    }

    static bool SameFolder(string a, string b)
    {
        return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    }

    // Moves settings and history saved under older names in one folder to the current names in another (or the same).
    public static void MoveOldFiles(string from, string to)
    {
        for (int i = 0; i < OldFiles.GetLength(0); i++)
        {
            string source = Path.Combine(from, OldFiles[i, 0]), target = Path.Combine(to, OldFiles[i, 1]);
            try { if (File.Exists(source) && !File.Exists(target)) File.Move(source, target); }
            catch (IOException) { } // keep going with defaults rather than not starting
            catch (UnauthorizedAccessException) { }
        }
    }

    // Left behind by an update (the running exe can be renamed but not deleted). Called once the old copy has quit.
    public static void CleanUpAfterUpdate()
    {
        try { File.Delete(Path.Combine(Program.Folder, Program.FileName + ".exe.old")); }
        catch (Exception) { }
    }

    // What the install window starts with: the settings of whatever install is there already, else the old setup's defaults.
    public static void Defaults(out bool startup, out bool jump, out bool desktop, out bool existing)
    {
        string ini = Path.Combine(Folder, Program.FileName + ".ini"), oldIni = Path.Combine(OldFolder, OldFileName + ".ini");
        existing = File.Exists(Exe) || Directory.Exists(OldFolder);
        string source = File.Exists(ini) ? ini : File.Exists(oldIni) ? oldIni : null;
        string start = source != null ? IniValue(source, Config.StartWithWindows) : null;
        startup = start != "false";
        jump = source != null && IniValue(source, Config.StartSpotify) == "true";
        desktop = File.Exists(DesktopShortcut(Program.Name)) || File.Exists(DesktopShortcut(OldName));
    }

    static string IniValue(string path, string key)
    {
        try
        {
            foreach (string line in File.ReadAllLines(path))
            {
                int eq = line.IndexOf('=');
                if (eq > 0 && line.Substring(0, eq).Trim().Equals(key, StringComparison.OrdinalIgnoreCase))
                    return line.Substring(eq + 1).Trim().ToLowerInvariant();
            }
        }
        catch (IOException) { }
        return null;
    }

    // Every step can run again, so after a failure (e.g. a file in use) Install can simply be pressed again.
    public static void Run(bool startup, bool jump, bool desktop)
    {
        StopOtherCopies();
        Directory.CreateDirectory(Folder);
        File.Copy(Application.ExecutablePath, Exe, true);

        // The old name's install: keep its settings and history, then remove it without its own uninstaller,
        // which would delete them.
        if (Directory.Exists(OldFolder))
        {
            MoveOldFiles(OldFolder, Folder);
            try { Directory.Delete(OldFolder, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        Registry.CurrentUser.DeleteSubKeyTree(OldUninstallKey, false);
        foreach (string name in new[] { OldName, "Spoco" })
        {
            DeleteFile(StartMenuShortcut(name));
            DeleteFile(DesktopShortcut(name));
        }

        string ini = Path.Combine(Folder, Program.FileName + ".ini");
        WriteSettings(ini, startup, jump);
        using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
        {
            key.DeleteValue(OldFileName, false);
            key.DeleteValue("Spoco", false);
            if (startup) key.SetValue(Program.FileName, "\"" + Exe + "\"");
            else key.DeleteValue(Program.FileName, false);
        }

        CreateShortcut(StartMenuShortcut(Program.Name), Exe);
        if (desktop) CreateShortcut(DesktopShortcut(Program.Name), Exe);
        else DeleteFile(DesktopShortcut(Program.Name));

        using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", Program.Name);
            key.SetValue("DisplayVersion", Updates.Current.ToString());
            key.SetValue("Publisher", "Matti Vakkilainen");
            key.SetValue("DisplayIcon", Exe);
            key.SetValue("InstallLocation", Folder);
            key.SetValue("UninstallString", "\"" + Exe + "\" --uninstall");
            key.SetValue("URLInfoAbout", "https://github.com/" + Updates.Repo);
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("EstimatedSize", (int)(new FileInfo(Exe).Length / 1024), RegistryValueKind.DWord);
        }

        Process.Start(new ProcessStartInfo(Exe) { WorkingDirectory = Folder });
    }

    // Sets StartWithWindows and StartSpotify and keeps every other line; the app fills in the rest when it starts.
    static void WriteSettings(string path, bool startup, bool jump)
    {
        var lines = new List<string>();
        if (File.Exists(path))
            foreach (string line in File.ReadAllLines(path))
            {
                string t = line.Trim().ToLowerInvariant();
                if (!t.StartsWith(Config.StartWithWindows.ToLowerInvariant()) && !t.StartsWith(Config.StartSpotify.ToLowerInvariant())) lines.Add(line);
            }
        lines.Add(Config.StartWithWindows + "=" + (startup ? "true" : "false"));
        lines.Add(Config.StartSpotify + "=" + (jump ? "true" : "false"));
        File.WriteAllLines(path, lines.ToArray());
    }

    // Runs from Installed apps (or "<exe> --uninstall"). Removes what Run created, like the old setup's uninstaller did,
    // settings and history included. A portable copy only removes its own settings, history and autostart entry.
    public static int Uninstall()
    {
        if (MessageBox.Show("Remove " + Program.Name + " and its settings and Jump history?", Program.Name,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return 1;
        StopOtherCopies();
        bool installed = SameFolder(Program.Folder, Folder);

        using (var key = Registry.CurrentUser.OpenSubKey(RunKey, true))
        {
            if (key != null && (installed || Startup.Enabled)) key.DeleteValue(Program.FileName, false);
        }
        foreach (string file in new[] { ".ini", "-history.tsv", "-history.tsv.tmp" })
            DeleteFile(Path.Combine(Program.Folder, Program.FileName + file));
        if (!installed) return 0;

        DeleteFile(StartMenuShortcut(Program.Name));
        DeleteFile(DesktopShortcut(Program.Name));
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
        // A running exe can't delete itself: a hidden cmd removes the folder once this process has exited.
        Process.Start(new ProcessStartInfo("cmd.exe", "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" + Folder + "\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            WorkingDirectory = Path.GetTempPath()
        });
        return 0;
    }

    static void StopOtherCopies()
    {
        int self = Process.GetCurrentProcess().Id;
        foreach (string name in new[] { Program.FileName, OldFileName, "Spoco" })
            foreach (var p in Process.GetProcessesByName(name))
            {
                try { if (p.Id != self) { p.Kill(); p.WaitForExit(5000); } }
                catch (Exception) { } // already gone
                finally { p.Dispose(); }
            }
    }

    static void DeleteFile(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    // Windows Script Host's shortcut object, late-bound (csc has no reference to it here).
    static void CreateShortcut(string path, string target)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(shellType);
        try
        {
            object link = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            Type linkType = link.GetType();
            linkType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { target });
            linkType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { Path.GetDirectoryName(target) });
            linkType.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
            System.Runtime.InteropServices.Marshal.FinalReleaseComObject(link);
        }
        finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
    }
}

// Shown when the exe runs from somewhere other than its install folder and has no settings next to it.
class InstallForm : Form
{
    public bool RunHere; // "Just run it from here" was chosen; false when installed or closed

    public InstallForm()
    {
        bool startup, jump, desktop, existing;
        Install.Defaults(out startup, out jump, out desktop, out existing);

        Text = Program.Name;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Icon = Program.AppIcon(new Size(32, 32));
        AutoScaleMode = AutoScaleMode.Font;
        Font = SystemFonts.MessageBoxFont;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);

        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(new Label
        {
            Text = (existing ? "Update " + Program.Name + " on this PC to version " + Updates.Current + "."
                             : "Install " + Program.Name + " " + Updates.Current + " for your user (no admin rights needed).")
                + Environment.NewLine + "Installs to " + Install.Folder,
            AutoSize = true,
            Margin = new Padding(3, 3, 3, 12)
        });
        var startupBox = new CheckBox { Text = "Start " + Program.Name + " when I log in to Windows", AutoSize = true, Checked = startup };
        var jumpBox = new CheckBox
        {
            Text = "Start Spotify with Jump support (opens a debugging port on 127.0.0.1" + Environment.NewLine
                + "that programs on this PC can use to control Spotify)",
            AutoSize = true,
            Checked = jump
        };
        var desktopBox = new CheckBox { Text = "Create a desktop shortcut", AutoSize = true, Checked = desktop };
        layout.Controls.Add(startupBox);
        layout.Controls.Add(jumpBox);
        layout.Controls.Add(desktopBox);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 12, 0, 0) };
        var install = new Button { Text = existing ? "Update" : "Install", AutoSize = true };
        var here = new Button { Text = "Just run it from here", AutoSize = true };
        install.Click += delegate
        {
            UseWaitCursor = true;
            try
            {
                Install.Run(startupBox.Checked, jumpBox.Checked, desktopBox.Checked);
                Close();
            }
            catch (Exception e)
            {
                UseWaitCursor = false;
                MessageBox.Show("Couldn't install: " + e.Message, Program.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        here.Click += delegate { RunHere = true; Close(); };
        buttons.Controls.Add(install);
        buttons.Controls.Add(here);
        layout.Controls.Add(buttons);

        Controls.Add(layout);
        AcceptButton = install;
    }
}
