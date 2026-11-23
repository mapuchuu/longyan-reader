using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Text.Json.Nodes;
using System.Windows.Automation;

namespace Longyan;

/// Uses the Windows app as a reader would, on a desktop with nothing else open: starts it,
/// selects Chinese text in Notepad, presses Ctrl+Alt+L, and saves a screenshot and the card's
/// text once the card settles (the model's pick and translation in, when there's a model).
/// Usage: UiCheck APP_EXE OUT_DIR
static class Program
{
    static string outDir = ".";
    static string log = "";
    static readonly List<string> failures = new();

    static int Main(string[] args)
    {
        var exe = args[0];
        outDir = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(outDir);
        log = Path.Combine(outDir, "events.jsonl");
        Console.OutputEncoding = new UTF8Encoding(false);

        // Windows Server ships with "animate controls inside windows" off, which the app takes as
        // Reduce Motion. Turn it on so the films show the usual motion.
        SystemParametersInfo(SPI_SETCLIENTAREAANIMATION, 0, (IntPtr)1, SPIF_SENDCHANGE);
        SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, out var animates, 0);
        Console.WriteLine($"animations {(animates != 0 ? "on" : "off")}");

        var start = new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)! };
        start.Environment["LONGYAN_CARD_LOG"] = log;
        var app = Process.Start(start)!;
        Thread.Sleep(12000);   // the dictionary and splitter load
        if (app.HasExited) { Console.WriteLine($"the app exited: {app.ExitCode}"); return 1; }
        Shot("0-started");

        var file = Path.Combine(Path.GetTempPath(), "longyan-ui.txt");
        File.WriteAllText(file, "他得了感冒，吃不了饭。\r\n明朝实行海禁，闭关锁国。\r\n", new UTF8Encoding(true));
        var notepad = Process.Start("notepad.exe", file)!;
        var window = WaitForWindow("longyan-ui", TimeSpan.FromSeconds(20));
        if (window == IntPtr.Zero) { Console.WriteLine("Notepad didn't open"); Shot("no-notepad"); return 1; }
        Thread.Sleep(1500);
        // A short Notepad at the top: the card then hangs over the dark console, where its
        // edges show in the frames.
        SetWindowPos(window, IntPtr.Zero, 40, 30, 760, 170, 0x4 /* SWP_NOZORDER */);
        Thread.Sleep(300);
        Focus(window);

        // 感冒: the 4th and 5th characters of the first line.
        Keys(VK_CONTROL, VK_HOME);
        for (var i = 0; i < 3; i++) Keys(VK_RIGHT);
        for (var i = 0; i < 2; i++) Keys(VK_SHIFT, VK_RIGHT);
        Check("1-word", app, new[] { "感冒", "Meanings" }, burst: true);

        // Feel: hover a meaning, pick it, drag the card, then Esc.
        if (FindText(app, "(common) cold") is System.Windows.Rect cold)
        {
            MoveTo(cold.Left + 20, cold.Top + cold.Height / 2);
            Thread.Sleep(400);
            Shot("1-hover");
            Click(cold.Left + 20, cold.Top + cold.Height / 2);
            Burst("1-pick", 700);
            Thread.Sleep(500);
            Shot("1-picked");
            Drag(cold.Left + 20, cold.Top + cold.Height / 2, 160, 90);
            Thread.Sleep(300);
            Shot("1-moved");
        }
        else failures.Add("1-word: no \"(common) cold\" row to hover");

        Keys(VK_ESCAPE);
        Burst("1-close", 300);
        Thread.Sleep(300);
        if (CardOpen(app)) failures.Add("1-word: Esc didn't close the card");
        Thread.Sleep(800);
        Focus(window);
        // The whole second line: a phrase card.
        Keys(VK_CONTROL, VK_HOME);
        Keys(VK_DOWN);
        Keys(VK_HOME);
        Keys(VK_SHIFT, VK_END);
        Check("2-phrase", app, new[] { "明朝", "Words" }, burst: true);

        // Open a row: the card grows and the detail slides in.
        if (FindText(app, "to implement") is System.Windows.Rect row)
        {
            Click(row.Left + 10, row.Top + row.Height / 2);
            Burst("2-open", 800);
            Thread.Sleep(1500);
            Shot("2-opened");
            // Ctrl and the wheel zoom in until the card scrolls; two notches down glide, then
            // back up and back to the usual size.
            MoveTo(row.Left + 10, row.Top + row.Height / 2);
            CtrlWheel(120, 7);
            Thread.Sleep(800);
            Shot("2-zoomed");
            Wheel(-240);
            Burst("2-scroll", 600);
            Wheel(240);
            Thread.Sleep(600);
            CtrlWheel(-120, 7);
            Thread.Sleep(800);
            Click(row.Left + 10, row.Top + row.Height / 2);
            Burst("2-shut", 800);
        }
        else failures.Add("2-phrase: no \"to implement\" row to open");

        Keys(VK_ESCAPE);
        Thread.Sleep(800);
        EyeCheck(window);

        try { notepad.Kill(); } catch { }
        try { app.Kill(); } catch { }
        Latencies();
        foreach (var f in failures) Console.WriteLine("FAILED: " + f);
        return failures.Count == 0 ? 0 : 1;
    }

    /// Presses the shortcut, then waits for the card to settle, as the core reports it (the
    /// app's event log): the model's pick in, the translation in and no row still waiting.
    /// Three minutes at most.
    static void Check(string name, Process app, string[] expect, bool burst = false)
    {
        var before = File.Exists(log) ? File.ReadAllLines(log).Length : 0;
        Keys(VK_CONTROL, VK_MENU, 0x4C);
        if (burst) Burst(name + "-reveal", 2000);
        var started = DateTime.Now;
        var shotEarly = false;
        JsonObject? card = null;
        while ((DateTime.Now - started).TotalSeconds < 180)
        {
            Thread.Sleep(500);
            card = LastCard(before);
            if (card == null) continue;
            if (!shotEarly) { Thread.Sleep(300); Shot(name + "-first"); shotEarly = true; Console.WriteLine($"[{name}] first card after {(DateTime.Now - started).TotalSeconds:0.0} s"); }
            if (Settled(card)) break;
        }
        Console.WriteLine($"[{name}] {(card != null && Settled(card) ? "settled" : "NOT settled")} after {(DateTime.Now - started).TotalSeconds:0.0} s");
        Thread.Sleep(600);   // the last change drawn
        Shot(name);
        var text = CardText(app);
        File.WriteAllText(Path.Combine(outDir, name + ".txt"), text, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(outDir, name + ".json"), card?.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) ?? "", new UTF8Encoding(false));
        Console.WriteLine($"[{name}] card text:\n{text}\n");
        if (card == null || !Settled(card)) failures.Add($"{name}: the card didn't settle");
        foreach (var e in expect) if (!text.Contains(e)) failures.Add($"{name}: no \"{e}\" on the card");
    }

    /// The eye: a plain click shows nothing; a double-click on Chinese text shows it; hovering
    /// grows it; a click on it opens the card; a drag shows it too; a key press hides it.
    static void EyeCheck(IntPtr notepad)
    {
        if (TextIn(notepad, "海禁") is not System.Windows.Rect word) { failures.Add("3-eye: couldn't find 海禁 in Notepad"); return; }
        double x = word.Left + word.Width / 2, y = word.Top + word.Height / 2;
        Click(x, y);
        Thread.Sleep(800);
        if (Eye() != IntPtr.Zero) failures.Add("3-eye: a plain click showed the eye");
        DoubleClick(x, y);
        Burst("3-eye-in", 700);
        var eye = Eye();
        Shot("3-eye");
        if (eye == IntPtr.Zero) { failures.Add("3-eye: no eye after a double-click on Chinese text"); return; }
        GetWindowRect(eye, out var r);
        double cx = (r.Left + r.Right) / 2.0, cy = (r.Top + r.Bottom) / 2.0;
        Console.WriteLine($"[3-eye] at {r.Left},{r.Top} to {r.Right},{r.Bottom}; the word at {word}");
        MoveTo(cx, cy);
        Thread.Sleep(600);
        Shot("3-eye-hover");
        var before = File.Exists(log) ? File.ReadAllLines(log).Length : 0;
        Click(cx, cy);
        Burst("3-eye-reveal", 1500);
        var started = DateTime.Now;
        JsonObject? card = null;
        while ((DateTime.Now - started).TotalSeconds < 60 && (card = LastCard(before)) == null) Thread.Sleep(300);
        Thread.Sleep(800);
        Shot("3-eye-card");
        if (card == null) failures.Add("3-eye: clicking the eye opened no card");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);

        Drag(word.Left - word.Width, y, (int)(word.Width * 2), 0);
        Thread.Sleep(700);
        Shot("3-eye-drag");
        if (Eye() == IntPtr.Zero) failures.Add("3-eye: no eye after dragging over Chinese text");
        Keys(VK_RIGHT);
        Thread.Sleep(500);
        if (Eye() != IntPtr.Zero) failures.Add("3-eye: a key press didn't hide the eye");
    }

    /// The eye's window, when one is showing.
    static IntPtr Eye()
    {
        var found = IntPtr.Zero;
        EnumWindows((h, _) =>
        {
            var sb = new StringBuilder(64);
            GetWindowText(h, sb, 64);
            if (IsWindowVisible(h) && sb.ToString() == "Longyan eye") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    /// Where `text` is in a window's document, through its UI Automation text pattern.
    static System.Windows.Rect? TextIn(IntPtr hwnd, string text)
    {
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            foreach (AutomationElement e in root.FindAll(TreeScope.Subtree, Condition.TrueCondition))
            {
                if (!e.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern t) continue;
                var range = t.DocumentRange.FindText(text, false, false);
                var rects = range?.GetBoundingRectangles();
                if (rects is { Length: > 0 }) return rects[0];
            }
        }
        catch { }
        return null;
    }

    static void DoubleClick(double x, double y)
    {
        MoveTo(x, y);
        Thread.Sleep(60);
        var clicks4 = new[] { Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP), Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP) };
        SendInput(4, clicks4, Marshal.SizeOf<INPUT>());
    }

    /// For each click on the card: how long until the core's new card, and until it's drawn.
    /// Clicks sent, by the system's tick count, to match against the app's log.
    static readonly List<long> clicks = new();

    static void Latencies()
    {
        if (!File.Exists(log)) return;
        long? action = null, card = null;
        foreach (var line in File.ReadAllLines(log))
        {
            if (JsonNode.Parse(line) is not JsonObject e) continue;
            var t = (long?)e["t"] ?? 0;
            switch ((string?)e["event"])
            {
                case "shortcut":
                    action = t; card = null;
                    break;
                case "eye":
                    Console.WriteLine($"[latency] the eye appeared (readable: {e["readable"]})");
                    break;
                case "eye-click":
                    action = t; card = null;
                    break;
                case "revealed" when action != null:
                    Console.WriteLine($"[latency] the card on screen {t - action} ms after the shortcut or eye");
                    break;
                case "selection":
                    Console.WriteLine($"[latency] shortcut: warm-up {e["warm"]} ms, automation read {e["automation"]} ms, copy {e["copy"]} ms ({e["how"]})");
                    break;
                case "action":
                    action = t; card = null;
                    var k = (long?)e["k"] ?? 0;
                    var sent = clicks.Where(c => c <= k).DefaultIfEmpty(-1).Max();
                    if (sent >= 0) Console.WriteLine($"[latency] click sent to the app's handler {k - sent} ms");
                    break;
                case "card" when action != null && card == null: card = t; break;
                case "drawn" when action != null && card != null:
                    Console.WriteLine($"[latency] click to card {card - action} ms, to drawn {t - action} ms (drawing {e["ms"]} ms: build {e["build"]}, layout {e["layout"]}, fade {e["fade"]}, resize {e["resize"]})");
                    break;
                case "frames" when action != null:
                    Console.WriteLine($"[latency] first frame {e["first"]} ms after drawn; {e["count"]} frames in 0.6 s, longest gap {e["gap"]} ms");
                    action = null; break;
            }
        }
    }

    /// The newest card event after line `skip` of the log.
    static JsonObject? LastCard(int skip)
    {
        if (!File.Exists(log)) return null;
        string[] lines;
        try { lines = File.ReadAllLines(log); } catch { return null; }
        for (var i = lines.Length - 1; i >= skip; i--)
        {
            if (JsonNode.Parse(lines[i]) is JsonObject e && (string?)e["event"] == "card") return e["card"] as JsonObject;
        }
        return null;
    }

    static bool Settled(JsonObject card)
    {
        if ((string?)card["kind"] == "phrase")
        {
            if (card["translation"] == null && card["translationError"] == null) return false;
            foreach (var r in card["rows"]?.AsArray() ?? new JsonArray())
                if ((bool?)r?["pending"] == true || ((string?)r?["status"])?.StartsWith("Reading") == true) return false;
            return true;
        }
        return (string?)card["status"] != "Reading the sentence…";
    }

    /// The text of the app's visible windows, through UI Automation, as a screen reader sees it.
    static string CardText(Process app)
    {
        var sb = new StringBuilder();
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
        {
            foreach (AutomationElement t in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
            {
                var name = t.Current.Name;
                if (!string.IsNullOrWhiteSpace(name)) sb.AppendLine(name);
            }
        }
        return sb.ToString();
    }

    /// Frames of the screen as fast as they come for `ms`, kept in memory and saved after, so the
    /// capture doesn't slow itself down: name-00.png, name-01.png, … with the times in name.txt.
    static void Burst(string name, int ms)
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        var frames = new List<(double t, Bitmap bmp)>();
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < ms)
        {
            var bmp = new Bitmap(b.Width, b.Height);
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
            frames.Add((clock.Elapsed.TotalMilliseconds, bmp));
            Thread.Sleep(10);
        }
        var dir = Path.Combine(outDir, name);
        Directory.CreateDirectory(dir);
        var times = new StringBuilder();
        for (var i = 0; i < frames.Count; i++)
        {
            frames[i].bmp.Save(Path.Combine(dir, $"{i:00}.png"), ImageFormat.Png);
            frames[i].bmp.Dispose();
            times.AppendLine($"{i:00}\t{frames[i].t:0}");
        }
        File.WriteAllText(Path.Combine(dir, "times.txt"), times.ToString());
        Console.WriteLine($"[{name}] {frames.Count} frames in {ms} ms");
    }

    /// Where a piece of the card's text is on screen (pixels), through UI Automation.
    static System.Windows.Rect? FindText(Process app, string contains)
    {
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            foreach (AutomationElement t in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
                if (t.Current.Name.Contains(contains)) return t.Current.BoundingRectangle;
        return null;
    }

    static bool CardOpen(Process app)
    {
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            if (!w.Current.IsOffscreen && w.Current.BoundingRectangle.Width > 0 && w.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)) != null) return true;
        return false;
    }

    static void MoveTo(double x, double y) => SetCursorPos((int)x, (int)y);

    static void Click(double x, double y)
    {
        MoveTo(x, y);
        Thread.Sleep(60);
        var click = new[] { Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP) };
        clicks.Add(Environment.TickCount64);
        SendInput(2, click, Marshal.SizeOf<INPUT>());
    }

    /// Presses at (x, y), moves by (dx, dy) in steps, and lets go.
    static void Drag(double x, double y, int dx, int dy)
    {
        MoveTo(x, y);
        Thread.Sleep(60);
        SendInput(1, new[] { Mouse(MOUSEEVENTF_LEFTDOWN) }, Marshal.SizeOf<INPUT>());
        for (var i = 1; i <= 12; i++) { MoveTo(x + dx * i / 12.0, y + dy * i / 12.0); Thread.Sleep(16); }
        SendInput(1, new[] { Mouse(MOUSEEVENTF_LEFTUP) }, Marshal.SizeOf<INPUT>());
    }

    static void Shot(string name)
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        using var bmp = new Bitmap(b.Width, b.Height);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        bmp.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
    }

    static IntPtr WaitForWindow(string title, TimeSpan timeout)
    {
        var end = DateTime.Now + timeout;
        while (DateTime.Now < end)
        {
            var found = IntPtr.Zero;
            EnumWindows((h, _) =>
            {
                var sb = new StringBuilder(256);
                GetWindowText(h, sb, 256);
                if (IsWindowVisible(h) && sb.ToString().Contains(title)) { found = h; return false; }
                return true;
            }, IntPtr.Zero);
            if (found != IntPtr.Zero) return found;
            Thread.Sleep(300);
        }
        return IntPtr.Zero;
    }

    /// Brings the window forward with a click in it, as a reader would.
    static void Focus(IntPtr hwnd)
    {
        SetForegroundWindow(hwnd);
        GetWindowRect(hwnd, out var r);
        SetCursorPos((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2);
        var click = new[] { Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP) };
        clicks.Add(Environment.TickCount64);
        SendInput(2, click, Marshal.SizeOf<INPUT>());
        Thread.Sleep(500);
    }

    /// Presses the keys together and lets them go in reverse order.
    static void Keys(params int[] vks)
    {
        var inputs = vks.Select(k => Key(k, false)).Concat(vks.Reverse().Select(k => Key(k, true))).ToArray();
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        Thread.Sleep(120);
    }

    static INPUT Key(int vk, bool up) => new()
    {
        type = 1,
        u = new InputUnion { ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = (up ? 2u : 0u) | (Extended(vk) ? 1u : 0u) } },
    };
    static bool Extended(int vk) => vk is VK_HOME or VK_END or VK_RIGHT or VK_DOWN;
    static INPUT Mouse(uint flags, int data = 0) => new() { type = 0, u = new InputUnion { mi = new MOUSEINPUT { dwFlags = flags, mouseData = unchecked((uint)data) } } };

    static void CtrlWheel(int delta, int times)
    {
        SendInput(1, new[] { Key(VK_CONTROL, false) }, Marshal.SizeOf<INPUT>());
        for (var i = 0; i < times; i++) { Wheel(delta); Thread.Sleep(80); }
        SendInput(1, new[] { Key(VK_CONTROL, true) }, Marshal.SizeOf<INPUT>());
    }

    static void Wheel(int delta) => SendInput(1, new[] { Mouse(MOUSEEVENTF_WHEEL, delta) }, Marshal.SizeOf<INPUT>());

    const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_END = 0x23, VK_HOME = 0x24, VK_RIGHT = 0x27, VK_DOWN = 0x28;
    const uint MOUSEEVENTF_LEFTDOWN = 2, MOUSEEVENTF_LEFTUP = 4, MOUSEEVENTF_WHEEL = 0x0800;

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, IntPtr value, uint flags);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, out int value, uint flags);
    const uint SPI_GETCLIENTAREAANIMATION = 0x1042, SPI_SETCLIENTAREAANIMATION = 0x1043, SPIF_SENDCHANGE = 2;
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
}
