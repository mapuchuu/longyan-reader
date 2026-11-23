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
///
/// With MODEL, the reading model is used: the lookups go one at a time, each until its card has
/// settled (or LONGYAN_CHECK_MINUTES, default 4), and stderr gets the model's status, each
/// card's times and the peak memory.
static class Program
{
    static string modelStatus = "";
    static AutoResetEvent? queued;

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
        if (args.Length >= 3) return WithModel(args[0], args[2]);
        Bridge.ly_start(Bridge.Utf8(args[0]), null, keep);
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

    static int WithModel(string resources, string model)
    {
        Bridge.ly_start(Bridge.Utf8(resources), Bridge.Utf8(model), keep!);
        var handle = Bridge._dispatch_get_main_queue_handle_4CF();
        queued = handle == IntPtr.Zero ? null : new AutoResetEvent(false) { SafeWaitHandle = new Microsoft.Win32.SafeHandles.SafeWaitHandle(handle, false) };
        var limit = TimeSpan.FromMinutes(double.TryParse(Environment.GetEnvironmentVariable("LONGYAN_CHECK_MINUTES"), out var m) ? m : 4);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (!ready)
        {
            Pump();
            if (failed) return 1;
            if (clock.Elapsed.TotalMinutes > 2) { Console.Error.WriteLine("timed out loading the dictionary"); return 1; }
        }
        // A "model" event sent with "ready" comes just after it.
        clock.Restart();
        while (clock.Elapsed.TotalSeconds < 1) Pump();
        Console.Error.WriteLine($"model at start: {modelStatus}");
        var all = true;
        for (var i = 0; i < lookups.Count; i++)
        {
            // As the app does when the shortcut is pressed.
            Bridge.ly_warm_up();
            var t = System.Diagnostics.Stopwatch.StartNew();
            byID[Bridge.ly_lookup(Bridge.Utf8(lookups[i].passage), lookups[i].start, lookups[i].end)] = i;
            double? first = null, settled = null;
            while (t.Elapsed < limit)
            {
                Pump();
                if (!last.TryGetValue(i, out var json)) continue;
                first ??= t.Elapsed.TotalSeconds;
                if (Settled(json)) { settled = t.Elapsed.TotalSeconds; break; }
            }
            all &= settled != null;
            Console.Error.WriteLine(FormattableString.Invariant(
                $"card {i + 1}: first {(first is double f ? f.ToString("F1") + " s" : "never")}, settled {(settled is double s ? s.ToString("F1") + " s" : "not in " + limit.TotalMinutes + " min")}, {Describe(last.GetValueOrDefault(i))}"));
        }
        for (var i = 0; i < lookups.Count; i++) Console.WriteLine(last.TryGetValue(i, out var j) ? j : "{\"missing\":true}");
        Console.Error.WriteLine($"model at end: {modelStatus}");
        using var me = System.Diagnostics.Process.GetCurrentProcess();
        Console.Error.WriteLine($"peak memory: {me.PeakWorkingSet64 / 1_000_000} MB");
        Bridge.ly_shutdown();
        return all ? 0 : 1;
    }

    static void Pump()
    {
        if (queued != null) queued.WaitOne(20); else Thread.Sleep(20);
        Bridge._dispatch_main_queue_callback_4CF(IntPtr.Zero);
    }

    /// The model has nothing more to add: a word card's pick is in (or it isn't waiting for one),
    /// a phrase card has its translation and every row's meaning.
    static bool Settled(string json)
    {
        if (JsonNode.Parse(json) is not JsonObject e || e["card"] is not JsonObject card) return true;
        if ((string?)card["kind"] == "word") return (string?)card["status"] != "Reading the sentence…";
        var rows = card["rows"] as JsonArray ?? new JsonArray();
        return (card["translation"] != null || card["translationError"] != null)
            && !rows.OfType<JsonObject>().Any(r => r["pending"] is JsonValue v && v.TryGetValue<bool>(out var p) && p);
    }

    static string Describe(string? json)
    {
        if (json == null || JsonNode.Parse(json) is not JsonObject e) return "no card";
        if (e["card"] is not JsonObject card) return "hint: " + (string?)e["message"];
        if ((string?)card["kind"] == "word")
            return $"word {(string?)card["word"]}: " + ((string?)card["status"] ?? "picked") + (card["meaning"] is JsonNode mm ? $" ({(string?)mm})" : "");
        return $"phrase: " + ((string?)card["translation"] ?? (string?)card["translationError"] ?? "no translation");
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
            case "ready": ready = true; modelStatus = (string?)e!["model"] ?? ""; Console.Error.WriteLine(json); break;
            case "model": modelStatus = (string?)e!["model"] ?? ""; Console.Error.WriteLine(json); break;
            case "failed": failed = true; Console.Error.WriteLine(json); break;
            case "card":
            case "hint":
                if (byID.TryGetValue((long)e!["id"]!, out var i)) last[i] = json;
                break;
        }
    }
}
