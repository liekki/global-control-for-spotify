// Spotify Global Hotkeys - global hotkeys for Spotify (play/pause, next, previous) and Jump.
// The hotkeys send WM_APPCOMMAND straight to Spotify's window, so they work even when
// another app (browser, game) owns the system media session. Jump keeps a local history
// of songs played and starts one by driving Spotify's own UI through UI Automation.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class Program
{
    public const string Name = "Spotify Global Hotkeys", FileName = "SpotifyGlobalHotkeys";
    public static readonly string Folder = AppDomain.CurrentDomain.BaseDirectory;

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--selftest") return SelfTest.Run();

        bool created;
        using (var mutex = new System.Threading.Mutex(true, FileName + ".SingleInstance", out created))
        {
            if (!created) return 0;
            SetProcessDPIAware();
            MigrateFromOldName();
            Application.EnableVisualStyles();
            Application.Run(new TrayApp());
        }
        return 0;
    }

    // Carry settings and Jump history saved under the app's old name over to the current names.
    static void MigrateFromOldName()
    {
        var moves = new[,]
        {
            { "Spoco.ini", FileName + ".ini" },
            { "SpocoHistory.tsv", FileName + "-history.tsv" },
        };
        for (int i = 0; i < moves.GetLength(0); i++)
        {
            string from = Path.Combine(Folder, moves[i, 0]), to = Path.Combine(Folder, moves[i, 1]);
            try { if (File.Exists(from) && !File.Exists(to)) File.Move(from, to); }
            catch (IOException) { } // keep going with defaults rather than not starting
        }
    }

    public static Icon AppIcon(Size size)
    {
        using (var s = typeof(Program).Assembly.GetManifestResourceStream("app.ico"))
            return new Icon(s, size);
    }
}

class TrayApp : ApplicationContext
{
    readonly NotifyIcon tray;
    readonly HotkeyWindow window = new HotkeyWindow();
    readonly string iniPath = Path.Combine(Program.Folder, Program.FileName + ".ini");
    readonly History history = new History(Path.Combine(Program.Folder, Program.FileName + "-history.tsv"));
    readonly Control ui = new Control(); // marshals background results back to this thread
    readonly Recorder recorder;
    readonly Timer saveTimer = new Timer { Interval = 30000 };
    readonly Timer updateTimer = new Timer { Interval = 2 * 60 * 1000 }; // first check soon after starting, then daily
    Dictionary<string, string> hotkeys;
    SettingsForm settings;
    JumpForm jump;
    Release update; // a newer release, once a check found one
    bool importing, checking, updating;

