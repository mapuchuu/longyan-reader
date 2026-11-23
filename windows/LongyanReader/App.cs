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
    static Forms.ToolStripMenuItem? eyeItem, eyeAppsItem;
    static string modelStatus = "";
    static bool lastRunEndedBadly, reportOffered, exiting, checkingModel, modelVerified;
    static string? toldAbout;
    static Action? balloonClicked;
    const string AgainEvent = "LongyanReader.Windows.Again";

    [STAThread]
    static int Main(string[] args)
    {
        // --render DIR OUT: draws every DIR/*.json card into OUT, light and dark (gallery.yml).
        if (args.Length == 3 && args[0] == "--render") return RenderGallery(args[1], args[2]);
        // --check-shortcut: the default shortcut on each installed keyboard layout (UiCheck).
        if (args.Length == 1 && args[0] == "--check-shortcut") return Shortcut.Check();

        using var single = new Mutex(true, "LongyanReader.Windows", out var first);
        if (!first)
        {
            // The running copy says so.
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
        ThreadPool.RegisterWaitForSingleObject(openedAgain, (_, _) => app.Dispatcher.BeginInvoke(() =>
            Balloon("Longyan Reader is already running. Its icon is in the notification area (under the ^ arrow if it's hidden).")),
            null, Timeout.Infinite, false);
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
        return 0;
    }

    static void Start()
    {
        var core = Core.Shared;
        core.Ready += status =>
        {
            modelStatus = status;
            UpdateMenu();
            Application.Current.Dispatcher.BeginInvoke(CardWindow.Warm, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            if (lastRunEndedBadly)
            {
                lastRunEndedBadly = false;
                reportOffered = true;
                Balloon("Longyan Reader closed unexpectedly last time. Click here to report the problem.", Report);
            }
            else if (status != "ready" && !ModelDownload.IsDownloaded) Balloon("Longyan Reader is ready. Download the reading model from this icon's menu to pick meanings and translate.");
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
        Shortcut.Start(LookUp, (text, pick) => { Balloon(text, pick ? ShortcutWindow.Open : null); if (pick) ShortcutWindow.Open(); });
        Chip.Clicked = EyeClicked;
        Chip.Start();
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
            Core.Log($"{{\"event\":\"point\",\"found\":\"{PointReader.Found}\"}}");
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

    static void MakeTray()
    {
        var menu = new Forms.ContextMenuStrip();
        // Clicking here would take the focus from the app with the selection, so the menu only says how.
        var hint = new Forms.ToolStripMenuItem { Enabled = false };
        void Hint() => hint.Text = Shortcut.Registered ? $"Select Chinese text, then click the eye or press {Shortcut.Name}" : "Select Chinese text, then click the eye";
        Hint();
        Shortcut.Changed += Hint;
        menu.Items.Add(hint);
        modelItem = new Forms.ToolStripMenuItem("Reading model: checking…", null, (_, _) => ModelClicked());
        menu.Items.Add(modelItem);
        eyeItem = new Forms.ToolStripMenuItem("Show the eye when you select text", null, (_, _) => { Settings.ShowEye = !Settings.ShowEye; MenuChanged(); });
        menu.Items.Add(eyeItem);
        eyeAppsItem = new Forms.ToolStripMenuItem("Hide the eye in");
        menu.Items.Add(eyeAppsItem);
        menu.Items.Add("Change shortcut…", null, (_, _) => ShortcutWindow.Open());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Report a problem", null, (_, _) => Report());
        menu.Items.Add("Exit", null, (_, _) => Exit("menu", TimeSpan.FromSeconds(4)));
        tray = new Forms.NotifyIcon
        {
            Icon = LoadIcon(), Text = "Longyan Reader", Visible = true, ContextMenuStrip = menu,
        };
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

    static void Try(Action step)
    {
        try { step(); }
        catch (Exception e) { Diagnostics.Write("exit: " + Diagnostics.Describe(e)); }
    }

    static void Report() => Diagnostics.Report(modelStatus.Length == 0 ? "checking"
        : modelStatus + (ModelDownload.IsDownloaded ? ", file downloaded" : ", no file"));

    /// The eye's menu items, after a change from the tray or the eye's own right-click menu.
    public static void MenuChanged()
    {
        if (eyeItem == null || eyeAppsItem == null) return;
        Chip.Enable();
        eyeItem.Checked = Settings.ShowEye;
        // Apps the eye is hidden in, ticked (as the Mac's "Hide Eye In"): a click brings it back.
        eyeAppsItem.DropDownItems.Clear();
        foreach (var (process, name) in Settings.EyeHiddenApps)
            eyeAppsItem.DropDownItems.Add(new Forms.ToolStripMenuItem(name, null, (_, _) => { Settings.ShowEyeIn(process); MenuChanged(); }) { Checked = true });
        eyeAppsItem.Visible = Settings.ShowEye && eyeAppsItem.DropDownItems.Count > 0;
    }

    static System.Drawing.Icon LoadIcon()
    {
        var path = System.IO.Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        return System.IO.File.Exists(path) ? new System.Drawing.Icon(path) : System.Drawing.SystemIcons.Application;
    }

    /// The model's state from the core: "ready", "unloadable", "no-memory", or why it can't pick.
    static void ModelChanged(string status)
    {
        modelStatus = status;
        UpdateMenu();
        if (status == "ready") toldAbout = null;
        // Each problem said once until it's fixed; the menu keeps saying it.
        if (status == toldAbout || status is not ("unloadable" or "no-memory")) return;
        toldAbout = status;
        Balloon(status == "unloadable"
            ? "The reading model couldn't load, so cards list meanings in dictionary order. Use this icon's menu to download it again."
            : "There isn't enough free memory for the reading model, so cards list meanings in dictionary order. It tries again in a minute.");
    }

    static void UpdateMenu()
    {
        if (modelItem == null) return;
        modelItem.Text = ModelDownload.Running || checkingModel ? modelItem.Text
            : modelStatus == "ready" ? "Reading model: ready"
            : modelStatus == "no-memory" ? "Reading model: not enough free memory, trying again soon"
            : modelStatus == "unloadable" || ModelDownload.IsDownloaded ? "Reading model: couldn't load it (click to download it again)"
            : $"Download reading model ({ModelDownload.Size / 1_000_000_000.0:0.0} GB)…";
        modelItem.Enabled = ModelDownload.Running || (!checkingModel && modelStatus != "ready" && modelStatus != "no-memory");
    }

    static async void ModelClicked()
    {
        if (ModelDownload.Running) { ModelDownload.Stop(); return; }
        if (modelStatus == "ready" || checkingModel) return;
        if (ModelDownload.IsDownloaded)
        {
            // A file that didn't load may still be the right one: check it before 2.7 GB again.
            checkingModel = true;
            if (modelItem != null) { modelItem.Text = "Checking the reading model…"; modelItem.Enabled = false; }
            bool good;
            try { good = await ModelDownload.Verify(); } catch (Exception e) { Diagnostics.Write("couldn't check the model file: " + e.Message); good = false; }
            checkingModel = false;
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
        var progress = new Progress<double>(p => { if (modelItem != null) modelItem.Text = $"Downloading the reading model: {p:P0} (click to stop)"; });
        var error = await ModelDownload.Run(progress);
        if (error == null) { toldAbout = null; modelVerified = false; Core.Shared.RefreshModel(); Balloon("The reading model is ready."); }
        else Balloon("The reading model didn't download: " + error);
        UpdateMenu();
    }

    /// A notification from the icon; `clicked` runs if the reader clicks it.
    static void Balloon(string text, Action? clicked = null)
    {
        balloonClicked = clicked;
        tray?.ShowBalloonTip(4000, "Longyan Reader", text, Forms.ToolTipIcon.None);
    }
}
