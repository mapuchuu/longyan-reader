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
        var show = Process.Start(start)!;
        try
        {
            var waited = Stopwatch.StartNew();
            System.Windows.Rect? row = null;
            while (waited.Elapsed.TotalSeconds < 40 && !show.HasExited && (row = FindText(show, "明朝")) == null) Thread.Sleep(250);
            if (row is not System.Windows.Rect r) { failures.Add("7-show: no card in 40 s" + (show.HasExited ? $" (exited {show.ExitCode})" : "")); Shot("7-show-none"); return; }
            Thread.Sleep(600);
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

    static System.Windows.Rect? FindExact(Process app, string text)
    {
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            foreach (AutomationElement t in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
                if (t.Current.Name.Trim() == text) return t.Current.BoundingRectangle;
        return null;
    }
}
