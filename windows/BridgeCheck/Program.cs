using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;

namespace Longyan;

/// Runs the lookups in scripts/bridge-check.txt through the bridge and prints each one's last
/// card (or hint), one JSON line each. Drains the core's main queue from this thread, as the
/// app does from its message loop. Usage: BridgeCheck RESOURCES LOOKUPS [MODEL]
/// With MODEL, the lookups go one at a time, each once its card has settled (the pick parity
/// step in windows.yml), and the signal check is skipped.
static class Program
{
    static readonly List<(string passage, int start, int end)> lookups = new();
    static readonly Dictionary<long, int> byID = new();
    static readonly Dictionary<int, string> last = new();
    static bool ready, failed;
    static long events;
    static Bridge.Callback? keep;

    static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        foreach (var line in File.ReadAllLines(args[1], Encoding.UTF8))
        {
            if (line.StartsWith("#") || line.Length == 0) continue;
            var p = line.Split('\t');
            lookups.Add((p[0], int.Parse(p[1]), int.Parse(p[2])));
        }
        keep = OnEvent;
        var model = args.Length > 2 ? args[2] : null;
        Bridge.ly_start(Bridge.Utf8(args[0]), model == null ? null : Bridge.Utf8(model), keep);
        var handle = Bridge._dispatch_get_main_queue_handle_4CF();
        Console.Error.WriteLine($"main queue handle: {handle}");
        using var queued = handle == IntPtr.Zero ? null : new AutoResetEvent(false) { SafeWaitHandle = new Microsoft.Win32.SafeHandles.SafeWaitHandle(handle, false) };

