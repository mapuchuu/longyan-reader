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

namespace Longyan;

/// The Windows app in the apps people read Chinese in: browsers, editors, a terminal, word
/// processors and PDF readers. In each, one line of Chinese (他得了感冒吃不了饭) in magenta, found
/// on screen by its colour, so this check never asks the app's UI Automation itself (asking is
/// what wakes Chromium's, which is part of what's measured). Then, as a reader would: drag over
/// 感冒, the shortcut on that selection, a double-click on 感, and the shortcut while pointing
/// at 感 with nothing selected. For each: whether the eye came, where, whether the app said what
/// was selected, the word on the card and where the card went. A table in OUT/compat.md.
/// Usage: CompatCheck APP_EXE OUT_DIR [CASE...]. App paths come from the environment (CHROME,
/// FIREFOX, VSCODE, WT, SOFFICE, SUMATRA); a case whose app isn't there is listed as skipped.
static class Program
{
    const string Line = "他得了感冒吃不了饭";   // 9 characters, each one em wide
    const string Title = "longyan-compat";
    static string outDir = ".", log = "", work = "", appExe = "";
    static Process? app;
    static bool appWakes;
    static readonly List<string[]> rows = new();
    static readonly List<string> notes = new();

    record Case(string Name, string App, Func<string?> Exe, Func<string, string> Args, string Doc, string[] Kill, bool Wake = true, int Settle = 4000);

    static int Main(string[] args)
    {
        appExe = args[0];
        outDir = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(outDir);
        work = Path.Combine(Path.GetTempPath(), "longyan-compat");
        Directory.CreateDirectory(work);
        log = Path.Combine(outDir, "events.jsonl");
        Console.OutputEncoding = new UTF8Encoding(false);
        Documents();

        string? Env(string name) => Environment.GetEnvironmentVariable(name) is string p && File.Exists(p) ? p : null;
        string? First(params string[] paths) => paths.FirstOrDefault(File.Exists);
        string Profile(string name) { var d = Path.Combine(work, "profile-" + name); if (Directory.Exists(d)) Directory.Delete(d, true); Directory.CreateDirectory(d); return d; }
        var chrome = () => Env("CHROME") ?? First(@"C:\Program Files\Google\Chrome\Application\chrome.exe", @"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe");
        var edge = () => First(@"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", @"C:\Program Files\Microsoft\Edge\Application\msedge.exe");
        var firefox = () => Env("FIREFOX") ?? First(@"C:\Program Files\Mozilla Firefox\firefox.exe");
        var code = () => Env("VSCODE") ?? First(@"C:\Program Files\Microsoft VS Code\Code.exe");
        string Chromium(string name, string doc, string extra = "") => $"--no-first-run --no-default-browser-check --disable-features=Translate --user-data-dir=\"{Profile(name)}\" {extra} --new-window \"{doc}\"";
        var browsers = new[] { "chrome", "msedge" };
        var cases = new List<Case>
        {
            new("chrome-nowake", "Chrome, no wake", chrome, d => Chromium("chrome-nowake", d), "html", browsers, Wake: false),
            new("chrome", "Chrome", chrome, d => Chromium("chrome", d), "html", browsers),
            new("chrome-forced", "Chrome, --force-renderer-accessibility, no wake", chrome, d => Chromium("chrome-forced", d, "--force-renderer-accessibility"), "html", browsers, Wake: false),
            new("edge", "Edge", edge, d => Chromium("edge", d), "html", browsers),
            new("firefox", "Firefox", firefox, d => $"-no-remote -profile \"{FirefoxProfile("firefox", false)}\" -new-window \"{d}\"", "html", new[] { "firefox" }, Settle: 6000),
            new("firefox-uia", "Firefox, accessibility.uia.enable 1", firefox, d => $"-no-remote -profile \"{FirefoxProfile("firefox-uia", true)}\" -new-window \"{d}\"", "html", new[] { "firefox" }, Settle: 6000),
            new("vscode-nowake", "VS Code, no wake", code, d => VsCode("vscode-nowake", d), "txt", new[] { "code" }, Wake: false, Settle: 8000),
            new("vscode", "VS Code", code, d => VsCode("vscode", d), "txt", new[] { "code" }, Settle: 8000),
            new("terminal", "Windows Terminal", () => Env("WT"), d => $"--title {Title} --suppressApplicationTitle powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File \"{d}\"", "ps1", new[] { "windowsterminal", "wt", "openconsole" }, Settle: 5000),
            new("writer", "LibreOffice Writer", () => Env("SOFFICE"), d => $"-env:UserInstallation=file:///{LibreProfile().Replace('\\', '/')} --writer --norestore --nologo \"{d}\"", "rtf", new[] { "soffice", "soffice.bin" }, Settle: 10000),
            new("wordpad", "WordPad", () => First(@"C:\Program Files\Windows NT\Accessories\wordpad.exe"), d => $"\"{d}\"", "rtf", new[] { "wordpad" }),
            new("edge-pdf", "PDF in Edge", edge, d => Chromium("edge-pdf", d), "pdf", browsers, Settle: 6000),
            // Windows 11's Notepad (the Store app on a rich edit box): plain text, found through UI Automation.
            new("notepad11", "Notepad (Windows 11)", () => Env("NOTEPAD11"), d => $"\"{d}\"", "txt", new[] { "notepad" }, Settle: 4000),
            new("sumatra", "SumatraPDF", () => Env("SUMATRA"), d => $"-new-window \"{d}\"", "pdf", new[] { "sumatrapdf" }, Settle: 5000),
        };
        var wanted = args.Skip(2).ToHashSet();
        if (wanted.Count > 0) cases = cases.Where(c => wanted.Contains(c.Name)).ToList();
        if (cases.Any(c => c.Doc == "pdf")) Pdf(edge());

        // The welcome window would take the first selection; it's been seen.
        var settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(settings)!);
        File.WriteAllText(settings, "{\"welcomeShown\":true}");

