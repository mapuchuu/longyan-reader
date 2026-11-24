using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// `--show`, the dev mode for filming the card beside the Mac's: phrase-ming.json opens with no
/// model where the selection (200, 150, 60, 20) DIPs would put it, a row opens with the
/// dictionary's meanings, Esc closes the card, and it opens again a second later.
static partial class Program
{
    static void ShowCheck(string exe)
    {
        var json = Path.GetFullPath(Path.Combine("windows", "gallery", "phrase-ming.json"));
        if (!File.Exists(json)) { failures.Add("7-show: windows/gallery/phrase-ming.json is missing (run from the repo)"); return; }
        var events = Path.Combine(outDir, "show-events.jsonl");
        var start = new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)! };
        foreach (var a in new[] { "--show", json, "200", "150" }) start.ArgumentList.Add(a);
        start.Environment["LONGYAN_CARD_LOG"] = events;
        CloseStartMenu("before");
        var show = Process.Start(start)!;
        try
        {
            var waited = Stopwatch.StartNew();
            System.Windows.Rect? row = null;
            while (waited.Elapsed.TotalSeconds < 40 && !show.HasExited && (row = FindText(show, "明朝")) == null) Thread.Sleep(250);
            if (row is not System.Windows.Rect r) { failures.Add("7-show: no card in 40 s" + (show.HasExited ? $" (exited {show.ExitCode})" : "")); Shot("7-show-none"); return; }
            Thread.Sleep(600);
            CloseStartMenu("over the card");
            Shot("7-show");
            var revealed = File.Exists(events) ? File.ReadLines(events).Select(l => JsonNode.Parse(l) as JsonObject).LastOrDefault(e => (string?)e?["event"] == "revealed") : null;
            if (revealed != null)
            {
                Console.WriteLine($"[7-show] {revealed.ToJsonString()}");
                var scale = (double)revealed["scale"]!;
                if (Math.Abs((double)revealed["left"]! - 200 * scale) > 2 || Math.Abs((double)revealed["top"]! - (150 + 20 + 8) * scale) > 3)
                    failures.Add($"7-show: card at {revealed["left"]}, {revealed["top"]}; wanted {200 * scale}, {178 * scale}");
            }
            else failures.Add("7-show: no revealed event");
            // The row's word, not the header (the whole phrase, which has 明朝 in it too).
            if (FindExact(show, "明朝") is System.Windows.Rect word) r = word;
            else { failures.Add("7-show: no 明朝 row"); return; }
            CloseStartMenu("before the click");
            MoveTo(r.Left + 10, r.Top + r.Height / 2);
            Thread.Sleep(400);
            Click(r.Left + 10, r.Top + r.Height / 2);
            Burst("7-show-open", 800);
            Thread.Sleep(500);
            Shot("7-show-opened");
            if (FindText(show, "Ming Dynasty (1368-1644)") == null) failures.Add("7-show: the 明朝 row didn't open to its meanings");
            Keys(VK_ESCAPE);
            Thread.Sleep(500);
            if (CardOpen(show)) failures.Add("7-show: Esc didn't close the card");
            Thread.Sleep(1500);
            if (FindExact(show, "明朝") == null) failures.Add("7-show: the card didn't open again after Esc");
            Shot("7-show-again");
        }
        finally
        {
            try { show.Kill(); } catch { }
        }
    }

    /// `--show --script --appearance --trace`: word-mianzi.json worked from inside the app (no
    /// mouse): row 1 hovered then picked, Copy clicked, Esc, and the plan again when it reopens;
    /// each step logged, the trace writing frames with the parts' names, in dark.
    static void ScriptCheck(string exe)
    {
        var json = Path.GetFullPath(Path.Combine("windows", "gallery", "word-mianzi.json"));
        if (!File.Exists(json)) { failures.Add("7-script: windows/gallery/word-mianzi.json is missing"); return; }
        var events = Path.Combine(outDir, "script-events.jsonl");
        var tracePath = Path.Combine(outDir, "script-trace.jsonl");
        var errPath = Path.Combine(outDir, "script-stderr.txt");
        const string plan = "0.3,hover,row1;0.9,click,row1;2.0,click,copy;3.0,unhover;3.3,esc";
        var start = new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)!, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in new[] { "--show", json, "200", "150", "--script", plan, "--appearance", "dark", "--trace", tracePath }) start.ArgumentList.Add(a);
        start.Environment["LONGYAN_CARD_LOG"] = events;
        var show = Process.Start(start)!;
        var err = new System.Text.StringBuilder();
        show.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (err) err.AppendLine(e.Data); };
        show.BeginErrorReadLine();
        try
        {
            var waited = Stopwatch.StartNew();
            bool Revealed() { try { return File.Exists(events) && File.ReadAllText(events).Contains("\"event\":\"revealed\""); } catch (IOException) { return false; } }
            while (waited.Elapsed.TotalSeconds < 40 && !show.HasExited && !Revealed()) Thread.Sleep(100);
            if (show.HasExited || !Revealed()) { failures.Add("7-script: no card in 40 s" + (show.HasExited ? $" (exited {show.ExitCode})" : "")); return; }
            Thread.Sleep(1200);
            Shot("7-script-hover");
            Thread.Sleep(2900);   // past the Esc, 3.8 s after the reveal
            Thread.Sleep(2500);   // the card again a second on, and its first step
            Shot("7-script-again");
        }
        finally
        {
            try { show.Kill(); } catch { }
        }
        Thread.Sleep(300);
        string log;
        lock (err) log = err.ToString();
        File.WriteAllText(errPath, log);
        var lines = File.Exists(events) ? File.ReadLines(events).Select(l => { try { return JsonNode.Parse(l) as JsonObject; } catch { return null; } }).Where(e => e != null).ToList() : new();
        var steps = lines.Where(e => (string?)e!["event"] == "script").Select(e => (string?)e!["step"] ?? "").ToList();
        Console.WriteLine($"[7-script] steps: {string.Join(" | ", steps)}");
        foreach (var want in new[] { "reveal", "t=0 (reveal done)", "t=0.3 hover row1", "t=0.9 click row1", "t=0.97 release", "t=2 click copy", "t=3.3 esc" })
            if (!steps.Contains(want)) failures.Add($"7-script: no \"{want}\" step logged");
        if (!log.Contains("script mono=")) failures.Add("7-script: nothing on stderr");
        if (!lines.Any(e => (string?)e!["event"] == "action" && (string?)e!["what"] == "pick")) failures.Add("7-script: the click on row1 didn't pick it");
        if (lines.Count(e => (string?)e!["event"] == "revealed") < 2) failures.Add("7-script: the card didn't open again after the scripted Esc");
        if (steps.Count(s => s == "t=0.3 hover row1") < 2) failures.Add("7-script: the plan didn't run again on the reopened card");
        var frames = File.Exists(tracePath) ? File.ReadLines(tracePath).Select(l => { try { return JsonNode.Parse(l) as JsonObject; } catch { return null; } }).ToList() : new();
        Console.WriteLine($"[7-script] trace: {frames.Count} frames");
        if (frames.Count < 20 || frames.Any(f => f == null)) { failures.Add($"7-script: the trace has {frames.Count} frames, or a line that isn't JSON"); return; }
        double Max(string name, string key) => frames.Max(f => (double?)f!["elements"]?[name]?[key] ?? 0);
        if (Max("row1-hover", "opacity") < 0.04) failures.Add("7-script: the trace never shows row1-hover");
        if (Max("row1-checkmark", "opacity") < 0.99) failures.Add("7-script: the trace never shows row1's checkmark");
        var alphas = frames.Select(f => (double?)f!["alpha"] ?? -1).ToList();
        if (!alphas.Any(a => a > 0.05 && a < 0.95)) failures.Add("7-script: the trace has no frame mid-fade");
        if (!frames.Any(f => (double?)f!["scale"] is double sc && sc > 0.961 && sc < 0.999)) failures.Add("7-script: the trace has no frame mid-reveal");
        var mono = frames.Select(f => (double?)f!["mono"] ?? 0).ToList();
        for (var i = 1; i < mono.Count; i++) if (mono[i] < mono[i - 1]) { failures.Add("7-script: the trace's times go back"); break; }
    }

    /// The ready plans run whole, in dark, with a trace each, to set beside the Mac's
    /// (windows/gallery/README.md): film-word.* and film-phrase.* in the output.
    static void FilmChecks(string exe)
    {
        Film(exe, "word-mianzi.json", "word.txt", "film-word", 12.5);
        Film(exe, "phrase-ming.json", "phrase.txt", "film-phrase", 12.5);
    }

    static void Film(string exe, string card, string plan, string name, double seconds)
    {
        var json = Path.GetFullPath(Path.Combine("windows", "gallery", card));
        var planPath = Path.GetFullPath(Path.Combine("windows", "gallery", "plans", plan));
        var tracePath = Path.Combine(outDir, name + ".jsonl");
        var start = new ProcessStartInfo(exe) { WorkingDirectory = Path.GetDirectoryName(exe)!, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in new[] { "--show", json, "200", "150", "--script", "@" + planPath, "--appearance", "dark", "--trace", tracePath }) start.ArgumentList.Add(a);
        start.Environment["LONGYAN_CARD_LOG"] = Path.Combine(outDir, name + "-events.jsonl");
        var show = Process.Start(start)!;
        var err = new System.Text.StringBuilder();
        show.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (err) err.AppendLine(e.Data); };
        show.BeginErrorReadLine();
        try
        {
            var waited = Stopwatch.StartNew();
            bool Revealed() { lock (err) return err.ToString().Contains(" reveal"); }
            while (waited.Elapsed.TotalSeconds < 40 && !show.HasExited && !Revealed()) Thread.Sleep(100);
            Thread.Sleep((int)(seconds * 1000));
        }
        finally
        {
            try { show.Kill(); } catch { }
        }
        Thread.Sleep(300);
        string log;
        lock (err) log = err.ToString();
        File.WriteAllText(Path.Combine(outDir, name + ".err"), log);
        var steps = log.Split('\n').Count(l => l.Contains("script mono=") && l.Contains(" t="));
        var planSteps = File.ReadAllLines(planPath).Count(l => l.Trim().Length > 0 && !l.StartsWith('#'));
        Console.WriteLine($"[7-{name}] {steps} steps logged, {(File.Exists(tracePath) ? File.ReadLines(tracePath).Count() : 0)} trace lines");
        if (steps < planSteps) failures.Add($"7-{name}: {steps} steps logged of the plan's {planSteps} and more");
    }

    static System.Windows.Rect? FindExact(Process app, string text)
    {
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            foreach (AutomationElement t in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
                if (t.Current.Name.Trim() == text) return t.Current.BoundingRectangle;
        return null;
    }

    /// The Windows 11 runner opens the Start menu by itself now and then (it was open over the
    /// card in 7-show.png, and the click on the row only closed it). Closed by ending its host,
    /// not with Esc, which would close the card too; it starts again closed.
    static void CloseStartMenu(string when)
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
        string name;
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch { return; }
        if (name is not ("StartMenuExperienceHost" or "SearchHost")) return;
        Console.WriteLine($"[7-show] {name} in front {when}: closing it");
        foreach (var p in Process.GetProcessesByName(name)) { try { p.Kill(); } catch { } }
        Thread.Sleep(1000);
    }
}