        var started = DateTime.Now;
        var asked = false;
        long seen = -1;
        var quietSince = DateTime.Now;
        while (true)
        {
            queued?.WaitOne(20);
            Bridge._dispatch_main_queue_callback_4CF(IntPtr.Zero);
            if (failed) return 1;
            if (model != null)
            {
                // BRIDGE_WARM=seconds: warm the model up as the app does when the eye shows or
                // the shortcut is pressed, that long before the first lookup.
                if (ready && warmAt == null && double.TryParse(Environment.GetEnvironmentVariable("BRIDGE_WARM"), out var w))
                {
                    Bridge.ly_warm_up(); warmAt = DateTime.Now.AddSeconds(w);
                }
                if (warmAt != null && DateTime.Now < warmAt) continue;
                if (ready && Next()) break;
                if ((DateTime.Now - started).TotalMinutes > 30) { Console.Error.WriteLine("timed out"); return 1; }
                continue;
            }
            if (ready && !asked)
            {
                for (var i = 0; i < lookups.Count; i++) byID[Bridge.ly_lookup(Bridge.Utf8(lookups[i].passage), lookups[i].start, lookups[i].end)] = i;
                asked = true;
            }
            if (events != seen) { seen = events; quietSince = DateTime.Now; }
            if (asked && (DateTime.Now - quietSince).TotalSeconds > 3) break;
            if ((DateTime.Now - started).TotalMinutes > 5) { Console.Error.WriteLine("timed out"); return 1; }
        }
        for (var i = 0; i < lookups.Count; i++) Console.WriteLine(last.TryGetValue(i, out var j) ? j : "{\"missing\":true}");
        if (model != null) return 0;
        return queued == null ? 0 : SignalCheck(queued);
    }

    /// The app runs the main queue only when its handle is signalled. Checked here, on stderr:
    /// no signals while idle, the same lookups again answered on signals alone, and how long
    /// ly_shutdown takes.
    static int SignalCheck(AutoResetEvent queued)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var idle = 0;
        while (clock.Elapsed.TotalSeconds < 3) if (queued.WaitOne(100)) { idle++; Bridge._dispatch_main_queue_callback_4CF(IntPtr.Zero); }
        Console.Error.WriteLine($"signal check: {idle} signals in 3 s idle");

        var first = new Dictionary<int, string>(last);
        last.Clear();
        byID.Clear();
        for (var i = 0; i < lookups.Count; i++) byID[Bridge.ly_lookup(Bridge.Utf8(lookups[i].passage), lookups[i].start, lookups[i].end)] = i;
        var drains = 0;
        clock.Restart();
        // Only on a signal: a missed one shows as a lookup left without its card.
        while (queued.WaitOne(3000)) { drains++; Bridge._dispatch_main_queue_callback_4CF(IntPtr.Zero); if (clock.Elapsed.TotalMinutes > 2) break; }
        var same = Enumerable.Range(0, lookups.Count).Count(i => first.TryGetValue(i, out var a) && last.TryGetValue(i, out var b) && WithoutID(a) == WithoutID(b));
        Console.Error.WriteLine($"signal check: {same} of {lookups.Count} lookups gave the same card on signals alone, {drains} drains");

        clock.Restart();
        Bridge.ly_shutdown();
        Console.Error.WriteLine($"signal check: ly_shutdown took {clock.Elapsed.TotalMilliseconds:F1} ms");
        return same == lookups.Count ? 0 : 1;
    }

    static int current = -1;
    static DateTime? warmAt;
    static DateTime askedAt, changedAt;
    static string? seenCard;
    static double firstMs, settledMs;

    /// Model mode: asks for the next lookup once the current card has stayed settled a while
    /// (or after 3 minutes). True when all are done.
    static bool Next()
    {
        if (current >= 0)
        {
            last.TryGetValue(current, out var json);
            if (json != seenCard) { seenCard = json; changedAt = DateTime.Now; }
            var c = json == null ? null : JsonNode.Parse(json)?["card"] as JsonObject;
            var settled = c != null && Settled(c);
            // When the card first showed, and when it last changed into a settled card.
            if (json != null && firstMs < 0) firstMs = (DateTime.Now - askedAt).TotalMilliseconds;
            if (!settled) settledMs = -1; else if (settledMs < 0) settledMs = (changedAt - askedAt).TotalMilliseconds;
            // A word card without a meaning yet may not have started its pick: wait longer.
            double quiet = c?["meaning"] != null || (string?)c?["kind"] == "phrase" ? 2 : 10;
            // BRIDGE_QUIET=seconds: a shorter wait, for long runs (the speed job's evals).
            if (double.TryParse(Environment.GetEnvironmentVariable("BRIDGE_QUIET"), out var q)) quiet = q;
            var waited = (DateTime.Now - askedAt).TotalSeconds;
            if (!(settled && (DateTime.Now - changedAt).TotalSeconds > quiet) && waited < 180) return false;
            Console.Error.WriteLine($"lookup {current}: {(settled ? "settled" : "NOT settled")} after {waited:0.0} s");
            Console.Error.WriteLine($"time: lookup {current} {(string?)c?["kind"]} first {firstMs:0} ms, settled {settledMs:0} ms");
        }
        // The card goes, as Esc closes it in the app, so its leftover work doesn't hold up the next.
        foreach (var (id, i) in byID) if (i == current) Bridge.ly_close(id);
        if (++current >= lookups.Count) return true;
        var (passage, start, end) = lookups[current];
        askedAt = changedAt = DateTime.Now; seenCard = null; firstMs = settledMs = -1;
        byID[Bridge.ly_lookup(Bridge.Utf8(passage), start, end)] = current;
        return false;
    }

    /// As UiCheck's: the model's pick in, and for a phrase its translation.
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

    static string WithoutID(string json)
    {
        if (JsonNode.Parse(json) is not JsonObject e) return json;
        e.Remove("id");
        return e.ToJsonString();
    }

    static void OnEvent(IntPtr p)
    {
        events++;
        var json = Bridge.FromUtf8(p);
        var e = JsonNode.Parse(json) as JsonObject;
        switch ((string?)e?["event"])
        {
            case "ready": ready = true; Console.Error.WriteLine(json); break;
            case "failed": failed = true; Console.Error.WriteLine(json); break;
            case "card":
            case "hint":
                if (byID.TryGetValue((long)e!["id"]!, out var i)) last[i] = json;
                break;
        }
    }
}
