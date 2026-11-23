using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Longyan;

/// The eye (windows/LongyanReader/Chip.cs) against the Mac's rule (Chip.swift show(at:)): for a
/// selection under 40 points tall, the 30-point button starts 4 after the selection's right edge
/// and is centred on its text; otherwise its bottom-left is 6 right of and 6 above where the
/// mouse let go; either way it stays on the working area. Measured from the pixels: the text's
/// centre is where its ink is on screen before it's selected, not the box UI Automation reports.
static partial class Program
{
    /// The very first eye after the app starts, the way a reader meets it: a double-click on 冒
    /// in the first line, the pointer onto the eye, a pause (the tooltip comes up), a click. It
    /// must sit on the line and open the card.
    static void FirstEye(Process app, IntPtr notepad, string name)
    {
        if (TextIn(notepad, "冒") is not System.Windows.Rect word) { failures.Add($"{name}: couldn't find 冒 in Notepad"); return; }
        Focus(notepad);
        Keys(VK_CONTROL, VK_HOME);
        var placed = Placement(name, notepad, () => DoubleClick(word.Left + word.Width / 2, word.Top + word.Height / 2), new[] { word }, word.Height);
        if (placed is not IntPtr eye) return;
        GetWindowRect(eye, out var r);
        double cx = (r.Left + r.Right) / 2.0, cy = (r.Top + r.Bottom) / 2.0;
        // Onto it the way a mouse gets there, a few steps, then a moment's rest.
        GetCursorPos(out var from);
        for (var i = 1; i <= 8; i++) { MoveTo(from.X + (cx - from.X) * i / 8, from.Y + (cy - from.Y) * i / 8); Thread.Sleep(15); }
        Thread.Sleep(1000);
        Shot(name + "-hover");
        var before = Lines();
        Click(cx, cy);
        var started = DateTime.Now;
        JsonObject? card = null;
        while ((DateTime.Now - started).TotalSeconds < 60 && (card = LastCard(before)) == null) Thread.Sleep(200);
        Thread.Sleep(1200);
        Shot(name + "-card");
        var clicked = LogHas(before, "eye-click", "event", "\"eye-click\"");
        var open = CardOpen(app);
        Console.WriteLine($"[{name}] eye click logged: {clicked}; card event: {card != null}; card on screen: {open}");
        if (!clicked) failures.Add($"{name}: the first click on the first eye didn't reach it");
        else if (card == null) failures.Add($"{name}: the first click on the first eye opened no card");
        else if (!open) failures.Add($"{name}: the first eye's card isn't on screen");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);
    }

    /// The eye: a plain click shows nothing; a double-click on Chinese text shows it beside the
    /// selection; hovering grows it; a click on it opens the card; a drag shows it too; a key
    /// press hides it; the middle button doesn't.
    static void EyeCheck(IntPtr notepad)
    {
        if (TextIn(notepad, "海禁") is not System.Windows.Rect word) { failures.Add("3-eye: couldn't find 海禁 in Notepad"); return; }
        double x = word.Left + word.Width / 2, y = word.Top + word.Height / 2;
        Click(x, y);
        Thread.Sleep(800);
        if (Eye() != IntPtr.Zero) failures.Add("3-eye: a plain click showed the eye");
        var logBefore = Lines();
        if (Placement("3-eye", notepad, () => DoubleClick(x, y), new[] { word }, word.Height, burst: "3-eye-in") is not IntPtr eye) return;
        // Read through UI Automation, not the copy fallback.
        if (!LogHas(logBefore, "eye", "readable", "true")) failures.Add("3-eye: the eye didn't read the selection through UI Automation");
        GetWindowRect(eye, out var r);
        double cx = (r.Left + r.Right) / 2.0, cy = (r.Top + r.Bottom) / 2.0;
        MoveTo(cx, cy);
        Thread.Sleep(600);
        Shot("3-eye-hover");
        // The middle button leaves it, as on the Mac.
        MoveTo(word.Left - 40, y);
        SendInput(2, new[] { Mouse(MOUSEEVENTF_MIDDLEDOWN), Mouse(MOUSEEVENTF_MIDDLEUP) }, Marshal.SizeOf<INPUT>());
        Thread.Sleep(400);
        if (Eye() == IntPtr.Zero) failures.Add("3-eye: a middle click hid the eye (the Mac's doesn't)");
        var before = Lines();
        Click(cx, cy);
        Burst("3-eye-reveal", 1500);
        // The eye never takes the focus: Notepad keeps it, and its selection.
        if (GetForegroundWindow() != notepad) failures.Add("3-eye: clicking the eye took the focus from Notepad");
        var started = DateTime.Now;
        JsonObject? card = null;
        while ((DateTime.Now - started).TotalSeconds < 60 && (card = LastCard(before)) == null) Thread.Sleep(300);
        Thread.Sleep(800);
        Shot("3-eye-card");
        if (card == null) failures.Add("3-eye: clicking the eye opened no card");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);

        Drag(word.Left - word.Width, y, (int)(word.Width * 2), 0);
        var dragged = WaitForEye(true, 2500);
        Shot("3-eye-drag");
        if (dragged == IntPtr.Zero) failures.Add("3-eye: no eye after dragging over Chinese text");
        Keys(VK_RIGHT);
        if (WaitForEye(false, 1500) != IntPtr.Zero) failures.Add("3-eye: a key press didn't hide the eye");

        // Right-click: the system's menu at the pointer; Esc closes it and the eye.
        if (Placement("3-eye-menu-place", notepad, () => DoubleClick(x, y), new[] { word }, word.Height) is IntPtr forMenu)
        {
            GetWindowRect(forMenu, out r);
            MoveTo((r.Left + r.Right) / 2.0, (r.Top + r.Bottom) / 2.0);
            Thread.Sleep(200);
            SendInput(2, new[] { Mouse(MOUSEEVENTF_RIGHTDOWN), Mouse(MOUSEEVENTF_RIGHTUP) }, Marshal.SizeOf<INPUT>());
            Thread.Sleep(700);
            Shot("3-eye-menu");
            var menu = FindWindow("#32768", null);
            Console.WriteLine($"[3-eye-menu] menu window: {(menu != IntPtr.Zero && IsWindowVisible(menu) ? "showing" : "none")}");
            if (menu == IntPtr.Zero || !IsWindowVisible(menu)) failures.Add("3-eye: right-clicking the eye showed no menu");
            Keys(VK_ESCAPE);
            Thread.Sleep(600);
            if (FindWindow("#32768", null) is var still && still != IntPtr.Zero && IsWindowVisible(still)) failures.Add("3-eye: Esc didn't close the eye's menu");
            if (Eye() != IntPtr.Zero) failures.Add("3-eye: the eye stayed after its menu closed");
        }

        // Gone by itself after 6 s, as on the Mac, even with the pointer on it.
        if (Placement("3-eye-again", notepad, () => DoubleClick(x, y), new[] { word }, word.Height) is IntPtr again)
        {
            GetWindowRect(again, out r);
            MoveTo((r.Left + r.Right) / 2.0, (r.Top + r.Bottom) / 2.0);
            Thread.Sleep(6200);
            if (Eye() != IntPtr.Zero) failures.Add("3-eye: still there 6 s after it appeared");
        }
    }

    /// The eye at each scaling the screen offers (100% to 200% when it can), in a Notepad of its
    /// own and in a rich edit box with a page margin (as Notepad on Windows 11 has): a word on
    /// the first line, one on the second, a right-to-left drag, two lines, three lines, and at
    /// 100% a word against the screen's right edge. A sheet per scaling shows each beside the
    /// Mac's rule (eye-sheet-*.png).
    static void EyeScalings(Process app)
    {
        var file = Path.Combine(Path.GetTempPath(), "longyan-eye.txt");
        File.WriteAllText(file, "他得了感冒，吃不了饭。\r\n明朝实行海禁，闭关锁国。\r\n我们研究研究再说吧。\r\n他找到了一个铁饭碗。\r\n", new UTF8Encoding(true));
        var (offered, now) = Scaling.Read();
        Console.WriteLine($"[eye-scale] scalings offered: {string.Join(", ", offered)}; now {now}%; screen {Screen()}");
        if (!offered.Contains(200))
        {
            Scaling.Largest();
            (offered, now) = Scaling.Read();
            Console.WriteLine($"[eye-scale] after the largest resolution: {string.Join(", ", offered)}; now {now}%; screen {Screen()}");
        }
        var notepad = Process.Start("notepad.exe", file)!;
        var window = WaitForWindow("longyan-eye", TimeSpan.FromSeconds(20));
        if (window == IntPtr.Zero) { failures.Add("eye-scale: Notepad didn't open"); return; }
        Console.WriteLine($"[eye-scale] Notepad's text box: {DocumentClass(window)}");
        var modern = ModernNotepad(file);
        var tested = new List<int>();
        foreach (var percent in new[] { 100, 125, 150, 175, 200 })
        {
            if (!offered.Contains(percent)) continue;
            if (percent != now && !Scaling.SetTo(percent)) { Console.WriteLine($"[eye-scale] couldn't set {percent}%"); continue; }
            now = percent;
            Thread.Sleep(3000);
            tested.Add(percent);
            var s = percent / 100.0;
            var cases = new List<(string Name, Bitmap Crop)>();
            SetWindowPos(window, IntPtr.Zero, (int)(40 * s), (int)(30 * s), (int)(560 * s), (int)(240 * s), 0x4);
            Thread.Sleep(600);
            Focus(window);
            Cases($"eye-{percent}-notepad", window, s, cases, edge: percent == 100);
            SetWindowPos(window, IntPtr.Zero, (int)(40 * s), (int)(30 * s), (int)(560 * s), (int)(240 * s), 0x4);
            const string text = "他得了感冒，吃不了饭。\r\n明朝实行海禁，闭关锁国。\r\n我们研究研究再说吧。\r\n他找到了一个铁饭碗。";
            // A page margin as the view's inset, then as space before the first paragraph, which
            // the box's first line may count (Notepad on Windows 11 counts its margin so).
            foreach (var spaced in new[] { false, true })
            {
                using var host = new RichEditHost(text, (int)(40 * s), (int)(300 * s), (int)(560 * s), (int)(220 * s), (int)(16 * s), spaced);
                Thread.Sleep(800);
                var kind = spaced ? "richedit-spaced" : "richedit";
                Console.WriteLine($"[eye-scale] {kind} at {percent}%: {DocumentClass(host.Window)}");
                Focus(host.Window);
                Cases($"eye-{percent}-{kind}", host.Window, s, cases, edge: false);
            }
            if (modern != IntPtr.Zero)
            {
                SetWindowPos(modern, IntPtr.Zero, (int)(620 * s), (int)(30 * s), (int)(560 * s), (int)(300 * s), 0x4);
                Thread.Sleep(800);
                Focus(modern);
                Cases($"eye-{percent}-notepad11", modern, s, cases, edge: false);
            }
            Sheet($"eye-sheet-{percent}", cases);
        }
        if (modern != IntPtr.Zero) PostMessage(modern, 0x10 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero);
        if (tested.Count < 2) failures.Add($"eye-scale: only {string.Join(", ", tested)}% could be tested");
        if (now != 100) Scaling.SetTo(100);
        Thread.Sleep(2000);
        try { notepad.Kill(); } catch { }
    }

    /// Notepad as Windows 11 has it (a Store app on its rich edit box), installed with winget
    /// when the runner allows; zero when it can't be had.
    static IntPtr ModernNotepad(string file)
    {
        try
        {
            var copy = Path.Combine(Path.GetTempPath(), "longyan-eye-11.txt");
            File.Copy(file, copy, true);
            var winget = new ProcessStartInfo("winget", "install --id 9MSMLRH6LZF3 --source msstore --accept-source-agreements --accept-package-agreements --disable-interactivity")
            { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var p = Process.Start(winget)!)
            {
                var output = p.StandardOutput.ReadToEndAsync();
                if (!p.WaitForExit(240000)) { try { p.Kill(); } catch { } }
                var lines = (output.Wait(5000) ? output.Result : "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 2 && !l.All(c => c is '-' or '\\' or '|' or '/' or ' ' or '█' or '▒')).TakeLast(4);
                Console.WriteLine($"[eye-scale] winget for Notepad: exit {(p.HasExited ? p.ExitCode : -1)}; {string.Join(" / ", lines)}");
            }
            var alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "Microsoft.WindowsNotepad_8wekyb3d8bbwe", "notepad.exe");
            if (!File.Exists(alias)) { Console.WriteLine("[eye-scale] Notepad for Windows 11: not available"); return IntPtr.Zero; }
            Process.Start(new ProcessStartInfo(alias, $"\"{copy}\"") { UseShellExecute = true });
            var window = WaitForWindow("longyan-eye-11", TimeSpan.FromSeconds(30));
            Console.WriteLine($"[eye-scale] Notepad for Windows 11: {(window == IntPtr.Zero ? "didn't open" : DocumentClass(window))}");
            return window;
        }
        catch (Exception e) { Console.WriteLine($"[eye-scale] Notepad for Windows 11: {e.Message}"); return IntPtr.Zero; }
    }

    static void Cases(string name, IntPtr window, double s, List<(string, Bitmap)> crops, bool edge)
    {
        void Add(string label, IntPtr? eye) { if (lastCrop != null) crops.Add(($"{name} {label}", lastCrop)); lastCrop = null; }
        string[] lines = { "他得了感冒，吃不了饭。", "明朝实行海禁，闭关锁国。", "我们研究研究再说吧。" };
        var r1 = TextIn(window, lines[0]); var r2 = TextIn(window, lines[1]); var r3 = TextIn(window, lines[2]);
        if (r1 is not System.Windows.Rect l1 || r2 is not System.Windows.Rect l2 || r3 is not System.Windows.Rect l3) { failures.Add($"{name}: couldn't find the lines"); return; }
        var ch1 = l1.Width / lines[0].Length; var ch2 = l2.Width / lines[1].Length; var ch3 = l3.Width / lines[2].Length;
        double Mid(System.Windows.Rect r) => r.Top + r.Height / 2;
        // The UI Automation box of the first line may hold the page margin: the pointer goes on its
        // text, at the bottom line's height.
        double y1 = l1.Bottom - l2.Height / 2, y2 = Mid(l2), y3 = Mid(l3);
        Add("first line, double-click 冒", Placement($"{name}-line1", window, () => DoubleClick(l1.Left + ch1 * 4.5, y1), new[] { l1 }, l2.Height));
        Add("second line, double-click 海", Placement($"{name}-line2", window, () => DoubleClick(l2.Left + ch2 * 4.5, y2), new[] { l2 }, l2.Height));
        Add("right-to-left drag 闭关锁国", Placement($"{name}-rtl", window, () => Drag(l2.Left + ch2 * 10.9, y2, -(int)(ch2 * 3.7), 0), new[] { l2 }, l2.Height));
        Add("two lines", Placement($"{name}-two", window, () => Drag(l1.Left + ch1 * 3.2, y1, (int)(ch2 * 1.5), (int)(y2 - y1)), new[] { l1, l2 }, l2.Height));
        Add("three lines", Placement($"{name}-three", window, () => Drag(l1.Left + ch1 * 3.2, y1, (int)(ch3 * 1.5), (int)(y3 - y1)), new[] { l1, l2, l3 }, l2.Height));
        if (edge)
        {
            // The first line's end a few points from the working area's right edge.
            GetWindowRect(window, out var w);
            var area = WorkArea(new Point(w.Left + 10, w.Top + 10));
            var dx = (int)(area.Right - 6 * s - l1.Right);
            SetWindowPos(window, IntPtr.Zero, w.Left + dx, w.Top, w.Right - w.Left, w.Bottom - w.Top, 0x4);
            Thread.Sleep(600);
            if (TextIn(window, lines[0]) is System.Windows.Rect e1)
                Add("at the screen's edge, double-click 饭", Placement($"{name}-edge", window, () => DoubleClick(e1.Left + ch1 * 9.5, e1.Bottom - l2.Height / 2), new[] { e1 }, l2.Height));
        }
    }

    static Bitmap? lastCrop;

    /// Makes a selection, waits for the eye, and checks it against the Mac's rule. `lines` are
    /// the text lines it covers (their ink, captured before, gives the text's centre). Returns
    /// the eye's window, or null when none came.
    static IntPtr? Placement(string name, IntPtr window, Action select, System.Windows.Rect[] lines, double lineHeight, string? burst = null)
    {
        // The caret out of the way (at the end), so it isn't taken for ink.
        Keys(VK_CONTROL, VK_END);
        WaitForEye(false, 1000);
        Thread.Sleep(300);
        using var before = Capture();
        var skip = Lines();
        select();
        if (burst != null) Burst(burst, 700);
        var eye = WaitForEye(true, 2500);
        GetCursorPos(out var up);
        if (eye == IntPtr.Zero) { Shot(name); failures.Add($"{name}: no eye"); return null; }
        Thread.Sleep(700);   // the spring in settles
        using var after = Capture();
        after.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
        GetWindowRect(eye, out var r);
        var s = ScaleOf(eye);
        var rects = SelectionRects(window);
        var logged = Last(skip, "eye");
        if (rects.Length == 0) { failures.Add($"{name}: no selection to measure"); return eye; }
        var union = rects[0];
        foreach (var x in rects.Skip(1)) union.Union(x);

        // The text's ink, before it was selected, in the selection's columns.
        int top = int.MaxValue, bottom = int.MinValue;
        foreach (var line in lines)
        {
            var cols = rects.Where(x => x.Top < line.Bottom && x.Bottom > line.Top).ToArray();
            if (cols.Length == 0) continue;
            var ink = Ink(before, (int)cols.Min(c => c.Left), (int)cols.Max(c => c.Right), (int)line.Top, (int)Math.Ceiling(line.Bottom));
            if (ink is (int t, int b)) { top = Math.Min(top, t); bottom = Math.Max(bottom, b); }
        }
        if (top == int.MaxValue) { failures.Add($"{name}: no ink found for the selected text"); return eye; }
        var textMid = (top + bottom + 1) / 2.0;
        var beside = lineHeight * lines.Length < 40 * s;
        double predX, predY;   // the 30-point button's centre
        if (beside) { predX = union.Right + 4 * s + 15 * s; predY = textMid; }
        else { predX = up.X + 6 * s + 15 * s; predY = up.Y - 6 * s - 15 * s; }
        var area = WorkArea(up);
        predX = Math.Clamp(predX - 22 * s, area.Left, area.Right - 44 * s) + 22 * s;
        predY = Math.Clamp(predY - 22 * s, area.Top, area.Bottom - 44 * s) + 22 * s;
        double cx = (r.Left + r.Right) / 2.0, cy = (r.Top + r.Bottom) / 2.0;
        var button = EyeButton(eye);
        Console.WriteLine($"[{name}] scale {s:0.##}; {(beside ? "beside" : "by the pointer")}; selection {Fmt(union)} in {rects.Length} box(es); ink rows {top}..{bottom} (centre {textMid:0.#}, box centre {union.Top + union.Height / 2:0.#}); " +
            $"up {up.X},{up.Y}; eye window {r.Left},{r.Top} to {r.Right},{r.Bottom} (centre {cx:0.#},{cy:0.#}); button {Fmt(button)}; Mac rule centre {predX:0.#},{predY:0.#}; logged {logged?.ToJsonString() ?? "nothing"}");
        // Within 2 px of the text's centre, at every scaling (the user saw 17 off at 200%).
        var tolY = 2.0; var tolX = 1 + s / 2;
        if (Math.Abs(cy - predY) > tolY) failures.Add($"{name}: the eye's centre is at y {cy:0.#}, the Mac's rule puts it at {predY:0.#} ({(beside ? "the text's centre" : "6 above where the mouse let go")}); off by {cy - predY:0.#} px at {s * 100:0}%");
        if (Math.Abs(cx - predX) > tolX) failures.Add($"{name}: the eye's centre is at x {cx:0.#}, the Mac's rule puts it at {predX:0.#}; off by {cx - predX:0.#} px at {s * 100:0}%");
        if (button is System.Windows.Rect br && (Math.Abs(br.Left + br.Width / 2 - cx) > 1 || Math.Abs(br.Top + br.Height / 2 - cy) > 1)) failures.Add($"{name}: the button isn't in the middle of the eye's window ({Fmt(br)})");

        // Evidence: the selection and the eye, with the Mac rule's circle (red) and the text's
        // centre (green) drawn over.
        var pad = (int)(24 * s);
        var crop = Rectangle.FromLTRB((int)Math.Min(union.Left, r.Left) - pad, (int)Math.Min(union.Top, r.Top) - pad, (int)Math.Max(union.Right, r.Right) + pad, (int)Math.Max(union.Bottom, r.Bottom) + pad);
        crop.Intersect(new Rectangle(0, 0, after.Width, after.Height));
        var zoom = 2 / s;
        var img = new Bitmap((int)(crop.Width * zoom), (int)(crop.Height * zoom));
        using (var g = Graphics.FromImage(img))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(after, new Rectangle(0, 0, img.Width, img.Height), crop, GraphicsUnit.Pixel);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float X(double v) => (float)((v - crop.Left) * zoom);
            float Y(double v) => (float)((v - crop.Top) * zoom);
            using var green = new Pen(Color.FromArgb(160, 0, 160, 0), 1);
            g.DrawLine(green, 0, Y(textMid), img.Width, Y(textMid));
            using var red = new Pen(Color.FromArgb(200, 220, 0, 0), 1);
            g.DrawEllipse(red, X(predX - 12 * s), Y(predY - 12 * s), (float)(24 * s * zoom), (float)(24 * s * zoom));
        }
        lastCrop = img;
        return eye;
    }

    static string Fmt(System.Windows.Rect? r) => r is System.Windows.Rect x ? $"{x.Left:0.#},{x.Top:0.#} {x.Width:0.#}x{x.Height:0.#}" : "none";

    /// The rows from `y0` to `y1` that have ink between `x0` and `x1`: pixels well away from the
    /// line's background (its most common colour).
    static (int, int)? Ink(Bitmap shot, int x0, int x1, int y0, int y1)
    {
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0); x1 = Math.Min(shot.Width, x1); y1 = Math.Min(shot.Height, y1);
        var counts = new Dictionary<int, int>();
        for (var y = y0; y < y1; y++) for (var x = x0; x < x1; x++) { var c = shot.GetPixel(x, y).ToArgb(); counts[c] = counts.GetValueOrDefault(c) + 1; }
        if (counts.Count == 0) return null;
        var bg = Color.FromArgb(counts.MaxBy(kv => kv.Value).Key);
        int top = -1, bottom = -1;
        for (var y = y0; y < y1; y++)
        {
            var ink = 0;
            for (var x = x0; x < x1; x++)
            {
                var c = shot.GetPixel(x, y);
                if (Math.Abs(c.R - bg.R) + Math.Abs(c.G - bg.G) + Math.Abs(c.B - bg.B) > 150) ink++;
            }
            if (ink == 0) continue;
            if (top < 0) top = y;
            bottom = y;
        }
        return top < 0 ? null : (top, bottom);
    }

    static Rectangle PrimaryBounds() => new(0, 0, GetSystemMetrics(0), GetSystemMetrics(1));

    /// The working area of the screen `p` is on (Win32, as the app reads it: WinForms keeps the
    /// screens it saw first).
    static Rectangle WorkArea(Point p)
    {
        var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(MonitorFromPoint(p, 2), ref info);
        return Rectangle.FromLTRB(info.Work.Left, info.Work.Top, info.Work.Right, info.Work.Bottom);
    }

    static Bitmap Capture()
    {
        var b = PrimaryBounds();
        var bmp = new Bitmap(b.Width, b.Height);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        return bmp;
    }

    static string Screen() { var b = PrimaryBounds(); return $"{b.Width}x{b.Height}"; }

    /// One image per scaling: each case's crop under its name.
    static void Sheet(string name, List<(string Name, Bitmap Crop)> cases)
    {
        if (cases.Count == 0) return;
        var width = Math.Max(400, cases.Max(c => c.Crop.Width)) + 20;
        var height = cases.Sum(c => c.Crop.Height + 30) + 10;
        using var sheet = new Bitmap(width, height);
        using (var g = Graphics.FromImage(sheet))
        {
            g.Clear(Color.White);
            using var font = new Font("Segoe UI", 10, GraphicsUnit.Pixel);
            using var f = new Font("Segoe UI", 12);
            var y = 6;
            foreach (var (label, crop) in cases)
            {
                g.DrawString(label + "   (red: the Mac's rule, green: the text's centre)", f, Brushes.Black, 10, y);
                y += 22;
                g.DrawImage(crop, 10, y, crop.Width, crop.Height);
                y += crop.Height + 8;
                crop.Dispose();
            }
        }
        sheet.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
    }

    /// The selection's boxes in a window's text, as UI Automation reports them.
    static System.Windows.Rect[] SelectionRects(IntPtr hwnd)
    {
        try
        {
            foreach (AutomationElement e in AutomationElement.FromHandle(hwnd).FindAll(TreeScope.Subtree, Condition.TrueCondition))
            {
                if (!e.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern t) continue;
                var rects = t.GetSelection().FirstOrDefault()?.GetBoundingRectangles();
                if (rects is { Length: > 0 }) return rects;
            }
        }
        catch { }
        return Array.Empty<System.Windows.Rect>();
    }

    static string DocumentClass(IntPtr hwnd)
    {
        try
        {
            foreach (AutomationElement e in AutomationElement.FromHandle(hwnd).FindAll(TreeScope.Subtree, Condition.TrueCondition))
                if (e.TryGetCurrentPattern(TextPattern.Pattern, out _)) return e.Current.ClassName;
        }
        catch { }
        return "none";
    }

    /// The eye's "Look up" button, where UI Automation has it.
    static System.Windows.Rect? EyeButton(IntPtr eye)
    {
        try { return AutomationElement.FromHandle(eye).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ClassNameProperty, "LongyanEye"))?.Current.BoundingRectangle; }
        catch { return null; }
    }

    static double ScaleOf(IntPtr hwnd) { var dpi = GetDpiForWindow(hwnd); return dpi > 0 ? dpi / 96.0 : 1; }

    static int Lines() { try { return File.Exists(log) ? File.ReadAllLines(log).Length : 0; } catch { return 0; } }

    /// The newest `name` event after line `skip` of the log.
    static JsonObject? Last(int skip, string name)
    {
        if (!File.Exists(log)) return null;
        var lines = File.ReadAllLines(log);
        for (var i = lines.Length - 1; i >= skip; i--)
            if (JsonNode.Parse(lines[i]) is JsonObject e && (string?)e["event"] == name) return e;
        return null;
    }

    /// Waits up to `ms` for the eye to be showing (or gone): its window, or zero.
    static IntPtr WaitForEye(bool showing, int ms)
    {
        var end = DateTime.Now.AddMilliseconds(ms);
        IntPtr eye;
        while ((eye = Eye()) != IntPtr.Zero != showing && DateTime.Now < end) Thread.Sleep(50);
        return eye;
    }

    /// Whether an event after line `skip` of the log has `key` equal to `value`.
    static bool LogHas(int skip, string name, string key, string value)
    {
        if (!File.Exists(log)) return false;
        foreach (var line in File.ReadAllLines(log).Skip(skip))
            if (JsonNode.Parse(line) is JsonObject e && (string?)e["event"] == name && e[key]?.ToJsonString() == value) return true;
        return false;
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

    const uint MOUSEEVENTF_MIDDLEDOWN = 0x20, MOUSEEVENTF_MIDDLEUP = 0x40, MOUSEEVENTF_RIGHTDOWN = 8, MOUSEEVENTF_RIGHTUP = 0x10;
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string? cls, string? title);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point p);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
}

