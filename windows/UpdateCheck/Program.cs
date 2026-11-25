using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Automation;
using Microsoft.Win32;

namespace Longyan;

/// The Windows app finding and installing an update from a local feed, as a reader would:
///   1. Automatic check (turned on, as after "Check automatically"): WinSparkle offers the
///      x64 build, not the newer arm64-only one, and Remind me later closes it.
///   2. Check now in Settings, with a tampered installer: the signature fails, nothing runs.
///   3. Check now again with the real one: it downloads, the signature checks out, Install
///      update runs the installer and the app exits for it.
/// The installer runs with the silent update's flags. With ARCH arm64 (the x64 app on an ARM
/// PC), the app reads appcast-windows-x64-on-arm64.xml and is offered the ARM64 installer.
/// Usage: UpdateCheck APP_EXE FEED_DIR SERVER_LOG OUT_DIR VERSION [ARCH]
/// Run as LongyanReader-Setup-*.exe it is the test installer: it notes its arguments and exits.
static class Program
{
    const string UpdateArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /OPEN=1";
    static readonly string marker = Path.Combine(Path.GetTempPath(), "longyan-test-installer.txt");
    static readonly string appLog = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "logs", "longyan.log");
    static string outDir = ".";
    static int failures;

    static int Main(string[] args)
    {
        var self = Path.GetFileName(Environment.ProcessPath ?? "");
        if (self.StartsWith("LongyanReader-Setup-", StringComparison.OrdinalIgnoreCase))
        {
            File.WriteAllText(marker, $"{Environment.ProcessPath} {string.Join(" ", args)}\n");
            return 0;
        }
        var (exe, feedDir, serverLog, version) = (args[0], args[1], args[2], args[4]);
        var arch = args.Length > 5 ? args[5] : "x64";
        outDir = Path.GetFullPath(args[3]);
        Directory.CreateDirectory(outDir);
        File.Delete(marker);
        var installer = Path.Combine(feedDir, $"LongyanReader-Setup-{version}-{arch}.exe");
        if (!File.Exists(installer)) return Fail("no " + installer);
        var feedName = arch == "arm64" ? "appcast-windows-x64-on-arm64.xml" : "appcast-windows.xml";

        // 0. The second launch: WinSparkle asks whether to check automatically. The question is
        // in front, with the app's icon in its title bar, and Check automatically checks at once.
        using (var key = Registry.CurrentUser.CreateSubKey(@"Software\LongyanReader\Updates"))
        {
            key.SetValue("DidRunOnce", "1");
            key.DeleteValue("CheckForUpdates", false);
            key.DeleteValue("LastCheckTime", false);
        }
        var app = Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)! })!;
        var ask = WaitForUpdateWindow(TimeSpan.FromSeconds(120), "Check for updates automatically?");
        Thread.Sleep(1000);
        Shot("0-ask");
        if (ask == null) return Fail("no question on the second launch");
        var hwnd = (IntPtr)ask.Current.NativeWindowHandle;
        Check(InFront(hwnd), "the question is in front (" + (GetForegroundWindow() == hwnd ? "with the focus" : "without the focus") + ")");
        Check(SameIcon(hwnd, Path.Combine(Path.GetDirectoryName(exe)!, "LongyanReader.ico")), "the question has the app's icon in its title bar");
        Click(ask, "Check automatically");

        // 1. Automatic checks on, never checked: WinSparkle checks at once.
        var offer = WaitForUpdateWindow(TimeSpan.FromSeconds(120), "is now available");
        Shot("1-automatic-offer");
        if (offer == null) return Fail("no update offered by the automatic check");
        var text = AllText(offer);
        Console.WriteLine("offer: " + text);
        Check(text.Contains($"Longyan Reader {version} is now available"), $"offers {version}, the newest build for {arch}");
        Check(Read(serverLog).Contains("GET /" + feedName), "read " + feedName);
        if (arch == "arm64") Check(LogHas("on ARM64, so the ARM64 build next"), "the app knows it's the x64 build on an ARM PC");
        Check(Button(offer, "Install update") != null && Button(offer, "Skip this version") != null, "Install update and Skip this version are there");
        Click(offer, "Remind me later");
        Thread.Sleep(2000);
        Check(!Read(serverLog).Contains(Path.GetFileName(installer)), "nothing downloaded before Install update");
        Check(LogHas("updates: found a new version") && LogHas("updates: remind me later"), "the app logged the offer and Remind me later");

        // 2. A tampered installer: downloaded, refused, not run.
        var good = File.ReadAllBytes(installer);
        File.WriteAllBytes(installer, good.Concat(new byte[] { 0 }).ToArray());
        if (!CheckNow(exe)) return Fail("no Check now button in Settings");
        offer = WaitForUpdateWindow(TimeSpan.FromSeconds(60), "is now available");
        if (offer == null) { Shot("2-no-offer"); return Fail("Check now offered nothing"); }
        Click(offer, "Install update");
        var refused = WaitForUpdateWindow(TimeSpan.FromSeconds(60), "improperly signed");
        Shot("2-tampered");
        Check(refused != null, "a tampered installer is refused (\"The update is improperly signed.\")");
        Check(!File.Exists(marker), "the tampered installer didn't run");
        if (refused != null) Click(refused, "Cancel");
        File.WriteAllBytes(installer, good);
        Thread.Sleep(1000);

        // 3. The real one.
        if (!CheckNow(exe)) return Fail("no Check now button in Settings the second time");
        offer = WaitForUpdateWindow(TimeSpan.FromSeconds(60), "is now available");
        if (offer == null) { Shot("3-no-offer"); return Fail("Check now offered nothing the second time"); }
        Shot("3-offer");
        Click(offer, "Install update");
        var ready = WaitForUpdateWindow(TimeSpan.FromSeconds(60), "Ready to install");
        Shot("3-ready");
        if (ready == null) return Fail("the download didn't finish (no \"Ready to install.\")");
        Check(Read(serverLog).Contains("GET /" + Path.GetFileName(installer)), "the installer was downloaded from the feed's URL");
        Click(ready, "Install update");
        for (var i = 0; i < 40 && !(File.Exists(marker) && app.HasExited); i++) Thread.Sleep(500);
        Shot("3-installed");
        Check(File.Exists(marker), "Install update ran the installer");
        if (File.Exists(marker)) Console.WriteLine("installer ran: " + File.ReadAllText(marker).Trim());
        Check(File.Exists(marker) && File.ReadAllText(marker).Contains(Path.GetFileName(installer)), "the " + arch + " installer");
        Check(File.Exists(marker) && File.ReadAllText(marker).Contains(UpdateArgs), "silently: " + UpdateArgs);
        Check(app.HasExited, "the app exited for the installer");
        Check(LogHas("exit (update)"), "the app logged its exit for the update");
        if (!app.HasExited) app.Kill();
        File.Copy(appLog, Path.Combine(outDir, "longyan.log"), true);
        Console.WriteLine(failures == 0 ? "all good" : $"{failures} failed");
        return failures == 0 ? 0 : 1;
    }

    /// Settings (opening the app again opens it in the running copy), then Check now.
    static bool CheckNow(string exe)
    {
        Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)! })?.WaitForExit(10000);
        var end = DateTime.Now.AddSeconds(20);
        while (DateTime.Now < end)
        {
            var settings = AutomationElement.RootElement.FindFirst(TreeScope.Children,
                new PropertyCondition(AutomationElement.NameProperty, "Longyan Reader settings"));
            var button = settings?.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "CheckForUpdates"));
            if (button != null)
            {
                Shot("settings");
                ((InvokePattern)button.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
                return true;
            }
            Thread.Sleep(500);
        }
        return false;
    }

    /// WinSparkle's window ("Software Update") once it shows `text`.
    static AutomationElement? WaitForUpdateWindow(TimeSpan timeout, string text)
    {
        var end = DateTime.Now + timeout;
        while (DateTime.Now < end)
        {
            var windows = AutomationElement.RootElement.FindAll(TreeScope.Children,
                new PropertyCondition(AutomationElement.NameProperty, "Software Update"));
            foreach (AutomationElement w in windows)
                if (AllText(w).Contains(text)) return w;
            Thread.Sleep(500);
        }
        return null;
    }

    static string AllText(AutomationElement window)
    {
        try
        {
            return string.Join(" | ", window.FindAll(TreeScope.Descendants, Condition.TrueCondition).Cast<AutomationElement>()
                .Where(e => !e.Current.IsOffscreen).Select(e => e.Current.Name).Where(n => !string.IsNullOrWhiteSpace(n)));
        }
        catch (ElementNotAvailableException) { return ""; }
    }

    static AutomationElement? Button(AutomationElement window, string name) =>
        window.FindAll(TreeScope.Descendants, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                new PropertyCondition(AutomationElement.NameProperty, name)))
            .Cast<AutomationElement>().FirstOrDefault(b => !b.Current.IsOffscreen && b.Current.IsEnabled);

    static void Click(AutomationElement window, string name)
    {
        var b = Button(window, name);
        if (b == null) { Check(false, $"a {name} button"); return; }
        ((InvokePattern)b.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        Console.WriteLine("clicked " + name);
    }

    static bool LogHas(string text) => Read(appLog).Contains(text);

    /// A file another process is still writing (the app's log, the server's).
    static string Read(string path)
    {
        try
        {
            using var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return new StreamReader(s).ReadToEnd();
        }
        catch { return ""; }
    }

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "ok: " : "FAILED: ") + what);
        if (!ok) failures++;
    }

    static int Fail(string why)
    {
        Console.WriteLine("FAILED: " + why);
        try { File.Copy(appLog, Path.Combine(outDir, "longyan.log"), true); } catch { }
        foreach (var p in Process.GetProcessesByName("LongyanReader")) p.Kill();
        return 1;
    }

    /// The window has the focus, or is the first visible window under the always-on-top ones (the taskbar).
    static bool InFront(IntPtr hwnd)
    {
        if (GetForegroundWindow() == hwnd) return true;
        var first = IntPtr.Zero;
        EnumWindows((h, _) =>
        {
            if (!IsWindowVisible(h) || (GetWindowLong(h, -20) & 8) != 0) return true;   // GWL_EXSTYLE, WS_EX_TOPMOST
            first = h;
            return false;
        }, IntPtr.Zero);
        return first == hwnd;
    }

    /// The window's title bar icon is the one in `ico`, pixel for pixel.
    static bool SameIcon(IntPtr hwnd, string ico)
    {
        var shown = SendMessage(hwnd, 0x7F, 0, 0);   // WM_GETICON, ICON_SMALL
        var size = GetSystemMetrics(49);   // SM_CXSMICON
        var app = LoadImage(IntPtr.Zero, ico, 1, size, size, 0x10);   // IMAGE_ICON, LR_LOADFROMFILE
        if (shown == IntPtr.Zero || app == IntPtr.Zero) return false;
        using var a = Icon.FromHandle(shown).ToBitmap();
        using var b = Icon.FromHandle(app).ToBitmap();
        if (a.Size != b.Size) { Console.WriteLine($"icon sizes {a.Size} and {b.Size}"); return false; }
        for (var y = 0; y < a.Height; y++)
            for (var x = 0; x < a.Width; x++)
                if (a.GetPixel(x, y) != b.GetPixel(x, y)) return false;
        return true;
    }

    delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int cx, int cy, uint load);

    static void Shot(string name)
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        using var bmp = new Bitmap(b.Width, b.Height);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        bmp.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
    }
}
