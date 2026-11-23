using System;
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

    [STAThread]
    static int Main(string[] args)
    {
        // --render DIR OUT: draws every DIR/*.json card into OUT, light and dark (gallery.yml).
        if (args.Length == 3 && args[0] == "--render") return RenderGallery(args[1], args[2]);

        using var single = new Mutex(true, "LongyanReader.Windows", out var first);
        if (!first) return 0;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += (_, _) => Start();
        app.Run();
        return 0;
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
                CardWindow.RenderToFile(card, System.IO.Path.Combine(output, name + (dark ? "-dark" : "") + ".png"));
            }
            Console.WriteLine(name);
        }
        return 0;
    }

    static void Start()
    {
        var core = Core.Shared;
        core.Ready += status =>
        {
            modelStatus = status;
            UpdateMenu();
            if (status != "ready" && !ModelDownload.IsDownloaded) Balloon("Longyan Reader is ready. Download the reading model from this icon's menu to pick meanings and translate.");
            else Balloon("Longyan Reader is ready. Select Chinese text in any app and press Ctrl+Alt+L.");
        };
        core.ModelChanged += status => { modelStatus = status; UpdateMenu(); };
        core.Failed += message => MessageBox.Show("Longyan Reader couldn't start: " + message, "Longyan Reader");
        core.Start();
        MakeTray();
        HotKey.Register(LookUp);
    }

    /// The shortcut: read the selection, else copy it, then open its card.
    static async void LookUp()
    {
        if (!Core.Shared.IsReady) { CardWindow.Hint("Dictionary still loading…"); return; }
        Bridge.ly_warm_up();
        var selected = SelectionReader.ReadAutomation() ?? await SelectionReader.ReadByCopying();
        if (selected == null) { CardWindow.Hint("Highlight Chinese text, then press Ctrl+Alt+L"); return; }
        CardWindow.Present(selected);
    }

    static void MakeTray()
    {
        var menu = new Forms.ContextMenuStrip();
        // Clicking here would take the focus from the app with the selection, so the menu only says how.
        menu.Items.Add(new Forms.ToolStripMenuItem("Select Chinese text, then press Ctrl+Alt+L") { Enabled = false });
        modelItem = new Forms.ToolStripMenuItem("Reading model: checking…", null, (_, _) => ModelClicked());
        menu.Items.Add(modelItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Longyan Reader", null, (_, _) => { tray!.Visible = false; Application.Current.Shutdown(); });
        tray = new Forms.NotifyIcon
        {
            Icon = LoadIcon(), Text = "Longyan Reader", Visible = true, ContextMenuStrip = menu,
        };
    }

    static System.Drawing.Icon LoadIcon()
    {
        var path = System.IO.Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        return System.IO.File.Exists(path) ? new System.Drawing.Icon(path) : System.Drawing.SystemIcons.Application;
    }

    static void UpdateMenu()
    {
        if (modelItem == null) return;
        modelItem.Text = ModelDownload.Running ? modelItem.Text
            : modelStatus == "ready" ? "Reading model: ready"
            : ModelDownload.IsDownloaded ? "Reading model: couldn't load it"
            : $"Download Reading Model ({ModelDownload.Size / 1_000_000_000.0:0.0} GB)…";
        modelItem.Enabled = ModelDownload.Running || modelStatus != "ready";
    }

    static async void ModelClicked()
    {
        if (ModelDownload.Running) { ModelDownload.Stop(); return; }
        if (modelStatus == "ready") return;
        var progress = new Progress<double>(p => { if (modelItem != null) modelItem.Text = $"Downloading the reading model: {p:P0} (click to stop)"; });
        var error = await ModelDownload.Run(progress);
        if (error == null) { Core.Shared.RefreshModel(); Balloon("The reading model is ready."); }
        else Balloon("The reading model didn't download: " + error);
        UpdateMenu();
    }

    static void Balloon(string text) => tray?.ShowBalloonTip(4000, "Longyan Reader", text, Forms.ToolTipIcon.None);
}

/// Ctrl+Alt+L anywhere, through a hidden window that receives WM_HOTKEY.
static class HotKey
{
    static HwndSource? source;
    static Action? pressed;

    public static void Register(Action onPress)
    {
        pressed = onPress;
        source = new HwndSource(new HwndSourceParameters("LongyanReaderHotKey") { Width = 0, Height = 0, WindowStyle = 0 });
        source.AddHook(Hook);
        if (!RegisterHotKey(source.Handle, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 0x4C))
            MessageBox.Show("Ctrl+Alt+L is taken by another app, so Longyan Reader can't use it. Quit the app that uses it and open Longyan Reader again.", "Longyan Reader");
    }

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY) { handled = true; pressed?.Invoke(); }
        return IntPtr.Zero;
    }

    const int WM_HOTKEY = 0x0312;
    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_NOREPEAT = 0x4000;
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
}
