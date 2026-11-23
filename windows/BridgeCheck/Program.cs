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
/// app does from its message loop. Usage: BridgeCheck RESOURCES LOOKUPS
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
