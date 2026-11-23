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
        var placed = Placement(name, notepad, () => DoubleClick(word.Left + word.Width / 2, word.Top + word.Height / 2), new[] { word }, word.Height, early: true);
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
            if (Eye() != IntPtr.Zero)
            {
                var events = File.Exists(log) ? File.ReadAllLines(log).Where(l => l.Contains("\"eye")).TakeLast(6) : Enumerable.Empty<string>();
                Console.WriteLine($"[3-eye-again] still there; last eye events: {string.Join(" ", events)}");
                failures.Add("3-eye: still there 6 s after it appeared");
            }
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
        var browser = Edge();
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
            if (browser != IntPtr.Zero)
            {
                SetWindowPos(browser, IntPtr.Zero, (int)(40 * s), (int)(30 * s), (int)(900 * s), (int)(560 * s), 0x4);
                Thread.Sleep(1500);
                Focus(browser);
                EdgeCases($"eye-{percent}-edge", browser, s, cases);
                EdgeDrags($"eye-{percent}-edge", browser, s, cases);
            }
            if (modern != IntPtr.Zero)
            {
                // Above Edge, which covers its left part at 175% (a click meant for it went to Edge).
                SetWindowPos(modern, IntPtr.Zero /* HWND_TOP */, (int)(620 * s), (int)(30 * s), (int)(560 * s), (int)(300 * s), 0);
                Thread.Sleep(800);
                Focus(modern);
                Cases($"eye-{percent}-notepad11", modern, s, cases, edge: false);
            }
            Sheet($"eye-sheet-{percent}", cases);
        }
        foreach (var p in Process.GetProcessesByName("msedge")) try { p.Kill(); } catch { }
        if (modern != IntPtr.Zero) PostMessage(modern, 0x10 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero);
        if (tested.Count < 2) failures.Add($"eye-scale: only {string.Join(", ", tested)}% could be tested");
        if (ownTimes.Count > 0)
        {
            var sorted = ownTimes.OrderBy(x => x).ToList();
            int median = sorted[sorted.Count / 2], p90 = sorted[(int)(sorted.Count * 0.9)];
            Console.WriteLine($"[eye-scale] the app's own time from mouse-up to the eye (less the 0.12 s wait and the selection's read), {sorted.Count} eyes: median {median} ms, 90th {p90} ms, most {sorted[^1]} ms");
            if (median > 100 || p90 > 150) failures.Add($"eye-scale: the app takes {median} ms (median), {p90} ms (90th) of its own to show the eye");
        }
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

    /// Edge on a page with Chinese at 13, 16 and 20 px, one word followed by a space (Chromium's
    /// double-click on Windows takes the space too).
    static IntPtr Edge()
    {
        var exe = new[] { @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", @"C:\Program Files\Microsoft\Edge\Application\msedge.exe" }.FirstOrDefault(File.Exists);
        if (exe == null) { Console.WriteLine("[eye-scale] Edge: not installed"); return IntPtr.Zero; }
        var page = Path.Combine(Path.GetTempPath(), "longyan-edge.html");
        File.WriteAllText(page, """
            <!doctype html><meta charset="utf-8"><title>longyan-edge</title>
            <body style="margin:24px;background:#fff;color:#000;font-family:'Microsoft YaHei',sans-serif">
            <h1 style="font-size:32px">明朝实行海禁，闭关锁国。</h1>
            <p style="font-size:13px">他得了感冒，吃不了饭。</p>
            <p style="font-size:16px">明朝实行海禁 policy，闭关锁国。</p>
            <p style="font-size:20px">我们研究研究再说吧。</p>
            <p style="font-size:16px">铁饭碗 at last.</p>
            """, new UTF8Encoding(false));
        var profile = Path.Combine(Path.GetTempPath(), "longyan-edge-profile");
        Process.Start(new ProcessStartInfo(exe, $"--no-first-run --no-default-browser-check --user-data-dir=\"{profile}\" --new-window \"{page}\"") { UseShellExecute = false });
        var window = WaitForWindow("longyan-edge", TimeSpan.FromSeconds(40));
        Console.WriteLine($"[eye-scale] Edge: {(window == IntPtr.Zero ? "didn't open" : "open")}");
        return window;
    }

    static void EdgeCases(string name, IntPtr window, double s, List<(string, Bitmap)> crops)
    {
        // Where each line is comes from its text element: Chromium's FindText is off by a
        // character for each paragraph before the match. The characters are 1 em wide.
        foreach (var (label, line, index, px) in new[] { ("13px", "他得了感冒，吃不了饭。", 4, 13), ("16px, a space after", "明朝实行海禁 policy，闭关锁国。", 5, 16), ("20px", "我们研究研究再说吧。", 6, 20), ("16px, a space after, line start", "铁饭碗 at last.", 2, 16) })
        {
            var tag = $"{name}-{px}px{(label.Contains("line start") ? "-start" : label.Contains("space") ? "-space" : "")}";
            System.Windows.Rect? found = null;
            for (var i = 0; i < 20 && found == null; i++)
            {
                try { found = AutomationElement.FromHandle(window).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, line))?.Current.BoundingRectangle; } catch { }
                if (found == null) Thread.Sleep(500);
            }
            if (found is not System.Windows.Rect l || l.IsEmpty) { failures.Add($"{tag}: couldn't find the text in Edge"); continue; }
            var x = l.Left + (index + 0.5) * px * s;
            var eye = Placement(tag, window, () => DoubleClick(x, l.Top + l.Height / 2), new[] { l }, l.Height, exact: true, clear: Deselect(l, s));
            if (lastCrop != null) { crops.Add(($"{name} {label}, double-click {line[index]}", lastCrop)); lastCrop = null; }
            // Edge's own menu for a selection, if it came: its windows besides the page's.
            foreach (var (h, r) in EdgePopups(window)) Console.WriteLine($"[{tag}] Edge popup {h:X}: {r.Left},{r.Top} to {r.Right},{r.Bottom}");
            // The same once the eye has gone by itself, for drawing where else it could go.
            if (eye != null)
            {
                Thread.Sleep(6000);
                Shot(tag + "-no-eye");
                foreach (var (h, r) in EdgePopups(window)) Console.WriteLine($"[{tag}] after the eye: Edge popup {h:X}: {r.Left},{r.Top} to {r.Right},{r.Bottom}");
            }
        }
    }

    /// Drags in Edge whose eye the Mac puts beside the text: a 32 px heading (its line is over
    /// 40 points in Microsoft YaHei), ending on the line, below it, and past its text; and a
    /// paragraph dragged past its end. Within 1 point of the Mac rule's centre.
    /// A click in the page's left margin beside `line`: the last selection goes.
    static Action Deselect(System.Windows.Rect line, double s) => () =>
    {
        Click(line.Left - 12 * s, line.Top + line.Height / 2);
        Thread.Sleep(300);
    };

    static void EdgeDrags(string name, IntPtr window, double s, List<(string, Bitmap)> crops)
    {
        System.Windows.Rect? Find(string line)
        {
            for (var i = 0; i < 20; i++)
            {
                try { if (AutomationElement.FromHandle(window).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, line))?.Current.BoundingRectangle is System.Windows.Rect r && !r.IsEmpty) return r; } catch { }
                Thread.Sleep(500);
            }
            return null;
        }
        void Add(string label) { if (lastCrop != null) crops.Add(($"{name} {label}", lastCrop)); lastCrop = null; }
        const string heading = "明朝实行海禁，闭关锁国。";
        if (Find(heading) is not System.Windows.Rect h) { failures.Add($"{name}-h1: couldn't find the heading in Edge"); return; }
        var em = 32 * s; var y = h.Top + h.Height / 2;
        var from = h.Left + 3 * em + 2 * s;   // 行
        Console.WriteLine($"[{name}-h1] heading's box {Fmt(h)}");
        Placement($"{name}-h1-on", window, () => Drag(from, y, (int)(h.Left + 11 * em + 2 * s - from), 0), new[] { h }, h.Height, oneLine: true, tolerance: 1, exact: true, clear: Deselect(h, s));
        Add("32 px heading, 行 to just past 国");
        Placement($"{name}-h1-below", window, () => Drag(from, y, (int)(h.Left + 9.9 * em - from), (int)(h.Bottom - 2 * s - y)), new[] { h }, h.Height, oneLine: true, tolerance: 1, exact: true, clear: Deselect(h, s));
        Add("32 px heading, 行 to 锁, let go below the text");
        Placement($"{name}-h1-past", window, () => Drag(from, y, (int)(h.Left + 12 * em + 90 * s - from), 0), new[] { h }, h.Height, oneLine: true, tolerance: 1, exact: true, clear: Deselect(h, s));
        Add("32 px heading, 行 to 90 points past the text");
        const string para = "我们研究研究再说吧。";
        if (Find(para) is not System.Windows.Rect p) { failures.Add($"{name}-past: couldn't find the 20 px line in Edge"); return; }
        var start = p.Left + 2 * 20 * s + 2 * s;   // 研
        Placement($"{name}-20px-past", window, () => Drag(start, p.Top + p.Height / 2, (int)(p.Left + 10 * 20 * s + 90 * s - start), 0), new[] { p }, p.Height, tolerance: 1, exact: true, clear: Deselect(p, s));
        Add("20 px line, 研 to 90 points past the end");
    }

    static List<(IntPtr, RECT)> EdgePopups(IntPtr main)
    {
        var found = new List<(IntPtr, RECT)>();
        var ids = Process.GetProcessesByName("msedge").Select(p => (uint)p.Id).ToHashSet();
        EnumWindows((h, _) =>
        {
            if (h != main && IsWindowVisible(h) && GetWindowThreadProcessId(h, out var pid) != 0 && ids.Contains(pid) && GetWindowRect(h, out var r) && r.Right - r.Left < 800 && r.Bottom - r.Top < 800 && r.Right > r.Left)
                found.Add((h, r));
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static void Cases(string name, IntPtr window, double s, List<(string, Bitmap)> crops, bool edge)
    {
        void Add(string label, IntPtr? eye) { if (lastCrop != null) crops.Add(($"{name} {label}", lastCrop)); lastCrop = null; }
        string[] lines = { "他得了感冒，吃不了饭。", "明朝实行海禁，闭关锁国。", "我们研究研究再说吧。" };
        var r1 = TextIn(window, lines[0]); var r2 = TextIn(window, lines[1]); var r3 = TextIn(window, lines[2]);
        if (r1 is not System.Windows.Rect l1 || r2 is not System.Windows.Rect l2 || r3 is not System.Windows.Rect l3) { failures.Add($"{name}: couldn't find the lines"); return; }
        double Mid(System.Windows.Rect r) => r.Top + r.Height / 2;
        // The UI Automation box of the first line may hold the page margin: the pointer goes on its
        // text, at the second line's height from the bottom.
        double y1 = l1.Bottom - l2.Height / 2, y2 = Mid(l2), y3 = Mid(l3);
        System.Windows.Rect At(string c) => TextIn(window, c) ?? System.Windows.Rect.Empty;
        var mao = At("冒"); var hai = At("海"); var bi = At("闭"); var guo = At("国"); var gan = At("感"); var shi = At("实"); var jiu = At("究");
        if (new[] { mao, hai, bi, guo, gan, shi, jiu }.Any(r => r.IsEmpty)) { failures.Add($"{name}: couldn't find the characters"); return; }
        Add("first line, double-click 冒", Placement($"{name}-line1", window, () => DoubleClick(mao.Left + mao.Width / 2, y1), new[] { l1 }, l2.Height, exact: true));
        Add("second line, double-click 海", Placement($"{name}-line2", window, () => DoubleClick(hai.Left + hai.Width / 2, y2), new[] { l2 }, l2.Height, exact: true));
        Add("right-to-left drag 国 to 闭", Placement($"{name}-rtl", window, () => Drag(guo.Right - 2, y2, (int)(bi.Left + 2 - (guo.Right - 2)), 0), new[] { l2 }, l2.Height, exact: true));
        Add("two lines, 感 to 实", Placement($"{name}-two", window, () => Drag(gan.Left + 2, y1, (int)(shi.Right - 2 - (gan.Left + 2)), (int)(y2 - y1)), new[] { l1, l2 }, l2.Height, exact: true));
        Add("three lines, 感 to 究", Placement($"{name}-three", window, () => Drag(gan.Left + 2, y1, (int)(jiu.Right - 2 - (gan.Left + 2)), (int)(y3 - y1)), new[] { l1, l2, l3 }, l2.Height));
        // A drag from inside a line to well past its end (90 points right, same line): the Mac
        // puts the eye after the line's text.
        var yan = At("研");
        Add("first line, 感 to past the end", Placement($"{name}-past1", window, () => Drag(gan.Left + 2, y1, (int)(l1.Right + 90 * s - (gan.Left + 2)), 0), new[] { l1 }, l2.Height, exact: true));
        Add("second line, 闭 to past the end", Placement($"{name}-past2", window, () => Drag(bi.Left + 2, y2, (int)(l2.Right + 90 * s - (bi.Left + 2)), 0), new[] { l2 }, l2.Height, exact: true));
        if (!yan.IsEmpty) Add("third line, 研 to past the end", Placement($"{name}-past3", window, () => Drag(yan.Left + 2, y3, (int)(l3.Right + 90 * s - (yan.Left + 2)), 0), new[] { l3 }, l2.Height, exact: true));
        if (edge)
        {
            // The first line's end a few points from the working area's right edge.
            GetWindowRect(window, out var w);
            var area = WorkArea(new Point(w.Left + 10, w.Top + 10));
            var dx = (int)(area.Right - 6 * s - l1.Right);
            SetWindowPos(window, IntPtr.Zero, w.Left + dx, w.Top, w.Right - w.Left, w.Bottom - w.Top, 0x4);
            Thread.Sleep(600);
            if (TextIn(window, lines[0]) is System.Windows.Rect e1 && TextIn(window, "饭") is System.Windows.Rect fan)
                Add("at the screen's edge, double-click 饭", Placement($"{name}-edge", window, () => DoubleClick(fan.Left + fan.Width / 2, e1.Bottom - l2.Height / 2), new[] { e1 }, l2.Height, exact: true));
        }
    }

    static Bitmap? lastCrop;
    static readonly List<int> ownTimes = new();

    /// Makes a selection, waits for the eye, and checks it against the Mac's rule. `lines` are
    /// the text lines it covers (their ink, captured before, gives the text's centre). Returns
    /// the eye's window, or null when none came.
    /// `oneLine`: the selection is on one line, so the eye goes beside it whatever its height.
    /// `tolerance`: how far from the Mac rule's centre, in points (default 2 px down, 1 + s/2
    /// across). `early`: also a frame about 30 ms after the eye's window shows, whose circle
    /// must already be centred where it settles.
    static IntPtr? Placement(string name, IntPtr window, Action select, System.Windows.Rect[] lines, double lineHeight, string? burst = null, bool oneLine = false, double? tolerance = null, bool early = false, bool exact = false, Action? clear = null)
    {
        // The caret out of the way (at the end), so it isn't taken for ink; and in a page, the
        // last selection gone (Ctrl+End keeps it there), so its highlight isn't either.
        Keys(VK_CONTROL, VK_END);
        clear?.Invoke();
        WaitForEye(false, 1000);
        Thread.Sleep(300);
        using var before = Capture();
        var skip = Lines();
        select();
        // The highlight as it is when the app reads it (0.12 s after the mouse lets go), before
        // the eye comes: a rich edit box redraws it a few pixels shorter later on.
        if (burst != null) Burst(burst, 700);
        Bitmap? first = null; RECT firstRect = default; double firstMs = 0;
        if (early)
        {
            var clock = Stopwatch.StartNew();
            IntPtr seen;
            while ((seen = Eye()) == IntPtr.Zero && clock.ElapsedMilliseconds < 2500) Thread.Sleep(1);
            if (seen != IntPtr.Zero)
            {
                var at = clock.Elapsed.TotalMilliseconds;
                while (clock.Elapsed.TotalMilliseconds < at + 30) Thread.Sleep(1);
                GetWindowRect(seen, out firstRect);
                first = Capture();
                firstMs = clock.Elapsed.TotalMilliseconds - at;
            }
        }
        var eye = WaitForEye(true, 2500);
        GetCursorPos(out var up);
        if (eye == IntPtr.Zero)
        {
            Shot(name);
            var why = string.Join("; ", new[] { "eye-probe", "eye-skip", "eye-error" }.Select(e => Last(skip, e)?.ToJsonString()).Where(x => x != null));
            Console.WriteLine($"[{name}] no eye; selection {Fmt(SelectionRects(window) is { Length: > 0 } sr ? sr.Aggregate((a, b) => System.Windows.Rect.Union(a, b)) : null)}; logged {(why.Length > 0 ? why : "nothing")}; {NotepadState(window)}");
            failures.Add($"{name}: no eye ({(why.Length > 0 ? why : "nothing logged")})");
            first?.Dispose();
            return null;
        }
        Thread.Sleep(700);   // the spring in settles
        using var after = Capture();
        after.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
        GetWindowRect(eye, out var r);
        var s = ScaleOf(eye);
        var rects = SelectionRects(window);
        var trimmedRight = TrimmedRight(window);
        var logged = Last(skip, "eye");
        // Shown 0.12 s after the mouse let go, plus reading the selection (the Mac's 0.12 s, then
        // its Accessibility read): the screen read must not hold it up.
        // The app's own part: all but the 0.12 s wait and the app's answer to UI Automation (the
        // Mac waits on Accessibility the same way, up to 0.5 s).
        var probeMs = Last(skip, "eye-probe")?["ms"] is JsonNode pm ? (int)pm : 0;
        // A shared runner stalls now and then: one slow case is logged, a slow middle fails
        // (EyeScalings).
        if (burst == null && logged?["ms"] is JsonNode msNode)
        {
            var own = (int)msNode - probeMs - 120;
            ownTimes.Add(own);
            if (own > 150) Console.WriteLine($"[{name}] slow: the eye came {(int)msNode} ms after the mouse let go, {own} ms of it the app's own (reading the screen {logged["drawnMs"]} ms; the selection {probeMs} ms)");
        }
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
        if (top == int.MaxValue)
        {
            Console.WriteLine($"[{name}] no ink: lines {string.Join(" ", lines.Select(x => Fmt(x)))}; selection boxes {string.Join(" ", rects.Select(x => Fmt(x)))}; eye {r.Left},{r.Top} to {r.Right},{r.Bottom}");
            failures.Add($"{name}: no ink found for the selected text");
            return eye;
        }
        var textMid = (top + bottom + 1) / 2.0;
        var beside = oneLine || lineHeight * lines.Length < 40 * s;
        double predX, predY;   // the 30-point button's centre
        // The selected text's right edge, white space after it left out (the Mac's double-click
        // takes none).
        // Across, from the highlight's right edge as the app read it off the screen (the `exact`
        // cases check that edge against the screen themselves).
        var drawnRight = logged?["drawn"] is JsonArray da && da.Count == 2 && da[0] is JsonNode dr ? (double?)dr : null;
        if (beside) { predX = (drawnRight ?? trimmedRight ?? union.Right) + 4 * s + 15 * s; predY = textMid; }
        else { predX = up.X + 6 * s + 15 * s; predY = up.Y - 6 * s - 15 * s; }
        var area = WorkArea(up);
        predX = Math.Clamp(predX - 22 * s, area.Left, area.Right - 44 * s) + 22 * s;
        predY = Math.Clamp(predY - 22 * s, area.Top, area.Bottom - 44 * s) + 22 * s;
        double cx = (r.Left + r.Right) / 2.0, cy = (r.Top + r.Bottom) / 2.0;
        var button = EyeButton(eye);
        Console.WriteLine($"[{name}] scale {s:0.##}; {(beside ? "beside" : "by the pointer")}; selection {Fmt(union)} in {rects.Length} box(es); ink rows {top}..{bottom} (centre {textMid:0.#}, box centre {union.Top + union.Height / 2:0.#}); " +
            $"up {up.X},{up.Y}; eye window {r.Left},{r.Top} to {r.Right},{r.Bottom} (centre {cx:0.#},{cy:0.#}); button {Fmt(button)}; Mac rule centre {predX:0.#},{predY:0.#}; logged {logged?.ToJsonString() ?? "nothing"}");
        // Within 2 px of the text's centre, at every scaling (the user saw 17 off at 200%).
        var tolY = tolerance is double t1 ? t1 * s : 2.0; var tolX = tolerance is double t2 ? t2 * s : 1 + s / 2;
        if (Math.Abs(cy - predY) > tolY) failures.Add($"{name}: the eye's centre is at y {cy:0.#}, the Mac's rule puts it at {predY:0.#} ({(beside ? "the text's centre" : "6 above where the mouse let go")}); off by {cy - predY:0.#} px at {s * 100:0}%");
        if (Math.Abs(cx - predX) > tolX) failures.Add($"{name}: the eye's centre is at x {cx:0.#}, the Mac's rule puts it at {predX:0.#}; off by {cx - predX:0.#} px at {s * 100:0}%");
        // Exact: the mark itself, against the text as the eye sees it (the Mac measured 0.0
        // from the ink's centre and 19.5 points after the highlight, 12 points wide).
        var clamped = Math.Abs(predX - ((drawnRight ?? trimmedRight ?? union.Right) + 19 * s)) > 1 || r.Right >= area.Right;
        if (exact && beside && lines.Length == 1 && !clamped) Exact(name, after, r, s, textMid, union, top, bottom, trimmedRight);

        if (first != null)
        {
            // The circle's centre in the early frame and once settled, from what changed on
            // screen inside the window (less its left edge, over the selection's end). The early
            // one is faint (fading in) and its shadow fainter, so a few points either way.
            var zone = Rectangle.FromLTRB(Math.Min(r.Left, firstRect.Left) + (int)(4 * s), Math.Min(r.Top, firstRect.Top), Math.Max(r.Right, firstRect.Right), Math.Max(r.Bottom, firstRect.Bottom));
            var c0 = Circle(before, first, zone, 12); var c1 = Circle(before, after, zone, 12);
            var same = firstRect.Left == r.Left && firstRect.Top == r.Top && firstRect.Right == r.Right && firstRect.Bottom == r.Bottom;
            Console.WriteLine($"[{name}] early frame {firstMs:0} ms after the window showed: window {firstRect.Left},{firstRect.Top} to {firstRect.Right},{firstRect.Bottom}; circle centre {(c0 is (double a0, double b0) ? $"{a0:0.#},{b0:0.#}" : "not drawn yet")}; settled {(c1 is (double a1, double b1) ? $"{a1:0.#},{b1:0.#}" : "none")}");
            if (!same) failures.Add($"{name}: the eye's window moved after it first showed ({firstRect.Left},{firstRect.Top} to {r.Left},{r.Top})");
            if (c0 is (double x0, double y0) && c1 is (double x1, double y1) && (Math.Abs(x0 - x1) > 1 + s / 2 || Math.Abs(y0 - y1) > 2 + s))
                failures.Add($"{name}: the eye's circle {firstMs:0} ms in is centred at {x0:0.#},{y0:0.#}, settled at {x1:0.#},{y1:0.#}");
            var ez = new Rectangle(zone.Left - (int)(40 * s), zone.Top - (int)(20 * s), zone.Width + (int)(60 * s), zone.Height + (int)(40 * s));
            ez.Intersect(new Rectangle(0, 0, first.Width, first.Height));
            using (var e0 = first.Clone(ez, first.PixelFormat)) e0.Save(Path.Combine(outDir, $"{name}-{firstMs:0}ms.png"), ImageFormat.Png);
            using (var e1 = after.Clone(ez, after.PixelFormat)) e1.Save(Path.Combine(outDir, $"{name}-settled.png"), ImageFormat.Png);
            first.Dispose();
        }
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

    /// The mark's ink inside the eye's circle (darker or lighter than the circle's surface),
    /// then the eye hidden (Shift) and the highlight's right edge read with nothing over it.
    static void Exact(string name, Bitmap after, RECT r, double s, double textMid, System.Windows.Rect union, int inkTop, int inkBottom, double? trimmedRight)
    {
        double cx = (r.Left + r.Right) / 2.0, cy = (r.Top + r.Bottom) / 2.0;
        // The circle's surface: the commonest colour on a ring between the mark and the hairline.
        var ring = new Dictionary<int, int>();
        var zone = (int)Math.Ceiling(10.5 * s);
        int X0 = (int)Math.Floor(cx) - zone, Y0 = (int)Math.Floor(cy) - zone, n = 2 * zone + 1;
        var diff = new int[n, n];
        for (var j = 0; j < n; j++)
            for (var i = 0; i < n; i++)
            {
                var dist = Math.Sqrt(Math.Pow(X0 + i + 0.5 - cx, 2) + Math.Pow(Y0 + j + 0.5 - cy, 2)) / s;
                if (dist >= 8.5 && dist <= 10.5) { var c = after.GetPixel(X0 + i, Y0 + j).ToArgb(); ring[c] = ring.GetValueOrDefault(c) + 1; }
            }
        var surface = Color.FromArgb(ring.Count > 0 ? ring.MaxBy(kv => kv.Value).Key : after.GetPixel((int)cx, (int)(cy - 9 * s)).ToArgb());
        var most = 0;
        for (var j = 0; j < n; j++)
            for (var i = 0; i < n; i++)
            {
                var dist = Math.Sqrt(Math.Pow(X0 + i + 0.5 - cx, 2) + Math.Pow(Y0 + j + 0.5 - cy, 2)) / s;
                if (dist > 9.5) continue;
                var c = after.GetPixel(X0 + i, Y0 + j);
                diff[i, j] = Math.Abs(c.R - surface.R) + Math.Abs(c.G - surface.G) + Math.Abs(c.B - surface.B);
                most = Math.Max(most, diff[i, j]);
            }
        // The mark's edges where it's at least half its full contrast.
        int l = int.MaxValue, rr = int.MinValue, t = int.MaxValue, b = int.MinValue;
        double wx = 0, wy = 0, wsum = 0;
        for (var j = 0; j < n; j++)
            for (var i = 0; i < n; i++)
            {
                wx += diff[i, j] * (X0 + i + 0.5); wy += diff[i, j] * (Y0 + j + 0.5); wsum += diff[i, j];
                if (most == 0 || diff[i, j] * 2 < most) continue;
                l = Math.Min(l, X0 + i); rr = Math.Max(rr, X0 + i); t = Math.Min(t, Y0 + j); b = Math.Max(b, Y0 + j);
            }
        if (name.Contains("line2") || name.Contains("h1-on"))
        {
            Console.WriteLine($"[{name}] mark map from {X0},{Y0} (window centre {cx},{cy}; surface {surface.R},{surface.G},{surface.B}; 9 = full contrast {most}):");
            for (var j = 0; j < n; j++) Console.WriteLine("    " + string.Concat(Enumerable.Range(0, n).Select(i => most == 0 ? '.' : diff[i, j] * 10 / (most + 1) is var v && v == 0 ? '.' : (char)('0' + v))));
        }
        Keys(VK_SHIFT);
        WaitForEye(false, 1500);
        Thread.Sleep(300);
        // Three frames a blink apart: Notepad's caret, blinking at the selection's end, covers
        // its last column in some.
        double? edge = null;
        var edges = new List<string>();
        for (var f = 0; f < 3; f++)
        {
            if (f > 0) Thread.Sleep(270);
            using var selected = Capture();
            if (f == 0) selected.Save(Path.Combine(outDir, name + "-selected.png"), ImageFormat.Png);
            // The highlight: the commonest colour in the selection's rect on the ink's rows.
            var counts = new Dictionary<int, int>();
            for (var y = inkTop; y <= inkBottom; y++) for (var x = (int)union.Left; x < (int)union.Right; x++) { var c = selected.GetPixel(x, y).ToArgb(); counts[c] = counts.GetValueOrDefault(c) + 1; }
            if (counts.Count == 0) continue;
            var hl = Color.FromArgb(counts.MaxBy(kv => kv.Value).Key);
            // Row by row on the ink's middle half, the median (some rows run a few pixels longer).
            var ends = new List<int>();
            int q = (inkBottom - inkTop) / 4;
            for (var y = inkTop + q; y <= inkBottom - q; y++)
                for (var x = Math.Min(selected.Width - 1, (int)(union.Right + 12 * s)); x >= (int)union.Left; x--)
                {
                    var c = selected.GetPixel(x, y);
                    if (Math.Abs(c.R - hl.R) + Math.Abs(c.G - hl.G) + Math.Abs(c.B - hl.B) <= 6) { ends.Add(x); break; }
                }
            ends.Sort();
            var right = ends.Count > 0 ? ends[ends.Count / 2] : -1;
            edges.Add(right >= 0 ? (right + 1).ToString() : "none");
            if (right >= 0 && (edge == null || right + 1 > edge)) edge = right + 1;
        }
        Console.WriteLine($"[{name}] highlight's right edge in three frames a caret blink apart: {string.Join(", ", edges)}");
        // White space at the end is highlighted too (a line break, a space), where the Mac has
        // none: there the text ends where its trimmed range does.
        var textEnd = trimmedRight ?? edge;
        if (l == int.MaxValue) { failures.Add($"{name}: no mark found in the eye"); return; }
        double mx = (l + rr + 1) / 2.0, my = (t + b + 1) / 2.0, mw = (rr - l + 1) / s;
        Console.WriteLine($"[{name}] mark's weighted centre {(wsum > 0 ? $"{wx / wsum:0.##},{wy / wsum:0.##}" : "none")}");
        var dy = (my - textMid) / s; double? dx = textEnd is double e ? (mx - e) / s : null;
        Console.WriteLine($"[{name}] exact: mark {l},{t} to {rr},{b} (centre {mx:0.#},{my:0.#}, {mw:0.##} points wide); ink centre {textMid:0.#}; highlight's right edge {edge?.ToString("0.#") ?? "not found"} (UI Automation {union.Right:0.#}{(trimmedRight is double tr ? $", text without its white space {tr:0.#}" : "")}); mark minus ink {dy:+0.##;-0.##;0} points; mark after the text's end {dx?.ToString("0.##") ?? "?"} points (Mac 19.5)");
        // Half a point, plus half a device pixel: the mark sits on whole pixels.
        var tol = 0.5 + 0.5 / s;
        if (Math.Abs(dy) > tol) failures.Add($"{name}: the mark's centre is {dy:+0.##;-0.##} points from the text's ink centre (the Mac: 0)");
        if (dx is double d && Math.Abs(d - 19.5) > tol) failures.Add($"{name}: the mark's centre is {d:0.##} points after the text's end (the Mac: 19.5)");
        if (dx == null) failures.Add($"{name}: couldn't find the highlight's right edge");
    }

    /// The eye's circle where `shot` differs from `before` inside `zone` by more than `threshold`
    /// (summed over the channels): its centre across from its left and right edges, down from its
    /// top edge and half its width. Null when nothing changed.
    static (double, double)? Circle(Bitmap before, Bitmap shot, Rectangle zone, int threshold)
    {
        zone.Intersect(new Rectangle(0, 0, Math.Min(before.Width, shot.Width), Math.Min(before.Height, shot.Height)));
        int l = int.MaxValue, r = int.MinValue, t = int.MaxValue;
        for (var y = zone.Top; y < zone.Bottom; y++)
            for (var x = zone.Left; x < zone.Right; x++)
            {
                Color a = before.GetPixel(x, y), b = shot.GetPixel(x, y);
                if (Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B) <= threshold) continue;
                l = Math.Min(l, x); r = Math.Max(r, x); t = Math.Min(t, y);
            }
        if (l == int.MaxValue) return null;
        var w = r - l + 1;
        return (l + w / 2.0, t + w / 2.0);
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
                // A caret is a selection too (Edge's address bar has one): only one holding text.
                var sel = t.GetSelection().FirstOrDefault();
                if (sel == null || string.IsNullOrWhiteSpace(sel.GetText(-1))) continue;
                var rects = sel.GetBoundingRectangles();
                if (rects is { Length: > 0 }) return rects;
            }
        }
        catch { }
        return Array.Empty<System.Windows.Rect>();
    }

    /// The right edge of the selection's text without white space at its end.
    static double? TrimmedRight(IntPtr hwnd)
    {
        try
        {
            foreach (AutomationElement e in AutomationElement.FromHandle(hwnd).FindAll(TreeScope.Subtree, Condition.TrueCondition))
            {
                if (!e.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern t) continue;
                var sel = t.GetSelection().FirstOrDefault();
                if (sel == null) continue;
                var text = sel.GetText(-1);
                if (text.Length == 0) continue;
                var trimmed = text.TrimEnd();
                if (trimmed.Length == text.Length) return null;
                Console.WriteLine($"[selection] ends in white space: {string.Join(" ", text.Substring(trimmed.Length).Select(c => ((int)c).ToString("X4")))}");
                // The selection's own range, its end moved back (Chromium's FindText is off by
                // a character a paragraph, so the text can't be found again).
                var r = sel.Clone();
                for (var i = 0; i < 8 && r.GetText(-1).Length > trimmed.Length; i++) r.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, -1);
                var again = r.GetBoundingRectangles();
                return again is { Length: > 0 } ? again.Max(x => x.Right) : null;
            }
        }
        catch { }
        return null;
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
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
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
                // 11 pt as the box reports it (GDI+ here is at 96 dpi): text a real app draws larger.
                var font = new Font("Consolas", 11f, GraphicsUnit.Point);
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
