using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// How the card behaves, against the Mac's (notes/windows-parity.md, Motion and behaviour):
/// it opens 8 below the selection with its left edge on the selection's, within 0.4 s of the
/// lookup plus drawing; Notepad keeps the focus through the shortcut and a click on a row;
/// the open card turns dark and back when Windows does, without closing; a click in another
/// app closes it; Esc closes it.
static class CardFeelCheck
{
    const string Name = "6-feel";

    public static void Run(System.Diagnostics.Process app, IntPtr notepad, string log, List<string> failures, Action<string> shot)
    {
        void Fail(string what) => failures.Add($"{Name}: {what}");

        // 感冒 selected, as in the first card.
        SetForegroundWindow(notepad);
        Thread.Sleep(300);
        Keys(VK_CONTROL, VK_HOME);
        for (var i = 0; i < 3; i++) Keys(VK_RIGHT);
        for (var i = 0; i < 2; i++) Keys(VK_SHIFT, VK_RIGHT);
        Thread.Sleep(300);
        var sel = SelectionIn(notepad);
        var before = Lines(log);
        Keys(VK_CONTROL, VK_MENU, 0x4C);
        var started = DateTime.Now;
        JsonObject? shown = null;
        while ((DateTime.Now - started).TotalSeconds < 30 && (shown = Last(log, before, "revealed")) == null) Thread.Sleep(100);
        if (shown == null) { Fail("no card opened"); return; }
        Thread.Sleep(800);
        shot(Name);
        Console.WriteLine($"[{Name}] revealed: {shown.ToJsonString()}; the selection at {sel}");

        // Placement: hanging below, left edges together, 8 between (PU:620-628).
        double left = (double?)shown["left"] ?? 0, top = (double?)shown["top"] ?? 0, width = (double?)shown["width"] ?? 0, scale = (double?)shown["scale"] ?? 1;
        if ((bool?)shown["below"] != true) Fail("the card isn't below the selection, with room below");
        if (sel is System.Windows.Rect s)
        {
            if (Math.Abs(left - s.Left) > 2) Fail($"the card's left edge is at {left:0}, the selection's at {s.Left:0}");
            var gap = top - s.Bottom;
            if (Math.Abs(gap - 8 * scale) > 3) Fail($"the card is {gap:0} px under the selection, not {8 * scale:0}");
        }
        else Fail("couldn't read where the selection is");
        // The hold: 0.4 s from the lookup at most, then drawing (PU:371-375).
        var opened = (double?)shown["opened"] ?? 0;
        Console.WriteLine($"[{Name}] on screen {opened:0} ms after the lookup started");
        if (opened > 1000) Fail($"the card took {opened:0} ms to open (the hold is 0.4 s)");

        // Never takes the focus: not on opening, not on a click on a row.
        if (GetForegroundWindow() != notepad) Fail("the card took the focus from Notepad when it opened");
        if (FindText(app, "(common) cold") is System.Windows.Rect row)
        {
            Click(row.Left + 20, row.Top + row.Height / 2);
            Thread.Sleep(700);
            if (GetForegroundWindow() != notepad) Fail("clicking a row took the focus from Notepad");
            if (!CardOpen(app)) Fail("clicking a row closed the card");
            MoveTo(row.Right + 400, row.Top + 200);   // off the card
        }
        else Fail("no \"(common) cold\" row to click");
        Thread.Sleep(500);

        // Dark and back with the card open: it follows at once and stays open (CC:262-270).
        var band = new Rectangle((int)left + 24, (int)top + 3, Math.Max(10, (int)(width / 3)), 5);
        var light = Brightness(band);
        SetAppsTheme(dark: true);
        Thread.Sleep(1500);
        var dark = Brightness(band);
        shot(Name + "-dark");
        var openDark = CardOpen(app);
        SetAppsTheme(dark: false);
        Thread.Sleep(1500);
        var back = Brightness(band);
        Console.WriteLine($"[{Name}] the card's top band: {light:0} light, {dark:0} dark, {back:0} light again");
        if (light < 200) Fail($"the card's surface isn't light to start with ({light:0})");
        if (dark > 90) Fail($"the open card didn't turn dark with Windows ({light:0} to {dark:0})");
        if (back < 200) Fail($"the open card didn't turn light again ({back:0})");
        if (!openDark) Fail("switching to dark closed the card");
        if (!CardOpen(app)) Fail("switching back to light closed the card");

        // Esc in another app closes it, and Notepad keeps the focus.
        SetForegroundWindow(notepad);
        Thread.Sleep(200);
        Keys(VK_ESCAPE);
        Thread.Sleep(600);
        if (CardOpen(app)) Fail("Esc didn't close the card");

        // A click in another app closes it too: the card again, then a click on the desktop's
        // console below Notepad.
        before = Lines(log);
        Keys(VK_CONTROL, VK_MENU, 0x4C);
        started = DateTime.Now;
        while ((DateTime.Now - started).TotalSeconds < 30 && Last(log, before, "revealed") == null) Thread.Sleep(100);
        Thread.Sleep(600);
        Click(900, 600);
        Thread.Sleep(600);
        if (CardOpen(app)) Fail("a click in another app didn't close the card");
        SetForegroundWindow(notepad);
        Thread.Sleep(300);
    }