/// The screen's scaling, set as Settings > Display does, without signing out
/// (DisplayConfigSetDeviceInfo with the scale type Settings uses), and its resolution.
static class Scaling
{
    static readonly int[] steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    [StructLayout(LayoutKind.Sequential)] struct Header { public int Type, Size; public uint AdapterLow; public int AdapterHigh; public uint Id; }
    [StructLayout(LayoutKind.Sequential)] struct GetScale { public Header H; public int Min, Cur, Max; }
    [StructLayout(LayoutKind.Sequential)] struct SetScale { public Header H; public int Scale; }

    static Header Source(int type, int size)
    {
        GetDisplayConfigBufferSizes(2 /* QDC_ONLY_ACTIVE_PATHS */, out var np, out var nm);
        var paths = new byte[np * 72];
        var modes = new byte[nm * 64];
        QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero);
        return new Header { Type = type, Size = size, AdapterLow = BitConverter.ToUInt32(paths, 0), AdapterHigh = BitConverter.ToInt32(paths, 4), Id = BitConverter.ToUInt32(paths, 8) };
    }

    static GetScale? Get()
    {
        var g = new GetScale { H = Source(-3, Marshal.SizeOf<GetScale>()) };
        return DisplayConfigGetDeviceInfo(ref g) == 0 ? g : null;
    }

    /// The scalings offered (percent) and the current one.
    public static (int[] Offered, int Current) Read()
    {
        if (Get() is not GetScale g) return (new[] { 100 }, 100);
        var recommended = Math.Abs(g.Min);
        var offered = Enumerable.Range(g.Min, g.Max - g.Min + 1).Select(r => recommended + r).Where(i => i >= 0 && i < steps.Length).Select(i => steps[i]).ToArray();
        return (offered, steps[Math.Clamp(recommended + g.Cur, 0, steps.Length - 1)]);
    }

    public static bool SetTo(int percent)
    {
        if (Get() is not GetScale g) return false;
        var rel = Array.IndexOf(steps, percent) - Math.Abs(g.Min);
        if (rel < g.Min || rel > g.Max) return false;
        var set = new SetScale { H = Source(-4, Marshal.SizeOf<SetScale>()), Scale = rel };
        return DisplayConfigSetDeviceInfo(ref set) == 0;
    }

    /// Switches to the largest resolution the display offers, for the larger scalings.
    public static void Largest()
    {
        var best = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
        var all = new List<string>();
        for (var i = 0; ; i++)
        {
            var m = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
            if (!EnumDisplaySettings(null, i, ref m)) break;
            if (m.dmBitsPerPel < 32) continue;
            all.Add($"{m.dmPelsWidth}x{m.dmPelsHeight}");
            if ((long)m.dmPelsWidth * m.dmPelsHeight > (long)best.dmPelsWidth * best.dmPelsHeight) best = m;
        }
        Console.WriteLine($"[eye-scale] resolutions: {string.Join(" ", all.Distinct())}");
        if (best.dmPelsWidth == 0) return;
        best.dmFields = 0x80000 | 0x100000;   // DM_PELSWIDTH | DM_PELSHEIGHT
        var result = ChangeDisplaySettings(ref best, 0);
        Console.WriteLine($"[eye-scale] to {best.dmPelsWidth}x{best.dmPelsHeight}: {result}");
        Thread.Sleep(3000);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency, dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, byte[] pathInfo, ref uint modes, byte[] modeInfo, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref GetScale g);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SetScale s);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string? device, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
}