        foreach (var c in cases)
        {
            var exe = c.Exe();
            if (exe == null) { rows.Add(new[] { c.App, "all", "skipped: not installed", "", "", "", "" }); continue; }
            try { Run(c, exe); }
            catch (Exception e) { rows.Add(new[] { c.App, "all", "check failed: " + e.Message, "", "", "", "" }); Console.WriteLine(e); }
            Kill(c.Kill);
        }
        try { app?.Kill(); } catch { }
        Table();
        return 0;
    }

    // Documents: the line in magenta, alone near the top, with white space below it.

    static string Doc(string ext) => Path.Combine(work, Title + "." + ext);

    static void Documents()
    {
        File.WriteAllText(Doc("html"), $"""
            <!doctype html><meta charset="utf-8"><title>{Title}</title>
            <body style="margin:40px;background:#fff;font-family:'Microsoft YaHei',sans-serif">
            <p style="font-size:32px;color:#f0f;margin:0">{Line}</p>
            <div style="height:1400px"></div>
            """, new UTF8Encoding(false));
        File.WriteAllText(Doc("txt"), Line + "\r\n", new UTF8Encoding(false));
        // RTF wants each character as \uN? (a signed 16-bit number).
        var rtf = string.Concat(Line.Select(ch => $"\\u{(short)ch}?"));
        File.WriteAllText(Doc("rtf"), "{\\rtf1\\ansi\\ansicpg936\\deff0{\\fonttbl{\\f0\\fnil\\fcharset134 Microsoft YaHei;}}{\\colortbl;\\red255\\green0\\blue255;}\\f0\\fs56\\cf1 " + rtf + "\\par}", Encoding.ASCII);
        var codes = string.Join(",", Line.Select(ch => "0x" + ((int)ch).ToString("X4")));
        File.WriteAllText(Doc("ps1"), $$"""
            [Console]::OutputEncoding = [Text.Encoding]::UTF8
            $e = [char]27
            $s = -join ({{codes}} | ForEach-Object { [char]$_ })
            Write-Host ""
            Write-Host "$e[38;2;255;0;255m$s$e[0m"
            Write-Host ""
            """, new UTF8Encoding(true));
    }

    /// The HTML printed to PDF by Edge, so the PDF has the font and the colour.
    static void Pdf(string? edge)
    {
        if (edge == null) return;
        var p = Process.Start(new ProcessStartInfo(edge, $"--headless --disable-gpu --no-pdf-header-footer --user-data-dir=\"{Path.Combine(work, "pdf-profile")}\" --print-to-pdf=\"{Doc("pdf")}\" \"{Doc("html")}\"") { UseShellExecute = false })!;
        p.WaitForExit(60000);
        Console.WriteLine($"[pdf] {(File.Exists(Doc("pdf")) ? new FileInfo(Doc("pdf")).Length + " bytes" : "not made")}");
    }

    static string FirefoxProfile(string name, bool uia)
    {
        var d = Path.Combine(work, "profile-" + name);
        if (Directory.Exists(d)) Directory.Delete(d, true);
        Directory.CreateDirectory(d);
        var prefs = new StringBuilder();
        foreach (var (k, v) in new[] {
            ("browser.shell.checkDefaultBrowser", "false"), ("browser.aboutwelcome.enabled", "false"),
            ("datareporting.policy.dataSubmissionEnabled", "false"), ("datareporting.policy.firstRunURL", "\"\""),
            ("browser.startup.homepage_override.mstone", "\"ignore\""), ("toolkit.telemetry.reportingpolicy.firstRun", "false"),
            ("app.update.disabledForTesting", "true"), ("browser.translations.automaticallyPopup", "false"),
            ("datareporting.policy.dataSubmissionPolicyBypassNotification", "true"), ("datareporting.policy.dataSubmissionPolicyAcceptedVersion", "2"),
            ("datareporting.policy.dataSubmissionPolicyNotifiedTime", "\"1700000000000\""), ("startup.homepage_welcome_url", "\"\""),
            ("startup.homepage_welcome_url.additional", "\"\""), ("browser.startup.firstrunSkipsHomepage", "true") })
            prefs.AppendLine($"user_pref(\"{k}\", {v});");
        if (uia) prefs.AppendLine("user_pref(\"accessibility.uia.enable\", 1);");
        File.WriteAllText(Path.Combine(d, "user.js"), prefs.ToString());
        return d;
    }

    static string VsCode(string name, string doc)
    {
        var d = Path.Combine(work, "profile-" + name);
        if (Directory.Exists(d)) Directory.Delete(d, true);
        Directory.CreateDirectory(Path.Combine(d, "User"));
        // Plain text takes the editor's foreground colour. Accessibility support stays on
        // "auto", as people have it.
        File.WriteAllText(Path.Combine(d, "User", "settings.json"), """
            {
              "workbench.colorTheme": "Default Light Modern",
              "workbench.colorCustomizations": { "editor.foreground": "#ff00ff" },
              "editor.fontSize": 28,
              "editor.lineNumbers": "off",
              "editor.minimap.enabled": false,
              "editor.renderLineHighlight": "none",
              "editor.occurrencesHighlight": "off",
              "editor.selectionHighlight": false,
              "editor.unicodeHighlight.ambiguousCharacters": false,
              "workbench.startupEditor": "none",
              "workbench.tips.enabled": false,
              "security.workspace.trust.enabled": false,
              "telemetry.telemetryLevel": "off",
              "update.mode": "none",
              "extensions.ignoreRecommendations": true,
              "chat.disableAIFeatures": true
            }
            """);
        return $"--user-data-dir \"{d}\" --extensions-dir \"{Path.Combine(d, "ext")}\" --disable-workspace-trust --new-window \"{doc}\"";
    }

    static string LibreProfile()
    {
        var d = Path.Combine(work, "profile-writer");
        if (Directory.Exists(d)) Directory.Delete(d, true);
        Directory.CreateDirectory(Path.Combine(d, "user"));
        File.WriteAllText(Path.Combine(d, "user", "registrymodifications.xcu"), """
            <?xml version="1.0" encoding="UTF-8"?>
            <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="ShowTipOfTheDay" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Setup/Office"><prop oor:name="ooSetupInstCompleted" oor:op="fuse"><value>true</value></prop></item>
            </oor:items>
            """);
        return d;
    }

    // One app.

    static void StartApp(bool wake)
    {
        if (app is { HasExited: false } && appWakes == wake) return;
        try { app?.Kill(); app?.WaitForExit(5000); } catch { }
        var start = new ProcessStartInfo(appExe) { WorkingDirectory = Path.GetDirectoryName(appExe)!, UseShellExecute = false };
        start.Environment["LONGYAN_CARD_LOG"] = log;
        if (!wake) start.Environment["LONGYAN_WAKE"] = "0";
        app = Process.Start(start)!;
        appWakes = wake;
        Thread.Sleep(12000);   // the dictionary and splitter load
        Ping(app);
    }

    static void Run(Case c, string exe)
    {
        Console.WriteLine($"== {c.Name}");
        var start = Lines();
        Kill(c.Kill);
        StartApp(c.Wake);
        var doc = Doc(c.Doc);
        var launched = Stopwatch.StartNew();
        Process.Start(new ProcessStartInfo(exe, c.Args(doc)) { UseShellExecute = false, WorkingDirectory = work });
        var window = WaitForWindow(Title, 60000);
        if (window == IntPtr.Zero) { Shot(c.Name + "-no-window"); rows.Add(new[] { c.App, "all", "the app's window didn't open", "", "", "", "" }); return; }
        ShowWindow(window, SW_RESTORE);
        SetWindowPos(window, IntPtr.Zero, 0, 0, 1000, 720, SWP_NOZORDER);
        Thread.Sleep(c.Settle);
        GetWindowRect(window, out var wr);
        // Brought forward with a click on the title bar's empty part.
        SetForegroundWindow(window);
        Click(wr.Left + (wr.Right - wr.Left) * 0.72, wr.Top + 10);
        Thread.Sleep(800);
        Rectangle? found = null;
        for (var i = 0; i < 40 && found == null; i++) { found = c.Name == "notepad11" ? Located(window) : Magenta(); if (found == null) Thread.Sleep(500); }
        Shot(c.Name + "-0");
        if (found is not Rectangle ink) { rows.Add(new[] { c.App, "all", "couldn't find the text on screen", "", "", "", "" }); return; }
        var cell = ink.Width / (double)Line.Length;
        var word = new Rect(ink.Left + 3 * cell, ink.Top, 2 * cell, ink.Height);   // 感冒
        var line = new Rect(ink.Left, ink.Top, ink.Width, ink.Height);
        var cy = ink.Top + ink.Height / 2.0;
        var blank = (x: word.Left, y: Math.Min(ink.Bottom + 160, wr.Bottom - 30));
        Console.WriteLine($"[{c.Name}] text at {ink}, one character {cell:0.#} px, {launched.ElapsedMilliseconds} ms after launch");

        void Deselect() { Click(blank.x, blank.y); Thread.Sleep(700); }
        void DragWord() => Drag(word.Left + 2, cy, word.Right - 2, cy);

        // 1. Drag over 感冒 (the first selection since the app opened), then the eye.
        var first = Eye(c, "drag", DragWord, word, line);
        // Chromium's tree may come later: how long until a drag reads.
        if (first != "read")
        {
            var waited = Stopwatch.StartNew();
            string? got = null;
            for (var i = 0; i < 8 && got == null; i++)
            {
                Deselect();
                var mark = Lines();
                DragWord();
                if (WaitFor(mark, "eye", 2000) is JsonObject e && (bool?)e["readable"] == true) got = $"a drag read after {waited.ElapsedMilliseconds / 1000.0:0.#} s more";
                Keys(VK_ESCAPE);
            }
            notes.Add($"{c.App}: first drag gave \"{first}\"; {got ?? "no drag read in the next 8 tries"}");
        }
        HideEye();

        // 2. The shortcut on that selection.
        Deselect(); DragWord(); Thread.Sleep(400);
        Shortcut(c, "shortcut on the drag", word, line);

        // 3. Double-click 感.
        Deselect();
        Eye(c, "double-click", () => DoubleClick(word.Left + cell / 2, cy), word, line);
        HideEye();

        // 4. Point at 感 with nothing selected and press the shortcut.
        Deselect();
        MoveTo(word.Left + cell / 2, cy);
        Thread.Sleep(400);
        Shortcut(c, "point + shortcut", word, line);

        var wakes = Events(start).Where(e => (string?)e["event"] == "wake").Select(e => $"{e["found"]} in {e["ms"]} ms{((bool?)e["later"] == true ? " (2 s later)" : "")}").ToList();
        if (wakes.Count > 0) notes.Add($"{c.App}: woken {wakes.Count} times: {string.Join("; ", wakes.Distinct())}");
    }

    /// A selection made by `select`, then the eye: whether it came, whether it read the
    /// selection, where it is; then a click on it and the card.
    static string Eye(Case c, string action, Action select, Rect word, Rect line)
    {
        Stall();
        var mark = Lines();
        select();
        var up = Cursor();
        var e = WaitFor(mark, "eye", 2500);
        var eye = EyeWindow();
        Shot($"{c.Name}-{action.Replace(' ', '-')}");
        if (eye == IntPtr.Zero || e == null)
        {
            rows.Add(new[] { c.App, action, "no eye", "", "", "", $"{Stall()}" });
            return "no eye";
        }
        var readable = (bool?)e["readable"] == true;
        GetWindowRect(eye, out var r);
        var s = (r.Right - r.Left) / 44.0;
        double left = r.Left + 7 * s, top = r.Top + 7 * s, mid = (r.Top + r.Bottom) / 2.0;
        string place;
        if (Math.Abs(mid - (line.Top + line.Height / 2)) <= 6 * s && left >= word.Right - 4 && left <= line.Right + 40 * s)
            place = left <= word.Right + 40 * s ? $"beside, {left - word.Right:0} px after 冒" : $"beside, {left - line.Right:0} px after the line";
        else if (Math.Abs(left - (up.X + 6 * s)) <= 4 && Math.Abs(top + 30 * s - (up.Y - 6 * s)) <= 4) place = "above right of the pointer";
        else place = $"elsewhere ({left - word.Right:0}, {mid - (line.Top + line.Height / 2):0} from the word's end)";
        // A click on it: the card, from what the eye read or by copying.
        var before = Lines();
        Click((r.Left + r.Right) / 2.0, mid);
        var card = Card(before, word, line);
        Shot($"{c.Name}-{action.Replace(' ', '-')}-card");
        Thread.Sleep(1500);
        rows.Add(new[] { c.App, action, readable ? "eye, read" : "eye, not read (copies on click)", place, card.word, card.place, $"{Stall()}" });
        Keys(VK_ESCAPE);
        Thread.Sleep(500);
        return readable ? "read" : "unreadable";
    }

    static void Shortcut(Case c, string action, Rect word, Rect line)
    {
        Stall();
        var mark = Lines();
        Keys(VK_CONTROL, VK_MENU, 0x4C);
        var card = Card(mark, word, line);
        Shot($"{c.Name}-{action.Replace(' ', '-').Replace("+", "")}");
        var how = WaitFor(mark, "selection", 100) is JsonObject s ? (string?)s["how"] ?? "?" : "?";
        var point = WaitFor(mark, "point", 100) is JsonObject p ? (string?)p["found"] : null;
        var read = how switch { "automation" => "read (UI Automation)", "point" => "read at the pointer", "copy" => "read by copying", "none" => "nothing read", _ => how };
        if (point != null && how != "point") read += $"; pointer: {point}";
        Thread.Sleep(1500);
        rows.Add(new[] { c.App, action, read, "", card.word, card.place, $"{Stall()}" });
        Keys(VK_ESCAPE);
        Thread.Sleep(500);
    }

    /// The card that opened after line `mark` of the log: its word, and where it went.
    static (string word, string place) Card(int mark, Rect word, Rect line)
    {
        var revealed = WaitFor(mark, "revealed", 8000);
        Thread.Sleep(300);
        var card = Events(mark).LastOrDefault(e => (string?)e["event"] == "card")?["card"] as JsonObject;
        var text = card == null ? "" : (string?)card["word"] ?? (string?)card["text"] ?? "";
        if (revealed == null) return (card == null ? "no card" : text, "");
        if ((bool?)revealed["hint"] == true) return ("a hint, no card", "");
        var a = revealed["anchor"]!.AsArray().Select(v => (double)v!).ToArray();
        var anchor = new Rect(a[0], a[1], a[2] - a[0], a[3] - a[1]);
        double top = (double)revealed["top"]!, height = (double)revealed["height"]!;
        var below = (bool?)revealed["below"] == true;
        var gap = below ? top - anchor.Bottom : anchor.Top - (top + height);
        var near = new Rect(line.Left - 10, line.Top - 10, line.Width + 20, line.Height + 20);
        var at = anchor.IntersectsWith(near) && anchor.Height < 3 * line.Height ? "the text" : "the pointer";
        return (text, $"{(below ? "below" : "above")} {at}, {gap:0} px gap");
    }

    static void HideEye()
    {
        if (EyeWindow() == IntPtr.Zero) return;
        Keys(VK_ESCAPE);
        Thread.Sleep(400);
    }

    static void Table()
    {
        var md = new StringBuilder();
        md.AppendLine("| App | What | Read | Eye place | Card word | Card place | App thread's longest wait (ms) |");
        md.AppendLine("|---|---|---|---|---|---|---|");
        foreach (var r in rows) md.AppendLine("| " + string.Join(" | ", r) + " |");
        md.AppendLine();
        foreach (var n in notes) md.AppendLine("- " + n);
        File.WriteAllText(Path.Combine(outDir, "compat.md"), md.ToString(), new UTF8Encoding(false));
        Console.WriteLine(md);
    }

    // The screen.

    /// The magenta line's ink on screen, or null.
    static Rectangle? Magenta()
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        using var bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        var data = bmp.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new byte[data.Stride * b.Height];
        Marshal.Copy(data.Scan0, px, 0, px.Length);
        bmp.UnlockBits(data);
        bool Hit(int x, int y) { var i = y * data.Stride + x * 4; int B = px[i], G = px[i + 1], R = px[i + 2]; return R >= 170 && B >= 170 && G <= 110 && Math.Abs(R - B) <= 70; }
        // Rows with magenta, in bands of touching rows; the band with the most is the line (an
        // icon in the toolbar, Edge's Copilot, can be magenta too).
        var count = new int[b.Height];
        for (var y = 0; y < b.Height; y++) for (var x = 0; x < b.Width; x++) if (Hit(x, y)) count[y]++;
        int bestTop = -1, bestBottom = -1, best = 0;
        for (var y = 0; y < b.Height; y++)
        {
            if (count[y] == 0) continue;
            int y0 = y, sum = 0;
            // A gap of a few rows still counts as the same line (strokes of a character).
            for (var gap = 0; y < b.Height && gap <= 3; y++) { if (count[y] > 0) { sum += count[y]; gap = 0; } else gap++; }
            var y1 = y - 5;
            if (sum > best) { best = sum; bestTop = y0; bestBottom = y1; }
        }
        if (best < 60) return null;
        int l = int.MaxValue, r = -1, t = bestTop, bt = bestBottom;
        for (var y = t; y <= bt; y++) for (var x = 0; x < b.Width; x++) if (Hit(x, y)) { l = Math.Min(l, x); r = Math.Max(r, x); }
        if (r - l < 40) return null;
        return new Rectangle(l + b.Left, t + b.Top, r - l + 1, bt - t + 1);
    }

    /// The line in a window's document, through its UI Automation text pattern.
    static Rectangle? Located(IntPtr hwnd)
    {
        try
        {
            foreach (System.Windows.Automation.AutomationElement e in System.Windows.Automation.AutomationElement.FromHandle(hwnd).FindAll(System.Windows.Automation.TreeScope.Subtree, System.Windows.Automation.Condition.TrueCondition))
            {
                if (!e.TryGetCurrentPattern(System.Windows.Automation.TextPattern.Pattern, out var p) || p is not System.Windows.Automation.TextPattern t) continue;
                var rects = t.DocumentRange.FindText(Line, false, false)?.GetBoundingRectangles();
                if (rects is { Length: > 0 }) return new Rectangle((int)rects[0].Left, (int)rects[0].Top, (int)rects[0].Width, (int)rects[0].Height);
            }
        }
        catch { }
        return null;
    }

    // How long the app's own thread takes to answer: a WM_NULL sent every 100 ms to one of its
    // windows. A click on the eye or the card waits as long.
    static long longest, pingStarted;

    static void Ping(Process p)
    {
        var hwnd = IntPtr.Zero;
        for (var i = 0; i < 20 && hwnd == IntPtr.Zero; i++)
        {
            EnumWindows((h, _) => { GetWindowThreadProcessId(h, out var pid); if (pid == p.Id) { hwnd = h; return false; } return true; }, IntPtr.Zero);
            if (hwnd == IntPtr.Zero) Thread.Sleep(500);
        }
        if (hwnd == IntPtr.Zero) { Console.WriteLine("[ping] no window of the app's"); return; }
        new Thread(() =>
        {
            while (!p.HasExited)
            {
                var clock = Stopwatch.StartNew();
                Interlocked.Exchange(ref pingStarted, Environment.TickCount64);
                SendMessageTimeout(hwnd, 0 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero, 0, 300000, out _);
                Interlocked.Exchange(ref pingStarted, 0);
                var ms = clock.ElapsedMilliseconds;
                long seen;
                while (ms > (seen = Interlocked.Read(ref longest)) && Interlocked.CompareExchange(ref longest, ms, seen) != seen) { }
                Thread.Sleep(100);
            }
        }) { IsBackground = true }.Start();
    }

    /// The longest wait since the last call, a wait still going included; and starts again.
    static long Stall()
    {
        var started = Interlocked.Read(ref pingStarted);
        var now = started > 0 ? Environment.TickCount64 - started : 0;
        return Math.Max(Interlocked.Exchange(ref longest, 0), now);
    }

    static void Shot(string name)
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        using var bmp = new Bitmap(b.Width, b.Height);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        bmp.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
    }

    // The app's event log.

    static int Lines() => File.Exists(log) ? Read().Length : 0;

    static string[] Read()
    {
        for (var i = 0; i < 5; i++) { try { return File.ReadAllLines(log); } catch (IOException) { Thread.Sleep(50); } }
        return Array.Empty<string>();
    }

    static List<JsonObject> Events(int skip)
    {
        var list = new List<JsonObject>();
        if (!File.Exists(log)) return list;
        foreach (var l in Read().Skip(skip)) { try { if (JsonNode.Parse(l) is JsonObject e) list.Add(e); } catch { } }
        return list;
    }

    static JsonObject? WaitFor(int skip, string name, int ms)
    {
        var end = DateTime.Now.AddMilliseconds(ms);
        do
        {
            if (Events(skip).FirstOrDefault(e => (string?)e["event"] == name) is JsonObject e) return e;
            Thread.Sleep(100);
        } while (DateTime.Now < end);
        return null;
    }

    // Windows and input.

    static IntPtr EyeWindow()
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

    static IntPtr WaitForWindow(string title, int ms)
    {
        var end = DateTime.Now.AddMilliseconds(ms);
        while (DateTime.Now < end)
        {
            var found = IntPtr.Zero;
            EnumWindows((h, _) =>
            {
                var sb = new StringBuilder(256);
                GetWindowText(h, sb, 256);
                if (IsWindowVisible(h) && sb.ToString().Contains(title) && GetWindow(h, GW_OWNER) == IntPtr.Zero) { found = h; return false; }
                return true;
            }, IntPtr.Zero);
            if (found != IntPtr.Zero) return found;
            Thread.Sleep(300);
        }
        return IntPtr.Zero;
    }

    static void Kill(string[] names)
    {
        foreach (var n in names)
            foreach (var p in Process.GetProcessesByName(n)) { try { p.Kill(true); } catch { } }
        Thread.Sleep(1500);
    }

    record struct Rect(double Left, double Top, double Width, double Height)
    {
        public double Right => Left + Width;
        public double Bottom => Top + Height;
        public bool IntersectsWith(Rect o) => Left < o.Right && o.Left < Right && Top < o.Bottom && o.Top < Bottom;
    }

    static (int X, int Y) Cursor() { GetCursorPos(out var p); return (p.X, p.Y); }
    /// Moves as a mouse does (an input event, which some apps, Windows Terminal and LibreOffice,
    /// need to see, where a SetCursorPos isn't enough).
    static void MoveTo(double x, double y)
    {
        var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        var input = new INPUT { type = 0, u = new InputUnion { mi = new MOUSEINPUT {
            dx = (int)Math.Round(x * 65535.0 / (b.Width - 1)), dy = (int)Math.Round(y * 65535.0 / (b.Height - 1)), dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE } } };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
        SetCursorPos((int)Math.Round(x), (int)Math.Round(y));
    }

    static void Button(uint flags) => SendInput(1, new[] { Mouse(flags) }, Marshal.SizeOf<INPUT>());

    static void Click(double x, double y)
    {
        MoveTo(x, y);
        Thread.Sleep(60);
        Button(MOUSEEVENTF_LEFTDOWN); Thread.Sleep(30); Button(MOUSEEVENTF_LEFTUP);
        Thread.Sleep(100);
    }

    static void DoubleClick(double x, double y)
    {
        MoveTo(x, y);
        Thread.Sleep(60);
        Button(MOUSEEVENTF_LEFTDOWN); Thread.Sleep(30); Button(MOUSEEVENTF_LEFTUP); Thread.Sleep(60);
        Button(MOUSEEVENTF_LEFTDOWN); Thread.Sleep(30); Button(MOUSEEVENTF_LEFTUP);
    }

    static void Drag(double x0, double y0, double x1, double y1)
    {
        MoveTo(x0, y0);
        Thread.Sleep(60);
        Button(MOUSEEVENTF_LEFTDOWN);
        Thread.Sleep(60);
        for (var i = 1; i <= 20; i++) { MoveTo(x0 + (x1 - x0) * i / 20.0, y0 + (y1 - y0) * i / 20.0); Thread.Sleep(20); }
        Thread.Sleep(80);
        Button(MOUSEEVENTF_LEFTUP);
    }

    static void Keys(params int[] vks)
    {
        var inputs = vks.Select(k => Key(k, false)).Concat(vks.Reverse().Select(k => Key(k, true))).ToArray();
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        Thread.Sleep(120);
    }

    static INPUT Key(int vk, bool up) => new() { type = 1, u = new InputUnion { ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = up ? 2u : 0u } } };
    static INPUT Mouse(uint flags) => new() { type = 0, u = new InputUnion { mi = new MOUSEINPUT { dwFlags = flags } } };

    const int VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, SW_RESTORE = 9;
    const uint MOUSEEVENTF_MOVE = 1, MOUSEEVENTF_ABSOLUTE = 0x8000, MOUSEEVENTF_LEFTDOWN = 2, MOUSEEVENTF_LEFTUP = 4, SWP_NOZORDER = 4, GW_OWNER = 4;

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
}
