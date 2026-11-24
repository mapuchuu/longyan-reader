using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Threading;

namespace Longyan;

/// The shared core, as the app sees it: start it, ask for cards, get their contents back as
/// they change. Everything here runs on the app's main thread, which also runs the core's
/// main actor: work the core queues there is run from this thread's message loop.
sealed class Core
{
    public static readonly Core Shared = new();

    public event Action<string>? Ready;        // the model's status: "ready", or why not
    public event Action<string>? Failed;
    public event Action<string>? ModelChanged;
    readonly Dictionary<long, Action<JsonObject>> cardHandlers = new();
    readonly Dictionary<long, Action<string>> hintHandlers = new();
    /// The core has answered: the dictionary loaded, or it failed (then `StartError` says why,
    /// and lookups get a hint saying so).
    public bool IsReady { get; private set; }
    public string? StartError { get; private set; }

    // Kept alive for as long as the bridge may call it.
    readonly Bridge.Callback callback;
    WaitHandle? queued;
    RegisteredWaitHandle? waiting;
    DispatcherTimer? backup, stats;
    bool stopped;
    // How often the main queue was run, and why: for the log and the UI check.
    long signalled, polled, caught;
    readonly System.Diagnostics.Stopwatch quiet = new();
    bool inPoll;

    Core() { callback = OnEvent; }

    public static string AppDirectory => AppContext.BaseDirectory;
    public static string ResourcesDirectory => Path.Combine(AppDirectory, "Resources");

