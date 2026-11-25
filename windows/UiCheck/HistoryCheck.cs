using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// History, after the lookups in Program: the file has them (checked, never printed), the
/// window opens from `--history` and lists them, search narrows the list, Delete takes one
/// out; then the window's drawings with made-up entries (history/*.png).
static class HistoryCheck
{
    public static void Run(string exe, Process app, string outDir, List<string> failures)
    {
        void Fail(string why) { failures.Add("4-history: " + why); Console.WriteLine("[4-history] FAILED " + why); }
        var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "History", "lookups.jsonl");

        // The file: the word, the phrase and the eye's word, with meanings.
        var records = Records(file);
        Console.WriteLine($"[4-history] {records.Count} records: {records.Count(r => Str(r, "event") == "word")} words, {records.Count(r => Str(r, "event") == "phrase")} phrases, {records.Count(r => Str(r, "event") == "pick")} picks");
        var cold = records.LastOrDefault(r => Str(r, "event") == "word" && Str(r, "word") == "感冒");
        if (cold == null) Fail("the first lookup's word isn't in the history");
        else
        {
            if (Str(cold, "sentence") != "他得了感冒，吃不了饭。") Fail("the first lookup's sentence isn't the line it was in");
            if (Str(cold, "pinyin").Length == 0 || Str(cold, "meaningHere").Length == 0 || Str(cold, "gloss").Length == 0) Fail("the first lookup has no pinyin, meaning or dictionary sense");
            if (!Str(cold, "app").Equals("notepad", StringComparison.OrdinalIgnoreCase)) Fail("the first lookup's app isn't Notepad");
        }
        // The core leaves the closing 。 off a phrase.
        var phrase = records.LastOrDefault(r => Str(r, "event") == "phrase" && Str(r, "text").TrimEnd('。') == "明朝实行海禁，闭关锁国");
        if (phrase == null) Fail("the phrase isn't in the history");
        else if (Str(phrase, "translation").Length == 0) Fail("the phrase has no translation in the history");
        // A double-click selects one character, 海, whose card offers 海禁.
        var eye = records.LastOrDefault(r => Str(r, "event") == "word" && Str(r, "word").Length > 0 && "海禁".Contains(Str(r, "word")));
        if (eye == null) Fail("the eye's word isn't in the history");
        if (records.Any(r => Str(r, "at").Length == 0)) Fail("a record has no time");