/// A window with the system's rich edit box (RICHEDIT50W, the control Notepad on Windows 11 is
/// built on) and a page margin around the text, on a thread of its own.
sealed class RichEditHost : IDisposable
{
    public IntPtr Window { get; private set; }
    readonly Thread thread;
    System.Windows.Forms.Form? form;

    public RichEditHost(string text, int x, int y, int w, int h, int margin, bool spaced)
    {
        using var ready = new ManualResetEventSlim();
        thread = new Thread(() =>
        {
            LoadLibrary("Msftedit.dll");
            form = new System.Windows.Forms.Form
            {
                Text = "longyan-richedit", StartPosition = System.Windows.Forms.FormStartPosition.Manual,
                Left = x, Top = y, Width = w, Height = h, ShowInTaskbar = false,
            };
            form.Load += (_, _) =>
            {
                var size = form.ClientSize;
                var edit = CreateWindowEx(0, "RICHEDIT50W", "", 0x40000000 | 0x10000000 | 0x4 /* WS_CHILD | WS_VISIBLE | ES_MULTILINE */, 0, 0, size.Width, size.Height, form.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                var font = new Font("Consolas", 11f * GetDpiForWindow(form.Handle) / 96f, GraphicsUnit.Point);
                SendMessage(edit, 0x30 /* WM_SETFONT */, font.ToHfont(), (IntPtr)1);
                SetWindowText(edit, text);
                var rc = new RECT { Left = margin, Top = spaced ? 0 : margin, Right = size.Width - margin, Bottom = size.Height - margin };
                SendMessage(edit, 0xB3 /* EM_SETRECT */, IntPtr.Zero, ref rc);
                if (spaced)
                {
                    // PARAFORMAT2 with dySpaceBefore (twips) for the first paragraph, where the caret is.
                    var pf = new byte[188];
                    BitConverter.GetBytes(188).CopyTo(pf, 0);
                    BitConverter.GetBytes(0x40 /* PFM_SPACEBEFORE */).CopyTo(pf, 4);
                    BitConverter.GetBytes(margin * 1440 / (int)GetDpiForWindow(form.Handle)).CopyTo(pf, 156);
                    SendMessage(edit, 0x447 /* EM_SETPARAFORMAT */, IntPtr.Zero, pf);
                }
                Window = form.Handle;
                ready.Set();
            };
            System.Windows.Forms.Application.Run(form);
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.Wait(10000);
    }

    public void Dispose()
    {
        try { form?.Invoke(() => form.Close()); } catch { }
        thread.Join(3000);
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowText(IntPtr h, string text);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, ref RECT l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, byte[] l);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
}
