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
    public bool IsReady { get; private set; }

    // Kept alive for as long as the bridge may call it.
    readonly Bridge.Callback callback;
    WaitHandle? queued;
    DispatcherTimer? timer;

    Core() { callback = OnEvent; }

    public static string AppDirectory => AppContext.BaseDirectory;
    public static string ResourcesDirectory => Path.Combine(AppDirectory, "Resources");

    /// Where the reading model lives: %LOCALAPPDATA%\LongyanReader\models.
    public static string ModelsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "models");
    public const string ModelFileName = "qwen3.5-4b-q4_k_m.gguf";
    public static string ModelPath => Path.Combine(ModelsDirectory, ModelFileName);

    public void Start()
    {
        Bridge.ly_start(Bridge.Utf8(ResourcesDirectory), Bridge.Utf8(ModelPath), callback);
        StartDraining();
    }

    /// Runs the core's main-queue work from the WPF message loop: when dispatch signals that
    /// work is waiting, and on a short timer in case a signal is missed.
    void StartDraining()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var handle = Bridge._dispatch_get_main_queue_handle_4CF();
        if (handle != IntPtr.Zero)
        {
            queued = new AutoResetEvent(false) { SafeWaitHandle = new Microsoft.Win32.SafeHandles.SafeWaitHandle(handle, false) };
            ThreadPool.RegisterWaitForSingleObject(queued, (_, _) => dispatcher.BeginInvoke(Drain), null, Timeout.Infinite, false);
        }
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(15), DispatcherPriority.Background, (_, _) => Drain(), dispatcher);
        timer.Start();
    }

    static void Drain() => Bridge._dispatch_main_queue_callback_4CF(IntPtr.Zero);

    void OnEvent(IntPtr json)
    {
        JsonObject? e;
        try { e = JsonNode.Parse(Bridge.FromUtf8(json)) as JsonObject; } catch { return; }
        if (e == null) return;
        switch ((string?)e["event"])
        {
            case "ready":
                IsReady = true;
                Ready?.Invoke((string?)e["model"] ?? "");
                break;
            case "failed":
                Failed?.Invoke((string?)e["message"] ?? "");
                break;
            case "model":
                ModelChanged?.Invoke((string?)e["model"] ?? "");
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
        var id = Bridge.ly_lookup(Bridge.Utf8(passage), start, end);
        // The bridge answers on a later turn of this thread's loop, so these are in place first.
        cardHandlers[id] = onCard;
        hintHandlers[id] = onHint;
        return id;
    }

    public long OpenPartOf(long id, Action<JsonObject> onCard, Action<string> onHint)
    {
        var next = Bridge.ly_open_part_of(id);
        cardHandlers[next] = onCard;
        hintHandlers[next] = onHint;
        return next;
    }

    public void Close(long id)
    {
        cardHandlers.Remove(id);
        hintHandlers.Remove(id);
        Bridge.ly_close(id);
    }

    public void RefreshModel() => Bridge.ly_refresh(Bridge.Utf8(ModelPath));
}
