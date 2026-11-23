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
        Focus(window);

        // 感冒: the 4th and 5th characters of the first line.
        Keys(VK_CONTROL, VK_HOME);
        for (var i = 0; i < 3; i++) Keys(VK_RIGHT);
        for (var i = 0; i < 2; i++) Keys(VK_SHIFT, VK_RIGHT);
        Check("1-word", app, new[] { "感冒", "MEANINGS" });

        Keys(VK_ESCAPE);
        Thread.Sleep(800);
        Focus(window);
        // The whole second line: a phrase card.
        Keys(VK_CONTROL, VK_HOME);
        Keys(VK_DOWN);
        Keys(VK_HOME);
        Keys(VK_SHIFT, VK_END);
        Check("2-phrase", app, new[] { "明朝", "WORDS" });

        Keys(VK_ESCAPE);
        try { notepad.Kill(); } catch { }
        try { app.Kill(); } catch { }
        foreach (var f in failures) Console.WriteLine("FAILED: " + f);
        return failures.Count == 0 ? 0 : 1;
    }

    /// Presses the shortcut, then waits for the card to settle, as the core reports it (the
    /// app's event log): the model's pick in, the translation in and no row still waiting.
    /// Three minutes at most.
    static void Check(string name, Process app, string[] expect)
    {
        var before = File.Exists(log) ? File.ReadAllLines(log).Length : 0;
        Keys(VK_CONTROL, VK_MENU, 0x4C);
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
    static INPUT Mouse(uint flags) => new() { type = 0, u = new InputUnion { mi = new MOUSEINPUT { dwFlags = flags } } };

    const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_END = 0x23, VK_HOME = 0x24, VK_RIGHT = 0x27, VK_DOWN = 0x28;
    const uint MOUSEEVENTF_LEFTDOWN = 2, MOUSEEVENTF_LEFTUP = 4;

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
}