    public TrayApp()
    {
        tray = new NotifyIcon
        {
            Icon = Program.AppIcon(SystemInformation.SmallIconSize),
            Text = Program.Name,
            ContextMenuStrip = new ContextMenuStrip(),
            Visible = true
        };
        tray.DoubleClick += delegate { ShowSettings(); };
        IntPtr forceHandle = ui.Handle;

        window.Pressed += OnHotkey;
        recorder = new Recorder(history);
        // A big history takes a moment to write, so keep it off this thread.
        saveTimer.Tick += delegate
        {
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                try { history.SaveIfDirty(); } catch (IOException) { } // retried on the next tick
            });
        };
        saveTimer.Start();

        hotkeys = Config.Load(iniPath);
        var failed = Apply();
        if (failed.Count > 0)
            tray.ShowBalloonTip(5000, Program.Name, "Already in use by another app:\n" + string.Join("\n", failed.ToArray()), ToolTipIcon.Warning);

        // Jump needs Spotify started with its debugging port, so this app can start it (e.g. at login).
        if (hotkeys[Config.StartSpotify] == "true")
            RunInBackground(SpotifyLauncher.EnsureAtStartup);

        updateTimer.Tick += delegate
        {
            updateTimer.Interval = 24 * 60 * 60 * 1000;
            if (hotkeys[Config.CheckForUpdates] == "true") CheckForUpdates(false);
        };
        updateTimer.Start();
    }

    // The daily check is quiet: a new version only shows up in the tray menu, never as a popup over a game.
    // Checking from the menu reports what it found.
    void CheckForUpdates(bool manual)
    {
        if (checking) return;
        checking = true;
        var thread = new System.Threading.Thread(delegate()
        {
            Release latest = null;
            Exception error = null;
            try { latest = Updates.Latest(); }
            catch (Exception e) { error = e; }
            ui.BeginInvoke((Action)delegate
            {
                checking = false;
                if (Updates.IsNewer(latest)) { update = latest; if (settings == null) Apply(); }
                if (!manual) return;
                if (error != null || latest == null)
                    MessageBox.Show("Couldn't check for updates" + (error != null ? ": " + error.Message : "."), Program.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                else if (Updates.IsNewer(latest))
                {
                    if (MessageBox.Show("Version " + latest.Version + " is available (you have " + Updates.Current + "). Update now?", Program.Name,
                            MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                        InstallUpdate();
                }
                else if (Updates.IsDevelopmentBuild)
                    MessageBox.Show("This is a development build, so it doesn't update itself. The latest release is " + latest.Version + ".", Program.Name);
                else
                    MessageBox.Show("You have the latest version (" + Updates.Current + ").", Program.Name);
            });
        });
        thread.IsBackground = true;
        thread.Start();
    }

    void InstallUpdate()
    {
        if (update == null || updating) return;
        // Not installed by the setup (e.g. run from Downloads): the setup would install a second copy, so let the user decide.
        if (!Updates.Installed || update.Installer == "")
        {
            Process.Start(update.Page != "" ? update.Page : "https://github.com/" + Updates.Repo + "/releases/latest");
            return;
        }
        updating = true;
        Apply();
        tray.ShowBalloonTip(3000, Program.Name, "Updating to version " + update.Version + "...", ToolTipIcon.Info);
        Release release = update;
        RunInBackground(delegate
        {
            try { Updates.Install(release); }
            catch (Exception) { ui.BeginInvoke((Action)delegate { updating = false; Apply(); }); throw; }
            // The setup waits for this app to close, then starts the new version.
            ui.BeginInvoke((Action)delegate { ExitThread(); });
        });
    }

    void OnHotkey(int command)
    {
        if (command == Config.JumpCommand) ToggleJump();
        else if (command == Config.VolumeUpCommand) SpotifyVolume.Change(+SpotifyVolume.Step);
        else if (command == Config.VolumeDownCommand) SpotifyVolume.Change(-SpotifyVolume.Step);
        else Spotify.Send(command);
    }

    void ToggleJump()
    {
        if (jump == null) jump = new JumpForm(history, PlayInBackground, SearchInBackground, StartSpotifyInBackground);
        if (jump.Visible) jump.Dismiss(true);
        else jump.Open();
    }

    void PlayInBackground(Song song) { RunInBackground(delegate { Player.Play(song); }); }
    void SearchInBackground(string text) { RunInBackground(delegate { Player.Search(text); }); }

    void ImportPlaylists()
    {
        if (importing) return;
        importing = true;
        if (settings == null) Apply();
        tray.ShowBalloonTip(3000, Program.Name, "Importing your playlists in the background. Spotify stays where it is.", ToolTipIcon.Info);
        Action<string> progress = text => ui.BeginInvoke((Action)delegate { tray.Text = text.Length > 63 ? text.Substring(0, 60) + "..." : text; });
        RunInBackground(delegate
        {
            try
            {
                string summary = PlaylistImport.Run(history, progress);
                ui.BeginInvoke((Action)delegate { tray.ShowBalloonTip(5000, Program.Name, summary, ToolTipIcon.Info); });
            }
            finally
            {
                ui.BeginInvoke((Action)delegate { importing = false; tray.Text = Program.Name; if (settings == null) Apply(); });
            }
        });
    }

    void StartSpotifyInBackground()
    {
        RunInBackground(delegate
        {
            SpotifyLauncher.Start();
            ui.BeginInvoke((Action)delegate { tray.ShowBalloonTip(3000, Program.Name, "Spotify is ready for Jump.", ToolTipIcon.Info); });
        });
    }

    // Playback waits on Spotify's UI for a few seconds, so it never runs on this thread.
    void RunInBackground(Action work)
    {
        var thread = new System.Threading.Thread(delegate()
        {
            try { work(); }
            catch (Exception e)
            {
                string message = e is JumpException ? e.Message : "Something went wrong: " + e.Message;
                ui.BeginInvoke((Action)delegate { tray.ShowBalloonTip(5000, Program.Name, message, ToolTipIcon.Warning); });
            }
        });
        thread.IsBackground = true;
        thread.Start();
    }

    // Registers the current hotkeys and rebuilds the tray menu. Returns the ones that couldn't be registered.
    List<string> Apply()
    {
        Startup.Enabled = hotkeys[Config.StartWithWindows] == "true";
        window.UnregisterAll();
        var failed = new List<string>();
        var menu = tray.ContextMenuStrip;
        menu.Items.Clear();

        if (update != null)
        {
            var updateItem = new ToolStripMenuItem(updating ? "Updating to version " + update.Version + "..." : "Update to version " + update.Version,
                null, delegate { InstallUpdate(); });
            updateItem.Enabled = !updating;
            menu.Items.Add(updateItem);
            menu.Items.Add(new ToolStripSeparator());
        }

        for (int i = 0; i < Config.Names.Length; i++)
        {
            string name = Config.Names[i], text = hotkeys[name];
            int command = Config.Commands[i];
            uint mods; Keys key;
            if (Config.Parse(text, out mods, out key) && !window.Register(i + 1, mods, key, command, Config.Repeats(command)))
                failed.Add(Config.Label(name) + " (" + text + ")");

            var item = new ToolStripMenuItem(command == Config.JumpCommand ? "Jump..." : Config.Label(name), null, delegate { OnHotkey(command); });
            item.ShortcutKeyDisplayString = text == "" ? "(none)" : text;
            menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripSeparator());
        var import = new ToolStripMenuItem(importing ? "Importing playlists..." : "Import playlists into Jump", null, delegate { ImportPlaylists(); });
        import.Enabled = !importing;
        menu.Items.Add(import);
        var settingsItem = new ToolStripMenuItem("Settings...", null, delegate { ShowSettings(); });
        settingsItem.Font = new Font(settingsItem.Font, FontStyle.Bold);
        menu.Items.Add(settingsItem);
        var startup = new ToolStripMenuItem("Start with Windows") { Checked = Startup.Enabled };
        startup.Click += delegate
        {
            hotkeys[Config.StartWithWindows] = startup.Checked ? "false" : "true";
            Config.Save(iniPath, hotkeys);
            Apply();
        };
        menu.Items.Add(startup);
        menu.Items.Add(new ToolStripMenuItem("Check for updates" + (Updates.IsDevelopmentBuild ? "" : " (version " + Updates.Current + ")"), null,
            delegate { CheckForUpdates(true); }));
        menu.Items.Add("Exit", null, delegate { ExitThread(); });
        return failed;
    }

    void ShowSettings()
    {
        if (settings != null) { settings.Activate(); return; }

        // Release the hotkeys while recording, otherwise pressing an existing one would trigger it instead.
        window.UnregisterAll();
        settings = new SettingsForm(hotkeys, history);
        settings.FormClosed += delegate
        {
            if (settings.DialogResult == DialogResult.OK)
            {
                hotkeys = settings.Result;
                Config.Save(iniPath, hotkeys);
            }
            settings = null;
            var failed = Apply();
            if (failed.Count > 0)
                MessageBox.Show("These hotkeys are already in use by another app:\n\n" + string.Join("\n", failed.ToArray()),
                    Program.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        };
        settings.Show();
        settings.Activate();
    }

    protected override void ExitThreadCore()
    {
        if (settings != null) settings.Close();
        recorder.Stop();
        saveTimer.Stop();
        updateTimer.Stop();
        history.SaveIfDirty();
        tray.Visible = false;
        tray.Dispose();
        window.DestroyHandle();
        base.ExitThreadCore();
    }
}

class SettingsForm : Form
{
    readonly Dictionary<string, HotkeyBox> boxes = new Dictionary<string, HotkeyBox>();
    readonly CheckBox startWithWindows, startSpotify, checkForUpdates;
    public Dictionary<string, string> Result;

    public SettingsForm(Dictionary<string, string> current, History history)
    {
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

        var layout = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(new Label
        {
            Text = "Click a box and press the key combination you want.",
            AutoSize = true,
            Margin = new Padding(3, 3, 3, 12)
        }, 0, 0);
        layout.SetColumnSpan(layout.GetControlFromPosition(0, 0), 3);

        for (int i = 0; i < Config.Names.Length; i++)
        {
            string name = Config.Names[i];
            var box = new HotkeyBox { Hotkey = current[name], Width = 180 };
            var clear = new Button { Text = "Clear", AutoSize = true };
            clear.Click += delegate { box.Hotkey = ""; box.Focus(); };
            boxes[name] = box;

            layout.Controls.Add(new Label { Text = Config.Label(name), AutoSize = true, Anchor = AnchorStyles.Left }, 0, i + 1);
            layout.Controls.Add(box, 1, i + 1);
            layout.Controls.Add(clear, 2, i + 1);
        }

        startWithWindows = new CheckBox
        {
            Text = "Start with Windows",
            AutoSize = true,
            Checked = current[Config.StartWithWindows] == "true",
            Margin = new Padding(3, 12, 3, 3)
        };
        layout.Controls.Add(startWithWindows, 0, Config.Names.Length + 1);
        layout.SetColumnSpan(startWithWindows, 3);

        startSpotify = new CheckBox
        {
            Text = "Start Spotify with Jump support when this app starts" + Environment.NewLine + "(restarts a Spotify that just opened without it)",
            AutoSize = true,
            Checked = current[Config.StartSpotify] == "true",
            Margin = new Padding(3, 3, 3, 3)
        };
        layout.Controls.Add(startSpotify, 0, Config.Names.Length + 2);
        layout.SetColumnSpan(startSpotify, 3);

        checkForUpdates = new CheckBox
        {
            Text = "Check for updates once a day (installs only when you choose)",
            AutoSize = true,
            Checked = current[Config.CheckForUpdates] == "true",
            Margin = new Padding(3, 3, 3, 3)
        };
        layout.Controls.Add(checkForUpdates, 0, Config.Names.Length + 3);
        layout.SetColumnSpan(checkForUpdates, 3);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 12, 0, 0) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        var ok = new Button { Text = "Save", AutoSize = true };
        var defaults = new Button { Text = "Defaults", AutoSize = true };
        ok.Click += delegate { Save(); };
        defaults.Click += delegate
        {
            for (int i = 0; i < Config.Names.Length; i++) boxes[Config.Names[i]].Hotkey = Config.Defaults[i];
        };
        var clearHistory = new Button { Text = "Clear history...", AutoSize = true };
        clearHistory.Click += delegate
        {
            if (MessageBox.Show("Forget all " + history.Count + " songs Jump remembers?", Program.Name,
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK)
                history.Clear();
        };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(ok);
        buttons.Controls.Add(defaults);
        buttons.Controls.Add(clearHistory);
        layout.Controls.Add(buttons, 0, Config.Names.Length + 4);
        layout.SetColumnSpan(buttons, 3);

        Controls.Add(layout);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    void Save()
    {
        var seen = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in Config.Names)
        {
            string text = boxes[name].Hotkey, other;
            if (text == "") continue;
            if (seen.TryGetValue(text, out other))
            {
                MessageBox.Show(Config.Label(other) + " and " + Config.Label(name) + " both use " + text + ".", Program.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            seen[text] = name;
        }

        Result = new Dictionary<string, string>();
        foreach (var name in Config.Names) Result[name] = boxes[name].Hotkey;
        Result[Config.StartWithWindows] = startWithWindows.Checked ? "true" : "false";
        Result[Config.StartSpotify] = startSpotify.Checked ? "true" : "false";
        Result[Config.CheckForUpdates] = checkForUpdates.Checked ? "true" : "false";
        DialogResult = DialogResult.OK;
        Close();
    }
}

// A read-only text box that shows whatever key combination is pressed in it.
class HotkeyBox : TextBox
{
    string hotkey = "";

    public HotkeyBox()
    {
        ReadOnly = true;
        BackColor = SystemColors.Window;
        ShortcutsEnabled = false;
    }

    public string Hotkey
    {
        get { return hotkey; }
        set { hotkey = value ?? ""; Text = hotkey == "" ? "(none)" : hotkey; }
    }

    // Let arrows, Enter, Escape etc. reach OnKeyDown instead of moving focus or closing the dialog.
    protected override bool IsInputKey(Keys keyData) { return (keyData & Keys.KeyCode) != Keys.Tab; }
    // TextBoxBase swallows Ctrl(+Shift)+C/V/X/Z/A etc. here when ShortcutsEnabled is off, so skip it.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) { return false; }
    protected override bool ProcessDialogKey(Keys keyData)
    {
        if ((keyData & Keys.KeyCode) == Keys.Tab) return base.ProcessDialogKey(keyData);
        return false;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        e.SuppressKeyPress = true;
        e.Handled = true;
        Keys key = e.KeyCode;
        if (key == Keys.ControlKey || key == Keys.ShiftKey || key == Keys.Menu || key == Keys.LWin || key == Keys.RWin)
        {
            Text = Config.Format(e.Modifiers, Keys.None, IsWinDown());
            return;
        }
        // A bare letter or Enter would be swallowed system-wide, so only allow keys nobody types with.
        bool bare = e.Modifiers == Keys.None && !IsWinDown();
        if (bare && !(key >= Keys.F1 && key <= Keys.F24) && !(key >= Keys.BrowserBack && key <= Keys.LaunchApplication2)
            && key != Keys.Pause && key != Keys.Scroll)
        {
            Text = "Add Ctrl, Alt, Shift or Win";
            return;
        }
        Hotkey = Config.Format(e.Modifiers, key, IsWinDown());
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        Hotkey = hotkey; // drop a half-typed "Ctrl+Alt+" if no key followed
    }

    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    static bool IsWinDown() { return GetKeyState(0x5B) < 0 || GetKeyState(0x5C) < 0; }
}

// Per-user autostart via the Run key, so no admin rights are needed.
static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static string Command { get { return "\"" + Application.ExecutablePath + "\""; } }

    public static bool Enabled
    {
        get
        {
            using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey))
                return key != null && Command.Equals(key.GetValue(Program.FileName) as string, StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey))
            {
                key.DeleteValue("Spoco", false); // the old name
                if (value) key.SetValue(Program.FileName, Command);
                else key.DeleteValue(Program.FileName, false);
            }
        }
    }
}

class HotkeyWindow : NativeWindow
{
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    readonly Dictionary<int, int> commands = new Dictionary<int, int>();
    public event Action<int> Pressed;

    public HotkeyWindow() { CreateHandle(new CreateParams()); }

    // repeat: keep firing while the keys are held (volume); otherwise once per press.
    public bool Register(int id, uint modifiers, Keys key, int command, bool repeat)
    {
        if (!RegisterHotKey(Handle, id, modifiers | (repeat ? 0 : MOD_NOREPEAT), (uint)key)) return false;
        commands[id] = command;
        return true;
    }

    public void UnregisterAll()
    {
        foreach (int id in commands.Keys) UnregisterHotKey(Handle, id);
        commands.Clear();
    }

    protected override void WndProc(ref Message m)
    {
        int command;
        if (m.Msg == WM_HOTKEY && commands.TryGetValue(m.WParam.ToInt32(), out command) && Pressed != null)
            Pressed(command);
        base.WndProc(ref m);
    }
}

// Spotify's own volume, as set in the Windows volume mixer (Core Audio's per-app session volume).
// Doesn't touch the system volume or Spotify's window, and works without Jump's debugging port.
static class SpotifyVolume
{
    public const float Step = 0.05f;

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        int GetAudioSessionControl(IntPtr groupingParam, int flags, out IntPtr control);
        int GetSimpleAudioVolume(IntPtr groupingParam, int flags, out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        // IAudioSessionControl, unused here but needed for the vtable order
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName(IntPtr name, IntPtr context);
        int GetIconPath(out IntPtr path);
        int SetIconPath(IntPtr path, IntPtr context);
        int GetGroupingParam(out Guid param);
        int SetGroupingParam(IntPtr param, IntPtr context);
        int RegisterAudioSessionNotification(IntPtr client);
        int UnregisterAudioSessionNotification(IntPtr client);
        // IAudioSessionControl2
        int GetSessionIdentifier(out IntPtr id);
        int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid context);
        [PreserveSig] int GetMasterVolume(out float level);
    }

    // Changes every Spotify audio session on the default output by delta (0..1 scale). Returns the new
    // level, or -1 if Spotify has no audio session (not running, or hasn't played anything yet).
    public static float Change(float delta)
    {
        var pids = new HashSet<uint>();
        foreach (var p in Process.GetProcessesByName("Spotify")) { pids.Add((uint)p.Id); p.Dispose(); }
        if (pids.Count == 0) return -1;

        float result = -1;
        try
        {
            var devices = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDevice speakers;
            if (devices.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out speakers) != 0) return -1;
            Guid managerId = typeof(IAudioSessionManager2).GUID;
            object manager;
            if (speakers.Activate(ref managerId, 23 /* CLSCTX_ALL */, IntPtr.Zero, out manager) != 0) return -1;
            IAudioSessionEnumerator sessions;
            if (((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions) != 0) return -1;
            int count;
            sessions.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IAudioSessionControl2 session;
                uint pid;
                if (sessions.GetSession(i, out session) != 0 || session.GetProcessId(out pid) != 0 || !pids.Contains(pid)) continue;
                var volume = (ISimpleAudioVolume)session;
                float level;
                volume.GetMasterVolume(out level);
                level = Math.Max(0f, Math.Min(1f, (float)Math.Round((level + delta) / Step) * Step));
                Guid context = Guid.Empty;
                volume.SetMasterVolume(level, ref context);
                result = level;
            }
        }
        catch (COMException) { } // no audio device
        catch (InvalidCastException) { }
        return result;
    }
}