    /// Where the reading model lives: %LOCALAPPDATA%\LongyanReader\models.
    public static string ModelsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "models");
    public const string ModelFileName = "qwen3.5-4b-q4_k_m.gguf";
    public static string ModelPath => Path.Combine(ModelsDirectory, ModelFileName);

    /// `withModel` false: the dictionary only (--show, which never asks the model).
    public void Start(bool withModel = true)
    {
        Bridge.ly_start(Bridge.Utf8(ResourcesDirectory), withModel ? Bridge.Utf8(ModelPath) : null, callback);
        StartDraining();
    }

    /// Runs the core's main-queue work from the WPF message loop when dispatch signals that work
    /// is waiting. On Windows the main queue's handle is an auto-reset event that libdispatch
    /// sets each time work is queued on an empty main queue, and again after a drain that left
    /// work behind, so nothing runs while the app is idle. In case a signal is ever missed, a
    /// slower backup timer runs too, but only for a few seconds after the app last asked the
    /// core for something or heard from it; the log counts what it caught.
    void StartDraining()
    {
        var app = Dispatcher.CurrentDispatcher;
        var handle = Bridge._dispatch_get_main_queue_handle_4CF();
        if (handle != IntPtr.Zero)
        {
            queued = new AutoResetEvent(false) { SafeWaitHandle = new Microsoft.Win32.SafeHandles.SafeWaitHandle(handle, false) };
            waiting = ThreadPool.RegisterWaitForSingleObject(queued, (_, _) => app.BeginInvoke(() => { signalled++; Drain(); }), null, Timeout.Infinite, false);
        }
        // Without the handle, the timer is all there is, so it never stops.
        backup = new DispatcherTimer(TimeSpan.FromMilliseconds(handle != IntPtr.Zero ? 250 : 15), DispatcherPriority.Background, (_, _) =>
        {
            if (handle != IntPtr.Zero && IsReady && quiet.Elapsed.TotalSeconds > 5) { backup!.Stop(); return; }
            polled++;
            inPoll = true;
            Drain();
            inPoll = false;
        }, app);
        Busy();
        if (Logging)
        {
            // Every 10 s, how many times the queue ran: the UI check's idle wakeups.
            stats = new DispatcherTimer(TimeSpan.FromSeconds(10), DispatcherPriority.Background, (_, _) => LogStats(), app);
            stats.Start();
        }
    }

    void Drain()
    {
        if (!stopped) Bridge._dispatch_main_queue_callback_4CF(IntPtr.Zero);
    }

    /// Runs the core's work for something the card just asked for now, in the same turn of the
    /// message loop, so its answer is drawn on the next frame. Waiting for the queue's signal
    /// (a thread-pool wake, then a queued dispatcher call) cost tens of ms before a pick showed.
    /// A few rounds, for work that queues more work (the state change, then its event).
    public void DrainNow()
    {
        for (var i = 0; i < 3 && !stopped; i++) Drain();
    }

    /// The app asked the core for something, or heard from it: keep the backup timer going.
    void Busy()
    {
        quiet.Restart();
        if (backup != null && !backup.IsEnabled && !stopped) backup.Start();
    }

    long lastSignalled, lastPolled, lastCaught;
    void LogStats()
    {
        Log($"{{\"event\":\"drain\",\"signalled\":{signalled - lastSignalled},\"polled\":{polled - lastPolled},\"caught\":{caught - lastCaught},\"seconds\":10}}");
        lastSignalled = signalled; lastPolled = polled; lastCaught = caught;
    }

    /// For the log at exit.
    public string DrainSummary => $"main queue ran {signalled} times on its signal, {polled} on the backup timer; the timer caught {caught} events";

    /// Exit: no more draining. The bridge's last work is dropped.
    public void Stop()
    {
        stopped = true;
        waiting?.Unregister(null);
        backup?.Stop();
        stats?.Stop();
    }

    /// LONGYAN_CARD_LOG=file: every event from the core, one JSON line each (for the UI check).
    static readonly string? eventLog = Environment.GetEnvironmentVariable("LONGYAN_CARD_LOG");
    static readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();

    /// One line of the event log, stamped with the milliseconds since the app started.
    public static void Log(string json)
    {
        if (eventLog == null || json.Length < 2) return;
        try { File.AppendAllText(eventLog, "{\"t\":" + clock.ElapsedMilliseconds + ",\"k\":" + Environment.TickCount64 + "," + json.Substring(1) + "\n"); } catch { }
    }
    public static bool Logging => eventLog != null;

    // Called from native code: an exception must not get past it.
    void OnEvent(IntPtr json)
    {
        try { Handle(Bridge.FromUtf8(json)); }
        catch (Exception e) { Diagnostics.Write("error handling an event from the core: " + Diagnostics.Describe(e)); }
    }

    void Handle(string text)
    {
        Log(text);
        if (inPoll) caught++;
        Busy();
        JsonObject? e;
        try { e = JsonNode.Parse(text) as JsonObject; } catch { return; }
        if (e == null) return;
        switch ((string?)e["event"])
        {
            case "ready":
                IsReady = true;
                Diagnostics.Write($"dictionary loaded, {e["entries"]} entries; reading model: {e["model"]}");
                Ready?.Invoke((string?)e["model"] ?? "");
                break;
            case "failed":
                IsReady = true;
                StartError = (string?)e["message"] ?? "";
                Diagnostics.Write("the dictionary didn't load: " + StartError);
                Failed?.Invoke(StartError);
                break;
            case "model":
                Diagnostics.Write($"reading model: {e["model"]}");
                ModelChanged?.Invoke((string?)e["model"] ?? "");
                break;
            case "gpu":
                Gpu.OnEvent(e);
                break;
            case "card":
                if (e["card"] is JsonObject card && cardHandlers.TryGetValue((long)e["id"]!, out var onCard)) onCard(card);
                break;
            case "hint":
                if (hintHandlers.TryGetValue((long)e["id"]!, out var onHint)) onHint((string?)e["message"] ?? "");
                break;
        }
    }

    /// Opens a card for passage[start..end] (UTF-16 offsets). `onCard` gets its contents now
    /// and on every change; `onHint` instead when there's nothing to show.
    public long Lookup(string passage, int start, int end, Action<JsonObject> onCard, Action<string> onHint)
    {
        Busy();
        var id = Bridge.ly_lookup(Bridge.Utf8(passage), start, end);
        // The bridge answers on a later turn of this thread's loop, so these are in place first.
        cardHandlers[id] = onCard;
        hintHandlers[id] = onHint;
        return id;
    }

    /// Starts a card's work before the reader clicks: call it when the selection button appears.
    public void Prepare(string passage, int start, int end) { Busy(); Bridge.ly_prepare(Bridge.Utf8(passage), start, end); }
    public void CancelPrepare() { Busy(); Bridge.ly_cancel_prepare(); }

    /// Dev only (--show): a card built from a saved card JSON instead of a lookup. It answers
    /// as a lookup's card does, but never asks the model (Sources/LongyanCore/CardFixture.swift).
    public long Fixture(string json, Action<JsonObject> onCard, Action<string> onHint)
    {
        Busy();
        var id = Bridge.ly_fixture(Bridge.Utf8(json));
        cardHandlers[id] = onCard;
        hintHandlers[id] = onHint;
        return id;
    }

    public long OpenPartOf(long id, Action<JsonObject> onCard, Action<string> onHint)
    {
        Busy();
        var next = Bridge.ly_open_part_of(id);
        cardHandlers[next] = onCard;
        hintHandlers[next] = onHint;
        return next;
    }

    public void Close(long id)
    {
        cardHandlers.Remove(id);
        hintHandlers.Remove(id);
        if (stopped) return;
        Busy();
        Bridge.ly_close(id);
    }

    public void RefreshModel() { Busy(); Bridge.ly_refresh(Bridge.Utf8(ModelPath)); }

    /// Quitting: frees the model on another thread, waiting at most `timeout` (a first load can't
    /// be stopped part way). True when it finished.
    public static bool Shutdown(TimeSpan timeout)
    {
        var done = System.Threading.Tasks.Task.Run(() =>
        {
            try { Bridge.ly_shutdown(); }
            catch (Exception e) { Diagnostics.Write("shutdown: " + e.Message); }
        });
        return done.Wait(timeout);
    }
}
