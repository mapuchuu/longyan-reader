using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// UiCheck --first-run APP_EXE OUT_DIR: a first-time reader on a clean profile (no settings,
/// no model), filmed from the start (OUT_DIR/film, film.mp4 in the workflow). The welcome window
/// must open at once; the sample line looks up before there's a model (a dictionary card at
/// once); Download starts the model with a dead first host (so it moves to the next one),
/// Stop keeps what's in, Resume carries on from there, the checksum is checked, and the next
/// card has the model's pick. Done closes the window and the icon says where the app went.
static partial class Program
{
    static int FirstRun(string exe, string output)
    {
        outDir = Path.GetFullPath(output);
        Directory.CreateDirectory(outDir);
        log = Path.Combine(outDir, "events.jsonl");
        Console.OutputEncoding = new UTF8Encoding(false);
        SystemParametersInfo(SPI_SETCLIENTAREAANIMATION, 0, (IntPtr)1, SPIF_SENDCHANGE);

        // A clean profile: what a first install finds.
        var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader");
        try { if (Directory.Exists(data)) Directory.Delete(data, true); } catch (Exception e) { Console.WriteLine("couldn't clear the profile: " + e.Message); }
        using (var run = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)) run?.DeleteValue("Longyan Reader", false);
        var models = Path.Combine(data, "models");
        var modelFile = Path.Combine(models, "qwen3.5-4b-q4_k_m.gguf");