static class Spotify
{
    public const int PlayPause = 14, NextTrack = 11, PreviousTrack = 12, Play = 46;
    const int WM_APPCOMMAND = 0x0319;

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    static IntPtr cached;

    public static void Send(int command)
    {
        IntPtr hwnd = MainWindow();
        if (hwnd != IntPtr.Zero)
            SendMessage(hwnd, WM_APPCOMMAND, hwnd, new IntPtr(command << 16));
    }

    // Called every second by the recorder, so keep the window handle until it goes away.
    public static IntPtr MainWindow()
    {
        IntPtr h = cached;
        if (h != IntPtr.Zero && IsWindow(h) && GetWindowTextLength(h) > 0) return h;
        cached = FindWindow();
        return cached;
    }

    public static string Title(IntPtr hwnd)
    {
        var sb = new StringBuilder(GetWindowTextLength(hwnd) + 1);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    // Spotify's main window keeps a title even when it is closed to the tray,
    // which Process.MainWindowHandle doesn't handle, so enumerate instead.
    static IntPtr FindWindow()
    {
        var pids = new HashSet<uint>();
        foreach (var p in Process.GetProcessesByName("Spotify")) { pids.Add((uint)p.Id); p.Dispose(); }
        if (pids.Count == 0) return IntPtr.Zero;

        IntPtr found = IntPtr.Zero;
        var cls = new StringBuilder(64);
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid) || GetWindowTextLength(h) == 0) return true;
            cls.Length = 0;
            GetClassName(h, cls, cls.Capacity);
            if (cls.ToString() != "Chrome_WidgetWin_1") return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}