    static double Brightness(Rectangle r)
    {
        using var bmp = new Bitmap(r.Width, r.Height);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Location, Point.Empty, r.Size);
        double sum = 0;
        for (var y = 0; y < r.Height; y++)
            for (var x = 0; x < r.Width; x++)
            {
                var c = bmp.GetPixel(x, y);
                sum += 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
            }
        return sum / (r.Width * r.Height);
    }

    static void SetAppsTheme(bool dark)
    {
        using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            key.SetValue("AppsUseLightTheme", dark ? 0 : 1, Microsoft.Win32.RegistryValueKind.DWord);
        SendMessageTimeout((IntPtr)0xFFFF, 0x001A /* WM_SETTINGCHANGE */, IntPtr.Zero, "ImmersiveColorSet", 2 /* SMTO_ABORTIFHUNG */, 2000, out _);
    }

    static int Lines(string log) => File.Exists(log) ? File.ReadAllLines(log).Length : 0;

    static JsonObject? Last(string log, int skip, string name)
    {
        if (!File.Exists(log)) return null;
        string[] lines;
        try { lines = File.ReadAllLines(log); } catch { return null; }
        for (var i = lines.Length - 1; i >= skip; i--)
            if (JsonNode.Parse(lines[i]) is JsonObject e && (string?)e["event"] == name) return e;
        return null;
    }

    static System.Windows.Rect? SelectionIn(IntPtr hwnd)
    {
        try
        {
            foreach (AutomationElement e in AutomationElement.FromHandle(hwnd).FindAll(TreeScope.Subtree, Condition.TrueCondition))
            {
                if (!e.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern t) continue;
                var rects = t.GetSelection().FirstOrDefault()?.GetBoundingRectangles();
                if (rects is not { Length: > 0 }) continue;
                var u = rects[0];
                foreach (var x in rects.Skip(1)) u.Union(x);
                return u;
            }
        }
        catch { }
        return null;
    }

    static System.Windows.Rect? FindText(System.Diagnostics.Process app, string contains)
    {
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            foreach (AutomationElement t in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
                if (t.Current.Name.Replace('\u00A0', ' ').Contains(contains)) return t.Current.BoundingRectangle;
        return null;
    }

    static bool CardOpen(System.Diagnostics.Process app)
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
        SendInput(2, new[] { Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP) }, Marshal.SizeOf<INPUT>());
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
        u = new InputUnion { ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = (up ? 2u : 0u) | (vk is VK_HOME or VK_RIGHT ? 1u : 0u) } },
    };
    static INPUT Mouse(uint flags) => new() { type = 0, u = new InputUnion { mi = new MOUSEINPUT { dwFlags = flags } } };

    const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_HOME = 0x24, VK_RIGHT = 0x27;
    const uint MOUSEEVENTF_LEFTDOWN = 2, MOUSEEVENTF_LEFTUP = 4;

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, string l, uint flags, uint timeout, out IntPtr result);
}
