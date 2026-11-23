using System;
using System.Collections.Generic;
using System.IO;
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
        return 0;
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