static class Config
{
    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8;

    // Handled by this app itself, never sent to Spotify as such.
    public const int JumpCommand = -1, VolumeUpCommand = -2, VolumeDownCommand = -3;
    public static readonly string[] Names = { "PlayPause", "Next", "Previous", "Jump", "VolumeUp", "VolumeDown" };
    public static readonly string[] Defaults = { "Ctrl+Shift+C", "Ctrl+Shift+B", "Ctrl+Shift+Z", "Ctrl+Shift+J", // Winamp's classic hotkeys
        "Ctrl+Shift+PageUp", "Ctrl+Shift+PageDown" };
    public static readonly int[] Commands = { Spotify.PlayPause, Spotify.NextTrack, Spotify.PreviousTrack, JumpCommand, VolumeUpCommand, VolumeDownCommand };

    public static bool Repeats(int command) { return command == VolumeUpCommand || command == VolumeDownCommand; }
    public const string StartWithWindows = "StartWithWindows";
    public const string StartSpotify = "StartSpotify";
    public const string CheckForUpdates = "CheckForUpdates";

    public static Dictionary<string, string> Load(string path)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (File.Exists(path))
        {
            foreach (var raw in File.ReadAllLines(path))
            {
                string line = raw.Trim();
                int eq = line.IndexOf('=');
                if (line.StartsWith(";") || eq < 0) continue;
                values[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
        }

        // Older versions had separate Play and Pause keys; the toggle takes over the Play key.
        bool migrated = !values.ContainsKey("PlayPause") && (values.ContainsKey("Play") || values.ContainsKey("Pause"));
        if (migrated)
        {
            string old;
            if (!values.TryGetValue("Play", out old) || old == "") values.TryGetValue("Pause", out old);
            values["PlayPause"] = old ?? "";
        }

        var result = new Dictionary<string, string>();
        for (int i = 0; i < Names.Length; i++)
        {
            string text;
            uint mods; Keys key;
            if (!values.TryGetValue(Names[i], out text)) text = Defaults[i];
            else if (text != "" && !Parse(text, out mods, out key))
            {
                MessageBox.Show("Can't understand hotkey for " + Label(Names[i]) + ": " + text, Program.Name);
                text = "";
            }
            result[Names[i]] = text;
        }

        // Missing means an older ini: keep whatever autostart state is already in place.
        string start;
        if (values.TryGetValue(StartWithWindows, out start)) start = start.Trim().ToLowerInvariant();
        result[StartWithWindows] = start == "true" || start == "false" ? start : (Startup.Enabled ? "true" : "false");

        string spotify;
        values.TryGetValue(StartSpotify, out spotify);
        result[StartSpotify] = (spotify ?? "").Trim().ToLowerInvariant() == "true" ? "true" : "false";

        string updates;
        bool hasUpdates = values.TryGetValue(CheckForUpdates, out updates);
        result[CheckForUpdates] = (updates ?? "").Trim().ToLowerInvariant() == "false" ? "false" : "true";

        // Written back when something is missing, so every setting shows up in the file.
        if (!File.Exists(path) || start == null || migrated || !hasUpdates) Save(path, result);
        return result;
    }

    public static string Label(string name)
    {
        switch (name)
        {
            case "PlayPause": return "Play/Pause";
            case "VolumeUp": return "Volume up";
            case "VolumeDown": return "Volume down";
            default: return name;
        }
    }

    public static void Save(string path, Dictionary<string, string> hotkeys)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; " + Program.Name + " hotkeys. Easiest to change from the tray icon: right-click > Settings.");
        sb.AppendLine("; Modifiers: Ctrl, Alt, Shift, Win. Leave empty to disable.");
        foreach (var name in Names) sb.AppendLine(name + "=" + hotkeys[name]);
        sb.AppendLine();
        sb.AppendLine("; true or false: launch " + Program.Name + " when you log in to Windows.");
        sb.AppendLine(StartWithWindows + "=" + hotkeys[StartWithWindows]);
        sb.AppendLine();
        sb.AppendLine("; true or false: " + Program.Name + " starts Spotify with the debugging port Jump needs (127.0.0.1 only).");
        sb.AppendLine(StartSpotify + "=" + hotkeys[StartSpotify]);
        sb.AppendLine();
        sb.AppendLine("; true or false: once a day, ask GitHub whether there's a new version (it's only installed when you choose).");
        sb.AppendLine(CheckForUpdates + "=" + hotkeys[CheckForUpdates]);
        File.WriteAllText(path, sb.ToString());
    }