        using var film = new Film(Path.Combine(outDir, "film"));
        var start = new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)! };
        start.Environment["LONGYAN_CARD_LOG"] = log;
        // Nothing listens on port 9: every piece fails there first, and the download moves on.
        start.Environment["LONGYAN_DOWNLOAD_HOSTS"] = "http://127.0.0.1:9/,https://huggingface.co/";
        var clock = Stopwatch.StartNew();
        var app = Process.Start(start)!;

        // 1. The welcome window, at once (before the dictionary has loaded).
        var window = WaitForWindow("Welcome to Longyan Reader", TimeSpan.FromSeconds(30), exact: true);
        var opened = clock.Elapsed.TotalSeconds;
        Console.WriteLine($"[first-run] welcome window after {opened:0.0} s");
        if (window == IntPtr.Zero) { failures.Add("first-run: no welcome window"); Shot("fr-0-no-welcome"); return Finish(app); }
        if (opened > 6) failures.Add($"first-run: the welcome window took {opened:0.0} s to open");
        if (!Bring(window)) failures.Add("first-run: couldn't bring the welcome window to the front");
        Thread.Sleep(1000);
        Shot("fr-1-welcome");
        var root = AutomationElement.FromHandle(window);
        var text = WindowText(root);
        File.WriteAllText(Path.Combine(outDir, "fr-1-welcome.txt"), text, new UTF8Encoding(false));
        Console.WriteLine("[first-run] welcome text:\n" + text);
        foreach (var want in new[] { "Select Chinese text in any app", "Ctrl+Alt+L", "under the pointer", "notification area", "Recommended. ", "2.7 GB download" })
            if (!text.Contains(want)) failures.Add($"first-run: the welcome window doesn't say \"{want}\"");
        if (text.Contains('—')) failures.Add("first-run: an em dash in the welcome window");

        // The model's button waits for the core to say whether this PC can run the model.
        var button = Find(root, "ModelButton");
        if (!WaitFor(() => button?.Current.IsEnabled == true, 60)) failures.Add("first-run: the Download button never became usable");
        Console.WriteLine($"[first-run] model button \"{button?.Current.Name}\" usable after {clock.Elapsed.TotalSeconds:0.0} s");
        if (button?.Current.Name != "Download") failures.Add($"first-run: the model's button says \"{button?.Current.Name}\", not Download");

        // 2. Before the model: a dictionary card at once.
        var before = LookUpSample(root, "fr-2-card-no-model", out var card, settle: false);
        if (card == null) failures.Add("first-run: no card from the sample line before the model");
        else
        {
            if ((string?)card["copy"] != "感冒") failures.Add($"first-run: the sample's card is for {(string?)card["copy"]}");
            var status = (string?)card["status"] ?? "";
            Console.WriteLine($"[first-run] card before the model: {status}");
            if (!status.StartsWith("Dictionary order")) failures.Add($"first-run: the card before the model says \"{status}\", not dictionary order");
            if (before > 5) failures.Add($"first-run: the card before the model took {before:0.0} s");
        }
        Keys(VK_ESCAPE);
        Thread.Sleep(800);
        if (!IsWindowVisible(window)) failures.Add("first-run: Esc on the sample's card closed the welcome window too");

        // 3. Download, then Stop once some is in: what's in stays.
        if (button?.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern download) download.Invoke();
        else failures.Add("first-run: can't press Download");
        film.Every = 500;
        var started = clock.Elapsed.TotalSeconds;
        double got = 0;
        WaitFor(() => (got = Downloaded(root)) >= 0.4, 600);
        Console.WriteLine($"[first-run] {got:0.0} GB after {clock.Elapsed.TotalSeconds - started:0} s");
        Shot("fr-3-downloading");
        if (got < 0.4) failures.Add("first-run: the download didn't get going");
        var appLog = Path.Combine(data, "logs", "longyan.log");
        var logText = ReadShared(appLog);
        if (!logText.Contains("trying huggingface.co")) failures.Add("first-run: the download didn't move on from the dead host");
        if (Find(root, "ModelButton") is AutomationElement stop && stop.Current.Name == "Stop" && stop.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern s) s.Invoke();
        else failures.Add("first-run: no Stop button while downloading");
        WaitFor(() => Find(root, "ModelButton")?.Current.Name == "Resume", 30);
        Thread.Sleep(1000);
        Shot("fr-4-stopped");
        var stoppedText = WindowText(root);
        var kept = Regex.Match(stoppedText, @"(\d+\.\d) GB is downloaded so far") is { Success: true } m ? double.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture) : 0;
        Console.WriteLine($"[first-run] stopped with {kept:0.0} GB kept; pieces file: {File.Exists(modelFile + ".pieces")}");
        if (Find(root, "ModelButton")?.Current.Name != "Resume") failures.Add("first-run: after Stop the button isn't Resume");
        if (kept < got - 0.3) failures.Add($"first-run: Stop kept {kept:0.0} GB of {got:0.0}");
        if (!File.Exists(modelFile + ".pieces")) failures.Add("first-run: no list of pieces after Stop");

        // 4. Resume: from where it stopped, to the checksum, to ready.
        if (Find(root, "ModelButton")?.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern resume) resume.Invoke();
        double first = 0;
        WaitFor(() => (first = Downloaded(root)) > 0, 60);
        Console.WriteLine($"[first-run] resumed at {first:0.0} GB");
        if (first < kept - 0.1) failures.Add($"first-run: Resume started at {first:0.0} GB, not {kept:0.0}");
        film.Every = 2000;   // a time lapse through the rest of the download
        var sawChecking = false;
        var ready = WaitFor(() =>
        {
            var t = WindowText(root);
            if (t.Contains("Checking the download") && !sawChecking) { sawChecking = true; Shot("fr-5-checking"); film.Every = 300; }
            return t.Contains("Ready. It picks");
        }, 900);
        Console.WriteLine($"[first-run] model {(ready ? "ready" : "NOT ready")} after {clock.Elapsed.TotalSeconds - started:0} s");
        film.Every = 200;
        Thread.Sleep(800);
        Shot("fr-6-ready");
        if (!ready) failures.Add("first-run: the model never got to Ready");
        if (!sawChecking) Console.WriteLine("[first-run] (the check was too quick to see)");
        if (!File.Exists(modelFile) || new FileInfo(modelFile).Length != 2_740_937_888) failures.Add("first-run: no model file of the right size");
        if (File.Exists(modelFile + ".part") || File.Exists(modelFile + ".pieces")) failures.Add("first-run: the .part or .pieces file was left behind");
        if (ReadShared(appLog).Contains("couldn't save the list of pieces")) failures.Add("first-run: the list of pieces couldn't be saved");
        Console.WriteLine("[first-run] app log:\n" + string.Join("\n", ReadShared(appLog).Split('\n').Where(l => l.Contains("model"))));

        // 5. The next card: open at once, then the model's pick fills in.
        LookUpSample(root, "fr-7-card-model", out card, settle: true);
        var after = (string?)card?["status"];
        Console.WriteLine($"[first-run] card with the model: {after ?? "(picked)"}");
        if (card == null) failures.Add("first-run: no card once the model was ready");
        else if (after?.StartsWith("Dictionary order") == true) failures.Add($"first-run: with the model the card still says \"{after}\"");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);

        // 6. Done: the window goes, the icon says where the app is, and Open at login is on.
        if (Find(root, "Done")?.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern done) done.Invoke();
        else failures.Add("first-run: no Done button");
        Thread.Sleep(1500);
        Shot("fr-8-after-done");
        Thread.Sleep(2500);
        if (IsWindowVisible(window)) failures.Add("first-run: Done didn't close the welcome window");
        using (var run = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            if (run?.GetValue("Longyan Reader") is not string) failures.Add("first-run: Open at login isn't on");
        return Finish(app);
    }

    /// Brings a window to the front. Windows 11 refuses SetForegroundWindow to a process that
    /// isn't in front (as UiCheck isn't once Notepad is), so then a click on its title bar.
    /// On the ARM runner the welcome window stayed behind Notepad, and the shortcut looked up
    /// Notepad's selection (海) instead of the sample's.
    static bool Bring(IntPtr window)
    {
        SetForegroundWindow(window);
        Thread.Sleep(200);
        if (GetForegroundWindow() != window)
        {
            GetWindowRect(window, out var r);
            SetCursorPos(r.Left + 120, r.Top + 12);
            clicks.Add(Environment.TickCount64);
            SendInput(2, new[] { Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP) }, Marshal.SizeOf<INPUT>());
            Thread.Sleep(500);
        }
        return GetForegroundWindow() == window;
    }

    static int Finish(Process app)
    {
        try { app.Kill(); } catch { }
        foreach (var f in failures) Console.WriteLine("FAILED: " + f);
        return failures.Count == 0 ? 0 : 1;
    }

    /// Selects 感冒 in the welcome window's sample line and presses the shortcut. Seconds until
    /// the card's first contents, and the card as it was last (settled, if asked).
    static double LookUpSample(AutomationElement root, string name, out JsonObject? card, bool settle)
    {
        card = null;
        var sample = Find(root, "Sample");
        if (sample == null) { failures.Add("first-run: no sample line"); return 0; }
        try
        {
            sample.SetFocus();
            Thread.Sleep(300);
            ((TextPattern)sample.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.FindText("感冒", false, false)?.Select();
        }
        catch (Exception e) { Console.WriteLine($"[{name}] couldn't select in the sample: " + e.Message); }
        Thread.Sleep(300);
        var skip = File.Exists(log) ? File.ReadAllLines(log).Length : 0;
        Keys(VK_CONTROL, VK_MENU, 0x4C);
        var clock = Stopwatch.StartNew();
        double first = 0;
        while (clock.Elapsed.TotalSeconds < 180)
        {
            card = LastCard(skip);
            if (card != null && first == 0)
            {
                first = clock.Elapsed.TotalSeconds;
                Thread.Sleep(300);
                Shot(name + "-first");
                Console.WriteLine($"[{name}] first card after {first:0.0} s: {(string?)card["status"] ?? "(picked)"}");
            }
            if (card != null && (!settle || (string?)card["status"] != "Reading the sentence…")) break;
            Thread.Sleep(300);
        }
        Thread.Sleep(1200);
        Shot(name);
        if (card != null)
            File.WriteAllText(Path.Combine(outDir, name + ".json"), card.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }), new UTF8Encoding(false));
        return first;
    }

    static AutomationElement? Find(AutomationElement root, string id)
    {
        try { return root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, id)); }
        catch { return null; }
    }

    /// Every piece of text in the window, one per line, as a screen reader reads it.
    static string WindowText(AutomationElement root)
    {
        try
        {
            var all = root.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text));
            return string.Join("\n", all.Cast<AutomationElement>().Select(e => e.Current.Name).Where(n => n.Length > 0));
        }
        catch { return ""; }
    }

    /// GB downloaded, from "Downloading: 1.2 of 2.7 GB", or 0.
    static double Downloaded(AutomationElement root) =>
        Regex.Match(WindowText(root), @"Downloading: (\d+\.\d) of") is { Success: true } m ? double.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture) : 0;

    static bool WaitFor(Func<bool> done, double seconds)
    {
        var end = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < end)
        {
            try { if (done()) return true; } catch { }
            Thread.Sleep(500);
        }
        try { return done(); } catch { return false; }
    }

    static string ReadShared(string path)
    {
        try
        {
            using var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return new StreamReader(s).ReadToEnd();
        }
        catch { return ""; }
    }

    /// The screen, filmed: a JPEG every `Every` ms into a folder, numbered, with the time each
    /// was taken in times.txt (the workflow makes film.mp4 from them).
    sealed class Film : IDisposable
    {
        readonly string dir;
        readonly Thread thread;
        readonly StreamWriter times;
        volatile bool stop;
        public volatile int Every = 200;

        public Film(string dir)
        {
            this.dir = dir;
            Directory.CreateDirectory(dir);
            // Written as it goes, so a cancelled job still has it.
            times = new StreamWriter(Path.Combine(dir, "times.txt")) { AutoFlush = true };
            thread = new Thread(Loop) { IsBackground = true };
            thread.Start();
        }

        void Loop()
        {
            var jpeg = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
            using var quality = new EncoderParameters(1);
            quality.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 80L);
            var clock = Stopwatch.StartNew();
            var n = 0;
            while (!stop)
            {
                var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
                try
                {
                    using var bmp = new Bitmap(b.Width, b.Height);
                    using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
                    bmp.Save(Path.Combine(dir, $"{n:00000}.jpg"), jpeg, quality);
                    lock (times) times.WriteLine($"{n:00000}\t{clock.Elapsed.TotalMilliseconds:0}");
                    n++;
                }
                catch { }
                Thread.Sleep(Every);
            }
        }

        public void Dispose()
        {
            stop = true;
            thread.Join(3000);
            lock (times) times.Dispose();
        }
    }
}