        // The window, from --history, as a second copy passes it on.
        using (var p = Process.Start(new ProcessStartInfo(exe, "--history") { WorkingDirectory = Path.GetDirectoryName(exe)! })!) p.WaitForExit(15000);
        var window = WaitForWindow(app, "Lookup history", 10000);
        if (window == null) { Fail("--history didn't open the window"); Shot(outDir, "4-history-none"); }
        else
        {
            Thread.Sleep(1500);
            Shot(outDir, "4-history");
            foreach (var why in Undrawn(window)) Fail("from --history, " + why);
            var rows = Rows(window);
            Console.WriteLine($"[4-history] the window lists {rows.Count} lookups");
            var expected = new[] { "感冒", "明朝实行海禁，闭关锁国", eye == null ? "海禁" : Str(eye, "word") };
            for (var i = 0; i < expected.Length; i++)
                if (!rows.Any(n => n.TrimEnd('。') == expected[i] || n.StartsWith(expected[i] + ",") || n.StartsWith(expected[i] + "。,"))) Fail($"lookup {i + 1} isn't in the window's list");
            if (rows.Count > 0 && !rows[0].StartsWith(expected[2] + ",")) Fail("the newest lookup isn't first");

            // Search: only what has 感冒 in it.
            if (window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, "Search")) is AutomationElement box
                && box.TryGetCurrentPattern(ValuePattern.Pattern, out var vp))
            {
                ((ValuePattern)vp).SetValue("感冒");
                Thread.Sleep(800);
                Shot(outDir, "4-history-search");
                var found = Rows(window);
                Console.WriteLine($"[4-history] searching leaves {found.Count}");
                if (found.Count == 0 || found.Count >= rows.Count) Fail("search didn't narrow the list");

                // Delete the one found: it leaves the list and the file.
                if (window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem)) is AutomationElement item
                    && item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var sp))
                {
                    ((SelectionItemPattern)sp).Select();
                    item.SetFocus();
                    Thread.Sleep(300);
                    Keys(0x2E);   // Delete
                    Thread.Sleep(1200);
                    if (Records(file).Any(r => Str(r, "word") == "感冒")) Fail("Delete didn't take the lookup out of the file");
                    if (Rows(window).Count != found.Count - 1) Fail("Delete didn't take the lookup out of the list");
                }
                else Fail("no row to delete");
                ((ValuePattern)vp).SetValue("");
                Thread.Sleep(600);
            }
            else Fail("no search box");
            if (window.TryGetCurrentPattern(WindowPattern.Pattern, out var wp)) ((WindowPattern)wp).Close();
            Thread.Sleep(500);
        }

        // What the app logged about history (never the text).
        var appLog = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "logs", "longyan.log");
        try
        {
            using var f = new FileStream(appLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            foreach (var l in new StreamReader(f).ReadToEnd().Split('\n').Where(l => l.Contains("history"))) Console.WriteLine("[4-history log] " + l.Trim());
        }
        catch (Exception e) { Console.WriteLine("[4-history] no app log: " + e.GetType().Name); }

        // The drawings, with made-up entries.
        var drawn = Path.Combine(outDir, "history");
        var start = new ProcessStartInfo(exe, $"--render-history \"{drawn}\"")
        {
            UseShellExecute = false, RedirectStandardOutput = true, StandardOutputEncoding = new UTF8Encoding(false),
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        using (var r = Process.Start(start)!)
        {
            var output = r.StandardOutput.ReadToEnd();
            r.WaitForExit(60000);
            foreach (var l in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)) Console.WriteLine("[4-history render] " + l);
            if (r.ExitCode != 0) Fail($"--render-history exited with {r.ExitCode}");
        }
        foreach (var name in new[] { "history", "history-dark", "history-empty", "history-off", "history-search", "history-clear-dark" })
            if (!File.Exists(Path.Combine(drawn, name + ".png"))) Fail($"no {name}.png drawn");
    }

    /// The window opened from Settings' Open (Settings from opening the app again, as from
    /// Start): drawn as from --history, with its tabs, search box, More options and column
    /// names, on its grey. Open is invoked, or clicked with the mouse when `click` is given.
    public static void FromSettings(string exe, Process app, string outDir, List<string> failures, string name, Action<double, double>? click = null)
    {
        void Fail(string why) { failures.Add(name + ": " + why); Console.WriteLine($"[{name}] FAILED " + why); }
        using (var p = Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)! })!) p.WaitForExit(10000);
        var settings = WaitForWindow(app, "Longyan Reader settings", 10000);
        if (settings == null) { Fail("opening the app again didn't open Settings"); Shot(outDir, name + "-no-settings"); return; }
        Thread.Sleep(1000);
        if (settings.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "OpenHistory")) is not AutomationElement open
            || !open.TryGetCurrentPattern(InvokePattern.Pattern, out var ip)) { Fail("no Open button for history in Settings"); return; }
        if (click == null) ((InvokePattern)ip).Invoke();
        else
        {
            if (open.TryGetCurrentPattern(ScrollItemPattern.Pattern, out var scroll)) ((ScrollItemPattern)scroll).ScrollIntoView();
            Thread.Sleep(600);
            Shot(outDir, name + "-settings");
            var r = open.Current.BoundingRectangle;
            click(r.Left + r.Width / 2, r.Top + r.Height / 2);
        }
        var window = WaitForWindow(app, "Lookup history", 10000);
        if (window == null) { Fail("Open didn't open the window"); Shot(outDir, name + "-none"); }
        else
        {
            Thread.Sleep(1500);
            Shot(outDir, name);
            var undrawn = Undrawn(window);
            foreach (var why in undrawn) Fail(why);
            if (undrawn.Count > 0)
            {
                // Told to paint again: whether it's the drawing or the colours that are missing.
                RedrawWindow((IntPtr)window.Current.NativeWindowHandle, IntPtr.Zero, IntPtr.Zero, 0x1 | 0x4 | 0x80 | 0x100);
                Thread.Sleep(1000);
                Shot(outDir, name + "-repainted");
                var still = Undrawn(window);
                Console.WriteLine($"[{name}] painted again: {(still.Count == 0 ? "all drawn" : string.Join("; ", still))}");
            }
            // A setting changed in Windows (the window paints its colours again): still drawn.
            SendMessageTimeout((IntPtr)0xFFFF, 0x001A /* WM_SETTINGCHANGE */, IntPtr.Zero, "ImmersiveColorSet", 2, 2000, out _);
            Thread.Sleep(1500);
            Shot(outDir, name + "-setting-changed");
            foreach (var why in Undrawn(window)) Fail("after a setting change, " + why);
            if (window.TryGetCurrentPattern(WindowPattern.Pattern, out var wp)) ((WindowPattern)wp).Close();
        }
        var appLog = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "logs", "longyan.log");
        try
        {
            using var f = new FileStream(appLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            foreach (var l in new StreamReader(f).ReadToEnd().Split('\n').Where(l => l.Contains("history: drawn")).TakeLast(1)) Console.WriteLine($"[{name} log] " + l.Trim());
        }
        catch { }
        if (settings.TryGetCurrentPattern(WindowPattern.Pattern, out var sp)) ((WindowPattern)sp).Close();
        Thread.Sleep(500);
    }

    /// What of the window's bar, header and fill isn't on screen: each part must show ink
    /// (pixels well off its own commonest colour), and the window its grey.
    static List<string> Undrawn(AutomationElement window)
    {
        var o = new List<string>();
        var parts = new (string Name, ControlType Type, string What)[]
        {
            ("All", ControlType.RadioButton, "the All tab"),
            ("Phrases", ControlType.RadioButton, "the Phrases tab"),
            ("Search", ControlType.Edit, "the search box"),
            ("More options", ControlType.Button, "More options"),
            ("Chinese", ControlType.Text, "the Chinese column's name"),
            ("When", ControlType.Text, "the When column's name"),
        };
        System.Windows.Rect? tab = null;
        foreach (var (name, type, what) in parts)
        {
            var e = window.FindFirst(TreeScope.Descendants, new AndCondition(
                new PropertyCondition(AutomationElement.NameProperty, name), new PropertyCondition(AutomationElement.ControlTypeProperty, type)));
            if (e == null) { o.Add($"no {what}"); continue; }
            var r = e.Current.BoundingRectangle;
            if (name == "All") tab = r;
            var ink = Ink(r);
            Console.WriteLine($"[history drawn] {what}: {ink} ink pixels in {r.Width:0}x{r.Height:0}");
            if (ink < 12) o.Add($"{what} isn't drawn ({ink} ink pixels)");
        }
        if (tab is System.Windows.Rect t)
        {
            // Left of the first tab, in the bar's margin: the window's own colour.
            var c = Pixel((int)t.Left - 6, (int)(t.Top + t.Height / 2));
            var grey = c.R == c.G && c.G == c.B && (c.R is >= 0xEE and <= 0xF6 || c.R is >= 0x1C and <= 0x24);
            Console.WriteLine($"[history drawn] the window's fill: #{c.R:X2}{c.G:X2}{c.B:X2}");
            if (!grey) o.Add($"the window's fill is #{c.R:X2}{c.G:X2}{c.B:X2}, not its grey");
        }
        return o;
    }

    static int Ink(System.Windows.Rect r)
    {
        var w = Math.Max(1, (int)r.Width);
        var h = Math.Max(1, (int)r.Height);
        using var bmp = new Bitmap(w, h);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen((int)r.Left, (int)r.Top, 0, 0, new Size(w, h));
        var counts = new Dictionary<int, int>();
        var px = new List<Color>();
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) { var c = bmp.GetPixel(x, y); px.Add(c); counts[c.ToArgb()] = counts.GetValueOrDefault(c.ToArgb()) + 1; }
        var common = Color.FromArgb(counts.MaxBy(kv => kv.Value).Key);
        double L(Color c) => 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
        return px.Count(c => Math.Abs(L(c) - L(common)) > 40);
    }

    static Color Pixel(int x, int y)
    {
        using var bmp = new Bitmap(1, 1);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(x, y, 0, 0, new Size(1, 1));
        return bmp.GetPixel(0, 0);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, string l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr region, uint flags);

    static List<JsonObject> Records(string file)
    {
        var o = new List<JsonObject>();
        if (!File.Exists(file)) return o;
        foreach (var line in File.ReadAllLines(file, Encoding.UTF8))
        {
            if (line.Trim().Length == 0) continue;
            try { if (JsonNode.Parse(line) is JsonObject r) o.Add(r); } catch { o.Add(new JsonObject()); }
        }
        return o;
    }

    static string Str(JsonObject r, string key) => r[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    /// The names of the list's rows ("word, pinyin, meaning"), top first.
    static List<string> Rows(AutomationElement window)
    {
        var o = new List<string>();
        try
        {
            foreach (AutomationElement e in window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem)))
                o.Add(e.Current.Name);
        }
        catch { }
        return o;
    }

    static AutomationElement? WaitForWindow(Process app, string title, int ms)
    {
        var end = DateTime.Now.AddMilliseconds(ms);
        var cond = new AndCondition(new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id), new PropertyCondition(AutomationElement.NameProperty, title));
        while (DateTime.Now < end)
        {
            try { if (AutomationElement.RootElement.FindFirst(TreeScope.Children, cond) is AutomationElement w) return w; } catch { }
            Thread.Sleep(250);
        }
        return null;
    }

    static void Shot(string outDir, string name)
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        using var bmp = new Bitmap(b.Width, b.Height);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        bmp.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
    }

    static void Keys(ushort vk)
    {
        var size = Marshal.SizeOf<INPUT>();
        SendInput(2, new[]
        {
            new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = 1 } },
            new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = 1 | 2 } },
        }, size);
    }

    // A keyboard INPUT, padded to the size of the union's largest member (MOUSEINPUT).
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
}
