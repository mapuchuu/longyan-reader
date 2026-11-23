using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace Longyan;

/// Longyan Reader for Windows: an icon in the notification area and a shortcut, Ctrl+Alt+L,
/// that opens a card for the Chinese text selected in any app. The cards come from the same
/// core as the Mac app's (Sources/LongyanCore, through Sources/LongyanBridge).
static class Program
{
    static Forms.NotifyIcon? tray;
    static Forms.ToolStripMenuItem? modelItem;
    static string modelStatus = "";
    static bool lastRunEndedBadly, reportOffered, exiting, modelVerified;
    static string? toldAbout;
    static bool welcomedNow;
    static Action? balloonClicked;
    const string AgainEvent = "LongyanReader.Windows.Again";
    const string QuitEvent = "LongyanReader.Windows.Quit";

    [STAThread]
    static int Main(string[] args)
    {
        // --render DIR OUT: draws every DIR/*.json card into OUT, light and dark (gallery.yml).
        if (args.Length == 3 && args[0] == "--render") return RenderGallery(args[1], args[2]);
        // --render-windows OUT: the welcome and settings windows, light and dark (UiCheck).
        if (args.Length == 2 && args[0] == "--render-windows") return RenderWindows(args[1]);
        // --check-shortcut: the default shortcut on each installed keyboard layout (UiCheck).
        if (args.Length == 1 && args[0] == "--check-shortcut") return Shortcut.Check();
        // History: --render-history OUT (UiCheck), --history (the running copy's window).
        if (History.Command(args) is int history) return history;
        // Dev only: --show CARD.json X Y [--script PLAN|@FILE] [--appearance light|dark]
        // [--trace FILE], a live card from a saved card JSON, for filming beside the Mac's
        // (CardWindow.Show, CardWindow.Script.cs). Runs beside the usual copy; quit from its icon's menu.
        if (args.Length >= 4 && args[0] == "--show") return ShowCard(args);

        using var single = new Mutex(true, "LongyanReader.Windows", out var first);
        if (!first)
        {
            // The running copy opens Settings.
            if (EventWaitHandle.TryOpenExisting(AgainEvent, out var again)) { again.Set(); again.Dispose(); }
            return 0;
        }
        lastRunEndedBadly = Diagnostics.Start();
        if (MissingFile() is string missing)
        {
            Diagnostics.Write("missing " + missing + " in " + Core.AppDirectory);
            MessageBox.Show($"Longyan Reader can't find some of its files ({missing}).\n\n" +
                "If you opened it from inside the zip, extract the whole zip first: right-click it, choose Extract all, " +
                "then open LongyanReader.exe in the folder it makes. If you did, download Longyan Reader again.",
                "Longyan Reader", MessageBoxButton.OK, MessageBoxImage.Error);
            Diagnostics.ExitedCleanly();
            return 1;
        }
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        Diagnostics.Watch(app);
        Diagnostics.Failed = () =>
        {
            if (reportOffered) return;
            reportOffered = true;
            Balloon("Something went wrong in Longyan Reader. Click here to report the problem.", Report);
        };
        using var openedAgain = new EventWaitHandle(false, EventResetMode.AutoReset, AgainEvent);
        // Opened again (from Start, or the exe): Settings, as Windows tray apps do.
        ThreadPool.RegisterWaitForSingleObject(openedAgain, (_, _) => app.Dispatcher.BeginInvoke(() => SettingsWindow.Open()),
            null, Timeout.Infinite, false);
        // The installer and uninstaller (windows/installer) ask it to exit before they replace or remove it.
        using var quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent);
        ThreadPool.RegisterWaitForSingleObject(quit, (_, _) => app.Dispatcher.BeginInvoke(() => Exit("the installer asked", TimeSpan.FromSeconds(4))),
            null, Timeout.Infinite, true);
        app.SessionEnding += (_, _) => Exit("Windows is shutting down", TimeSpan.FromSeconds(2));
        app.Startup += (_, _) => Start();
        app.Run();
        return 0;
    }

    /// A file the app can't run without, when it's missing: as when the exe was run from inside
    /// the zip, or the zip was only partly extracted.
    static string? MissingFile()
    {
        foreach (var f in new[] { "LongyanBridge.dll", "dispatch.dll", "swiftCore.dll", @"Resources\cedict_ts.u8", @"Resources\splitter.tsv" })
            if (!System.IO.File.Exists(System.IO.Path.Combine(Core.AppDirectory, f))) return f;
        return null;
    }

    static int RenderGallery(string dir, string output)
    {
        System.IO.Directory.CreateDirectory(output);
        foreach (var file in System.IO.Directory.GetFiles(dir, "*.json"))
        {
            var card = System.Text.Json.Nodes.JsonNode.Parse(System.IO.File.ReadAllText(file)) as System.Text.Json.Nodes.JsonObject;
            if (card == null) continue;
            var name = System.IO.Path.GetFileNameWithoutExtension(file);
            foreach (var dark in new[] { false, true })
            {
                Theme.Dark = dark;
                CardWindow.RenderToFile(card, System.IO.Path.Combine(output, name + (dark ? "-dark" : "") + ".png"), pin: name.Contains("pinned"));
            }
            Console.WriteLine(name);
        }
        foreach (var dark in new[] { false, true })
        {
            Theme.Dark = dark;
            ChipWindow.RenderToFile(System.IO.Path.Combine(output, "eye" + (dark ? "-dark" : "") + ".png"));
        }
        Console.WriteLine("eye");
        RenderWindows(output);
        return 0;
    }

    static int ShowCard(string[] args)
    {
        CardWindow.UseConsole();
        string file = args[1], xText = args[2], yText = args[3];
        string? plan = null, appearance = null, tracePath = null;
        var ok = true;
        for (var i = 4; i < args.Length; i += 2)
        {
            var value = i + 1 < args.Length ? args[i + 1] : null;
            if (value == null) ok = false;
            else if (args[i] == "--script") plan = value;
            else if (args[i] == "--appearance" && value is "light" or "dark") appearance = value;
            else if (args[i] == "--trace") tracePath = value;
            else ok = false;
        }
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        if (!ok || !double.TryParse(xText, System.Globalization.NumberStyles.Float, inv, out var x) ||
            !double.TryParse(yText, System.Globalization.NumberStyles.Float, inv, out var y) || !System.IO.File.Exists(file))
        {
            const string usage = "LongyanReader --show CARD.json X Y [--script \"PLAN\" | --script @FILE] [--appearance light|dark] [--trace FILE]\n\nX and Y in DIPs from the primary screen's top-left.";
            Console.Error.WriteLine(usage);
            MessageBox.Show(usage, "Longyan Reader");
            return 2;
        }
        var steps = new System.Collections.Generic.List<CardWindow.Step>();
        if (plan != null)
        {
            if (plan.StartsWith('@'))
            {
                var path = plan[1..];
                if (!System.IO.File.Exists(path)) { Console.Error.WriteLine("error: can't read " + plan); return 2; }
                plan = string.Join(";", System.IO.File.ReadAllLines(path).Where(l => !l.StartsWith('#')));
            }
            var (parsed, error) = CardWindow.ParsePlan(plan);
            if (error != null) { Console.Error.WriteLine("error: " + error); MessageBox.Show(error, "Longyan Reader"); return 2; }
            steps = parsed;
        }
        // The card's light or dark for the run, whatever Windows is set to (nothing is changed there).
        if (appearance != null) { Theme.Forced = appearance == "dark"; Theme.Dark = Theme.Forced.Value; }
        var json = System.IO.File.ReadAllText(file);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += (_, _) =>
        {
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("Quit card show", null, (_, _) => { tray!.Visible = false; Core.Shared.Stop(); app.Shutdown(); });
            tray = new Forms.NotifyIcon { Icon = LoadIcon(), Text = "Longyan Reader --show", Visible = true, ContextMenuStrip = menu };
            Core.Shared.Ready += _ => { CardWindow.Prepare(steps, tracePath); CardWindow.Show(json, x, y); };
            Core.Shared.Failed += message => MessageBox.Show("The dictionary didn't load: " + message, "Longyan Reader");
            Core.Shared.Start(withModel: false);
            Anki.Start();   // as the app does, so the card offers Add to Anki when Anki is open
        };
        app.Run();
        return 0;
    }

    static int RenderWindows(string output)
    {
        System.IO.Directory.CreateDirectory(output);
        WelcomeWindow.RenderToFiles(output);
        SettingsWindow.RenderToFiles(output);
        Console.WriteLine("welcome, settings");
        return 0;
    }

    /// The model's state from the core, for Settings and the welcome window.
    public static string ModelStatus => modelStatus;

    static void Start()
    {
        var core = Core.Shared;
        core.Ready += status =>
        {
            modelStatus = status;
            ModelDownload.TooSlow = status is "too-slow" or "needs-arm64";
            UpdateMenu();
            Application.Current.Dispatcher.BeginInvoke(CardWindow.Warm, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            if (lastRunEndedBadly)
            {
                lastRunEndedBadly = false;
                reportOffered = true;
                Balloon("Longyan Reader closed unexpectedly last time. Click here to report the problem.", Report);
            }
            else if (!Settings.WelcomeShown) WelcomeWindow.Open();
            else if (welcomedNow) { }   // the welcome window says it all
            else if (status != "ready" && !ModelDownload.IsDownloaded) Balloon("Longyan Reader is ready. Download the reading model in Settings to pick meanings and translate. Click here to open Settings.", () => SettingsWindow.Open());
            else if (Shortcut.Registered) Balloon($"Longyan Reader is ready. Select Chinese text in any app and press {Shortcut.Name}.");
        };
        core.ModelChanged += ModelChanged;
        // Outside the core's callback, so the message box's loop doesn't run the core's queue inside its own drain.
        core.Failed += message => Application.Current.Dispatcher.BeginInvoke(() => MessageBox.Show(
            "Longyan Reader couldn't load its dictionary, so it can't show cards (" + message + ").\n\n" +
            "Extract the download again, or use Report a problem in the icon's menu.", "Longyan Reader", MessageBoxButton.OK, MessageBoxImage.Error));
        try { core.Start(); }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            Diagnostics.Write("couldn't start the core: " + Diagnostics.Describe(e));
            MessageBox.Show("Longyan Reader couldn't start: some of its files are missing or damaged (" + e.Message + ").\n\n" +
                "Extract the whole zip again and open LongyanReader.exe from the extracted folder.", "Longyan Reader", MessageBoxButton.OK, MessageBoxImage.Error);
            Diagnostics.ExitedCleanly();
            Application.Current.Shutdown();
            return;
        }
        MakeTray();
        MenuChanged();
        LoginItem.Refresh();
        Updates.Start();
        Shortcut.Start(LookUp, (text, pick) => { Balloon(text, pick ? ShortcutWindow.Open : null); if (pick) ShortcutWindow.Open(); });
        Chip.Clicked = EyeClicked;
        Chip.Start();
        // The first run: the welcome window at once, while the dictionary loads (first-run work,
        // win/firstrun). When it closes, the icon says where the app went.
        WelcomeWindow.Finished += () =>
        {
            if (exiting) return;
            Balloon($"Longyan Reader is running in the notification area. Select Chinese text in any app, then press {Shortcut.Name}."
                + (ModelDownload.Running ? " The reading model keeps downloading." : ""));
        };
        if (!Settings.WelcomeShown && !lastRunEndedBadly) { welcomedNow = true; WelcomeWindow.Open(); }
    }

    /// The eye: the selection read when it appeared, else copy it now (the eye never took the
    /// focus, so the app with the selection still has it).
    static async System.Threading.Tasks.Task EyeClicked(Selected? selected)
    {
        if (!Core.Shared.IsReady) { CardWindow.Hint("Dictionary still loading…"); return; }
        selected ??= await SelectionReader.ReadByCopying();
        if (selected == null) { CardWindow.Hint("No Chinese text in the selection"); return; }
        Present(selected);
    }

    static void Present(Selected selected)
    {
        Chip.Hide();
        History.Opening(selected);   // History: the card about to open is for this selection
        CardWindow.Present(selected);
    }

    /// The shortcut: read the selection, else the word under the pointer (as on the Mac), else
    /// copy the selection, then open its card.
    static async void LookUp()
    {
        if (!Core.Shared.IsReady) { CardWindow.Hint("Dictionary still loading…"); return; }
        var clock = System.Diagnostics.Stopwatch.StartNew();
        Core.Log("{\"event\":\"shortcut\"}");
        Bridge.ly_warm_up();
        var warm = clock.Elapsed.TotalMilliseconds;
        var selected = (await SelectionReader.ProbeAsync()).Selection;
        var read = clock.Elapsed.TotalMilliseconds;
        var how = "automation";
        // Nothing readable with Chinese in it is selected: the word under the pointer.
        if (selected == null || !SelectionReader.HasChinese(selected))
        {
            var pointed = await PointReader.ReadAsync();
            // Where the character is in the passage, a number; never the text.
            Core.Log($"{{\"event\":\"point\",\"found\":\"{PointReader.Found}\",\"at\":{pointed?.Start ?? -1}}}");
            if (pointed != null) { how = "point"; selected = pointed; }
        }
        var point = clock.Elapsed.TotalMilliseconds;
        // Ctrl+C interrupts the program in a terminal (and isn't copy in Emacs or Vim).
        if (selected == null && ForegroundApp.Get() is { CopyWorks: false }) { CardWindow.Hint("Can't read the selection in this app"); return; }
        if (selected == null) { how = "copy"; selected = await SelectionReader.ReadByCopying(); }
        var done = clock.Elapsed.TotalMilliseconds;
        // Timings only: the selected text never goes in the log.
        Core.Log(FormattableString.Invariant($"{{\"event\":\"selection\",\"how\":\"{(selected == null ? "none" : how)}\",\"warm\":{warm:F1},\"automation\":{read - warm:F1},\"point\":{point - read:F1},\"copy\":{done - point:F1}}}"));
        if (selected == null) { CardWindow.Hint($"Highlight Chinese text, or point at a word and press {Shortcut.Name}"); return; }
        Present(selected);
    }

    /// The icon's menu, kept short as Windows tray menus are: how to look up, the reading
    /// model when it needs something, then Settings, Check for Updates, Report a problem and Exit. A double-click
    /// on the icon opens Settings.
    static void MakeTray()
    {
        var menu = new Forms.ContextMenuStrip();
        // Clicking here would take the focus from the app with the selection, so the menu only says how.
        var hint = new Forms.ToolStripMenuItem { Enabled = false };
        void Hint() => hint.Text = Shortcut.Registered ? $"Select Chinese text or point at a word, then press {Shortcut.Name}" : "Select Chinese text, then click the eye";
        Hint();
        Shortcut.Changed += Hint;
        menu.Items.Add(hint);
        modelItem = new Forms.ToolStripMenuItem("Reading model: checking…", null, (_, _) => ModelClicked()) { Visible = false };
        menu.Items.Add(modelItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(History.MenuItem());   // History: "Lookup history…"
        var settings = new Forms.ToolStripMenuItem("Settings…", null, (_, _) => SettingsWindow.Open());
        settings.Font = new System.Drawing.Font(settings.Font, System.Drawing.FontStyle.Bold);
        menu.Items.Add(settings);
        if (Updates.Available) menu.Items.Add("Check for updates…", null, (_, _) => Updates.CheckNow());
        menu.Items.Add("Report a problem", null, (_, _) => Report());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Exit("menu", TimeSpan.FromSeconds(4)));
        tray = new Forms.NotifyIcon
        {
            Icon = LoadIcon(), Text = "Longyan Reader", Visible = true, ContextMenuStrip = menu,
        };
        tray.MouseDoubleClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) SettingsWindow.Open(); };
        tray.BalloonTipClicked += (_, _) => { var act = balloonClicked; balloonClicked = null; act?.Invoke(); };
    }

    /// Exit: everything that watches or wakes stops at once and the icon goes, then the model
    /// is freed (waiting out a reply, or a load for up to `wait`: a first load can't be stopped,
    /// so after that the process ends without the exit handlers that would wait for it).
    static void Exit(string why, TimeSpan wait)
    {
        if (exiting) return;
        exiting = true;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        // Each step on its own: one that fails mustn't keep the app running with no icon.
        Try(() => { if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; } });
        Try(() => InputWatch.Enable(false));
        Try(Chip.Hide);
        Try(Core.Shared.Stop);
        Try(ModelDownload.Stop);
        Try(Speech.Stop);
        Try(Updates.Stop);
        // The cards' windows, and with them their mouse and keyboard hooks.
        foreach (var w in Application.Current.Windows.Cast<Window>().ToList()) Try(w.Close);
        var stopped = clock.Elapsed.TotalMilliseconds;
        var freed = Core.Shutdown(wait);
        var total = clock.Elapsed.TotalMilliseconds;
        Diagnostics.Write(FormattableString.Invariant($"exit ({why}): stopped in {stopped:F0} ms, model {(freed ? "freed" : "still busy")} at {total:F0} ms; {Core.Shared.DrainSummary}"));
        Core.Log(FormattableString.Invariant($"{{\"event\":\"exit\",\"stopped\":{stopped:F0},\"total\":{total:F0},\"freed\":{(freed ? "true" : "false")}}}"));
        Diagnostics.ExitedCleanly();
        if (!freed) System.Diagnostics.Process.GetCurrentProcess().Kill();
        Application.Current.Shutdown();
    }

    /// WinSparkle has started the new version's installer, which replaces this copy's files.
    public static void ExitForUpdate() => Exit("update", TimeSpan.FromSeconds(4));

    static void Try(Action step)
    {
        try { step(); }
        catch (Exception e) { Diagnostics.Write("exit: " + Diagnostics.Describe(e)); }
    }

    public static void Report() => Diagnostics.Report(modelStatus.Length == 0 ? "checking"
        : modelStatus + (ModelDownload.IsDownloaded ? ", file downloaded" : ", no file"));

    /// The eye's settings changed, in Settings or the eye's own right-click menu.
    public static void MenuChanged()
    {
        Chip.Enable();
        SettingsWindow.Refresh();
    }

    static System.Drawing.Icon LoadIcon()
    {
        var path = System.IO.Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        return System.IO.File.Exists(path) ? new System.Drawing.Icon(path) : System.Drawing.SystemIcons.Application;
    }

    /// The model's state from the core: "ready", "unloadable", "no-memory", "too-slow" (this PC
    /// is too slow for it, so it isn't loaded or offered), or why it can't pick.
    static void ModelChanged(string status)
    {
        modelStatus = status;
        ModelDownload.TooSlow = status is "too-slow" or "needs-arm64";
        UpdateMenu();
        if (status == "ready") toldAbout = null;
        // Each problem said once until it's fixed; the menu keeps saying it.
        if (status == toldAbout || status is not ("unloadable" or "no-memory" or "too-slow" or "needs-arm64")) return;
        toldAbout = status;
        Balloon(status switch
        {
            "unloadable" => "The reading model couldn't load, so cards list meanings in dictionary order. Use this icon's menu to download it again.",
            "too-slow" => "This PC is too slow for the reading model. Cards use dictionary order.",
            "needs-arm64" => "The reading model needs the ARM version of Longyan Reader. Cards use dictionary order.",
            _ => "There isn't enough free memory for the reading model, so cards list meanings in dictionary order. It tries again in a minute.",
        });
    }

    /// The tray's model line, shown only when the model needs something or is downloading;
    /// Settings and the welcome window show the rest.
    static void UpdateMenu()
    {
        SettingsWindow.Refresh();
        WelcomeWindow.Refresh();
        if (modelItem == null) return;
        var running = ModelDownload.Running || ModelDownload.Checking;
        modelItem.Text = running ? modelItem.Text
            : modelStatus == "ready" ? "Reading model: ready"
            : modelStatus == "too-slow" ? "Reading model: this PC is too slow for it"
            : modelStatus == "needs-arm64" ? "Reading model: this PC needs the ARM version of Longyan Reader"
            : modelStatus == "no-memory" ? "Reading model: not enough free memory, trying again soon"
            : modelStatus == "unloadable" || ModelDownload.IsDownloaded ? "Reading model: couldn't load it (click to download it again)"
            : $"Download reading model ({ModelDownload.Size / 1_000_000_000.0:0.0} GB)…";
        modelItem.Enabled = ModelDownload.Running || (!ModelDownload.Checking && modelStatus is not ("ready" or "no-memory" or "too-slow" or "needs-arm64"));
        modelItem.Visible = running || (modelStatus.Length > 0 && modelStatus != "ready");
    }

    /// The tray's model line: download, or stop the download.
    static void ModelClicked()
    {
        if (ModelDownload.Running) ModelDownload.Stop(); else GetModel();
    }

    /// Download, Download again or Resume, from the tray, Settings or the welcome window.
    public static async void GetModel()
    {
        if (ModelDownload.Running || ModelDownload.Checking || modelStatus == "ready") return;
        if (ModelDownload.TooSlow)
        {
            Balloon(modelStatus == "needs-arm64" ? "The reading model needs the ARM version of Longyan Reader. Cards use dictionary order."
                : "This PC is too slow for the reading model. Cards use dictionary order.");
            return;
        }
        if (ModelDownload.IsDownloaded)
        {
            // A file that didn't load may still be the right one: check it before 2.7 GB again.
            if (modelItem != null) { modelItem.Text = "Checking the reading model…"; modelItem.Enabled = false; }
            bool good;
            try { good = await ModelDownload.Verify(); } catch (Exception e) { Diagnostics.Write("couldn't check the model file: " + e.Message); good = false; }
            Diagnostics.Write("the model file is " + (good ? "the right one" : "damaged"));
            if (good)
            {
                if (modelVerified) Balloon("The reading model's file is fine, but it doesn't load on this PC. Click here to report the problem.", Report);
                else { Balloon("The reading model's file is fine. Loading it again."); toldAbout = null; Core.Shared.RefreshModel(); }
                modelVerified = true;
                UpdateMenu();
                return;
            }
        }
        void Progress() { if (modelItem != null && ModelDownload.Running) modelItem.Text = $"Downloading the reading model: {ModelDownload.Progress:P0} (click to stop)"; }
        ModelDownload.Changed += Progress;
        UpdateMenu();
        var error = await ModelDownload.Run();
        ModelDownload.Changed -= Progress;
        if (error == null) { toldAbout = null; modelVerified = false; Core.Shared.RefreshModel(); if (!WelcomeWindow.IsOpen) Balloon("The reading model is ready."); }
        else if (error != "stopped" && !WelcomeWindow.IsOpen) Balloon("The reading model didn't download: " + error);
        UpdateMenu();
    }

    /// A notification from the icon; `clicked` runs if the reader clicks it.
    static void Balloon(string text, Action? clicked = null)
    {
        balloonClicked = clicked;
        tray?.ShowBalloonTip(4000, "Longyan Reader", text, Forms.ToolTipIcon.None);
    }
}