    public static string Format(Keys modifiers, Keys key, bool win)
    {
        var parts = new List<string>();
        if ((modifiers & Keys.Control) != 0) parts.Add("Ctrl");
        if ((modifiers & Keys.Alt) != 0) parts.Add("Alt");
        if ((modifiers & Keys.Shift) != 0) parts.Add("Shift");
        if (win) parts.Add("Win");
        // Keys.PageUp/PageDown share their values with Prior/Next, which ToString() may pick.
        parts.Add(key == Keys.None ? "" : key == Keys.PageUp ? "PageUp" : key == Keys.PageDown ? "PageDown" : key.ToString());
        return string.Join("+", parts.ToArray());
    }

    public static bool Parse(string text, out uint modifiers, out Keys key)
    {
        modifiers = 0;
        key = Keys.None;
        string[] parts = text.Split('+');
        for (int i = 0; i < parts.Length; i++)
        {
            string p = parts[i].Trim();
            switch (p.ToLowerInvariant())
            {
                case "ctrl": case "control": modifiers |= MOD_CONTROL; break;
                case "alt": modifiers |= MOD_ALT; break;
                case "shift": modifiers |= MOD_SHIFT; break;
                case "win": modifiers |= MOD_WIN; break;
                default:
                    if (i != parts.Length - 1) return false;
                    try { key = (Keys)Enum.Parse(typeof(Keys), p, true); }
                    catch (ArgumentException) { return false; }
                    return true;
            }
        }
        return false;
    }
}
