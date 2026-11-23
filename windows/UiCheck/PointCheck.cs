using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// Pointing at a word without selecting: with nothing selected in Notepad, the pointer over a
/// character and the shortcut pressed, the card is for the word that character is in. At the
/// start of a word (感 of 感冒) and in the middle of one (锁 of 闭关锁国), read from the text
/// pattern and not by copying. Over empty space, the hint.
static class PointCheck
{
    public static void Run(System.Diagnostics.Process app, IntPtr notepad, string log, List<string> failures, Action<string> shot)
    {
        Word(notepad, log, failures, shot, "4-point-start", "感", "感冒");
        Word(notepad, log, failures, shot, "4-point-middle", "锁", "闭关锁国");

        // Well past the end of the first line, on it.
        const string name = "4-point-empty";
        if (TextIn(notepad, "饭。") is not System.Windows.Rect end) { failures.Add($"{name}: couldn't find the end of the first line"); return; }
        Clear(notepad);
        SetCursorPos((int)(end.Right + 200), (int)(end.Top + end.Height / 2));
        Thread.Sleep(300);
        var before = Lines(log);
        Shortcut();
        var started = DateTime.Now;
        JsonObject? selection = null;
        while ((DateTime.Now - started).TotalSeconds < 10 && (selection = Last(log, before, "selection")) == null) Thread.Sleep(200);
        Thread.Sleep(800);
        shot(name);
        var found = (string?)Last(log, before, "point")?["found"];
        Console.WriteLine($"[{name}] point: {found ?? "not tried"}, selection: {(string?)selection?["how"] ?? "none logged"}");
        if (found is null or "text") failures.Add($"{name}: pointing at empty space found {found ?? "nothing logged"}");
        if ((string?)selection?["how"] != "none") failures.Add($"{name}: the shortcut read {(string?)selection?["how"] ?? "nothing logged"} over empty space");
        if (Last(log, before, "card") != null) failures.Add($"{name}: a card opened over empty space");
        if (!AppText(app).Contains("point at a word")) failures.Add($"{name}: no hint about pointing");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);
    }

    static void Word(IntPtr notepad, string log, List<string> failures, Action<string> shot, string name, string at, string expect)
    {
        if (TextIn(notepad, at) is not System.Windows.Rect r) { failures.Add($"{name}: couldn't find {at} in Notepad"); return; }
        Clear(notepad);
        SetCursorPos((int)(r.Left + r.Width / 2), (int)(r.Top + r.Height / 2));
        Thread.Sleep(300);
        var before = Lines(log);
        Shortcut();
        var started = DateTime.Now;
        JsonObject? card = null;
        while ((DateTime.Now - started).TotalSeconds < 60 && (card = Last(log, before, "card")) == null) Thread.Sleep(300);
        Thread.Sleep(1500);
        shot(name);
        var how = (string?)Last(log, before, "selection")?["how"];
        var found = (string?)Last(log, before, "point")?["found"];
        var word = (string?)card?["word"];
        Console.WriteLine($"[{name}] pointer on {at}: point {found ?? "not tried"}, read by {how ?? "nothing logged"}, card for {word ?? "nothing"} ({(string?)card?["kind"] ?? "no card"})");
        if (how != "point") failures.Add($"{name}: read by {how ?? "nothing logged"}, not by pointing");
        if (word != expect) failures.Add($"{name}: the card is for {word ?? "nothing"}, not {expect}");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);
    }

    /// Notepad in front with nothing selected (the caret at the end, no click on the text).
    static void Clear(IntPtr notepad)
    {
        SetForegroundWindow(notepad);
        Thread.Sleep(200);
        Keys(VK_CONTROL, VK_END);
        Thread.Sleep(200);
    }

    static void Shortcut() => Keys(VK_CONTROL, VK_MENU, 0x4C);

    static int Lines(string log) => File.Exists(log) ? File.ReadAllLines(log).Length : 0;

    /// The newest `name` event after line `skip` of the app's log.
    static JsonObject? Last(string log, int skip, string name)
    {
        if (!File.Exists(log)) return null;
        string[] lines;
        try { lines = File.ReadAllLines(log); } catch { return null; }
        for (var i = lines.Length - 1; i >= skip; i--)
            if (JsonNode.Parse(lines[i]) is JsonObject e && (string?)e["event"] == name) return e;
        return null;
    }

    /// The text of the app's windows (the card or hint), through UI Automation.
    static string AppText(System.Diagnostics.Process app)
    {
        var sb = new StringBuilder();
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            foreach (AutomationElement t in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
                sb.AppendLine(t.Current.Name);
        return sb.ToString();
    }

    /// Where `text` is in Notepad's document.
    static System.Windows.Rect? TextIn(IntPtr hwnd, string text)
    {
        try
        {
            foreach (AutomationElement e in AutomationElement.FromHandle(hwnd).FindAll(TreeScope.Subtree, Condition.TrueCondition))
            {
                if (!e.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern t) continue;
                var rects = t.DocumentRange.FindText(text, false, false)?.GetBoundingRectangles();
                if (rects is { Length: > 0 }) return rects[0];
            }
        }
        catch { }
        return null;
    }

    static void Keys(params int[] vks)
    {
        var inputs = vks.Select(k => Key(k, false)).Concat(vks.Reverse().Select(k => Key(k, true))).ToArray();
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        Thread.Sleep(120);
    }

    static INPUT Key(int vk, bool up) => new()
    {
        type = 1,
        u = new InputUnion { ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = (up ? 2u : 0u) | (vk == VK_END ? 1u : 0u) } },
    };

    const int VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_END = 0x23;

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
}
