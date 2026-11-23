using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Longyan;

/// Downloads the reading model, the same file, hosts and checksum as the Mac app
/// (Sources/LongyanReader/ModelDownloader.swift), into %LOCALAPPDATA%\LongyanReader\models.
///
/// As on the Mac, the file comes in 32 MB pieces over 8 connections at once. A piece slower
/// than 50 KB/s over 20 seconds is asked for again on a new connection; one that gets nothing
/// at all in that time counts as a failure of its host. Three failures on the host in use and
/// the next host is tried; after every host has failed three rounds in a row the download
/// stops and says why. While Windows says there's no network nothing counts: the pieces wait.
/// Finished pieces are listed in a file beside the download (the .pieces file, the Mac's
/// format), with how far each unfinished one got, so a stop, an exit or a restart costs at most
/// a few seconds of data. Only replies with the right byte range are written, so a captive
/// portal's page can't spoil the file. The system's proxy is used, with the user's sign-in.
///
/// The tray, the welcome window and Settings all show its state (Changed, on the app's thread).
static class ModelDownload
{
    /// LONGYAN_DOWNLOAD_TEST=folder: fetch Qwen 3.5 0.8B (0.5 GB) into that folder instead, as
    /// on the Mac, to try the downloader without touching the real model.
    static readonly string? testFolder = Environment.GetEnvironmentVariable("LONGYAN_DOWNLOAD_TEST") is { Length: > 0 } t ? t : null;
    static readonly string FilePath = testFolder == null
        ? "unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf"
        : "unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf";
    /// hf-mirror.com first (reachable from mainland China), then huggingface.co.
    /// LONGYAN_DOWNLOAD_HOSTS=a,b replaces them, to test failing hosts (the first-run check).
    static readonly string[] Hosts = Environment.GetEnvironmentVariable("LONGYAN_DOWNLOAD_HOSTS")?
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) is { Length: > 0 } h
        ? h : new[] { "https://hf-mirror.com/", "https://huggingface.co/" };
    public static readonly long Size = testFolder == null ? 2_740_937_888 : 532_517_120;
    static readonly string Sha256 = testFolder == null
        ? "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
        : "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517";

    const long PieceSize = 32L << 20;
    static int PieceCount => (int)((Size + PieceSize - 1) / PieceSize);
    const int Connections = 8;
    const double StallRate = 50_000;
    static readonly TimeSpan StallWindow = TimeSpan.FromSeconds(20);

    static string Folder => testFolder ?? Core.ModelsDirectory;
    static string Target => Path.Combine(Folder, Core.ModelFileName);
    static string Partial => Target + ".part";
    /// The pieces already in the .part file, one number per line; an unfinished one has its
    /// next byte after the number.
    static string Ledger => Target + ".pieces";

    public static bool Running { get; private set; }
    /// Checking a downloaded file's checksum.
    public static bool Checking { get; private set; }
    /// Windows says there's no network: the download waits for it.
    public static bool WaitingForNetwork { get; private set; }
    /// 0 to 1 while running.
    public static double Progress { get; private set; }
    /// Why the last download failed, until the next one starts ("stopped" when cancelled).
    public static string? LastError { get; set; }
    /// When the last one stopped for disk space: "needs 3.7 GB free and the disk has 1.2 GB".
    public static string? SpaceShort { get; private set; }
    /// "About 4 minutes left", once the download has run long enough to tell.
    public static string? TimeLeft { get; private set; }
    public static event Action? Changed;
    static CancellationTokenSource? cancel;
    static (DateTime At, double Progress)? rateStart;

    /// The core said this PC is too slow for the model ("too-slow"): no 2.7 GB download then.
    public static bool TooSlow { get; set; }

    public static bool IsDownloaded => File.Exists(Target) && new FileInfo(Target).Length == Size;

    /// Bytes of the model on disk: the file, or what's downloaded of it so far.
    public static long OnDisk
    {
        get
        {
            try { return File.Exists(Target) ? new FileInfo(Target).Length : File.Exists(Partial) ? Have(LoadLedger()) : 0; }
            catch { return 0; }
        }
    }

    public static void Notify() => Changed?.Invoke();

    /// The task ends with null, or why it failed. Call it from the app's thread.
    public static async Task<string?> Run()
    {
        if (Running) return null;
        if (TooSlow) return "this PC is too slow for the reading model";
        Running = true;
        Progress = (double)OnDisk / Size;
        LastError = null;
        SpaceShort = null;
        TimeLeft = null;
        WaitingForNetwork = false;
        rateStart = null;
        cancel = new CancellationTokenSource();
        var token = cancel.Token;
        var ui = SynchronizationContext.Current;
        void OnUi(Action a) { if (ui != null) ui.Post(_ => a(), null); else a(); }
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var startedWith = OnDisk;
        Diagnostics.Write(FormattableString.Invariant($"model download: starting with {startedWith / 1e6:F0} MB on disk, from {HostName(0)}"));
        Notify();
        string? error;
        try
        {
            error = await Task.Run(() => Download(token,
                p => OnUi(() => { if (!Running || Checking) return; Progress = p; Estimate(p); Notify(); }),
                w => OnUi(() => { WaitingForNetwork = w; if (w) rateStart = null; Notify(); })));
            if (error == null)
            {
                Checking = true;
                WaitingForNetwork = false;
                Progress = 1;
                Notify();
                var fetched = (Size - startedWith) / 1e6;
                Diagnostics.Write(FormattableString.Invariant($"model download: {fetched:F0} MB in {clock.Elapsed.TotalSeconds:F0} s, checking it"));
                error = await Task.Run(Finish);
            }
        }
        catch (OperationCanceledException) { error = "stopped"; }
        catch (Exception e) { error = Plain(e.Message); }
        finally { Running = false; Checking = false; WaitingForNetwork = false; TimeLeft = null; }
        if (error != null) Diagnostics.Write("model download: " + error);
        LastError = error;
        Notify();
        return error;
    }

    public static void Stop() => cancel?.Cancel();

    /// Why the disk can't take the rest of the download, or null. Asks for what's left to
    /// fetch plus 1 GB, so the download doesn't leave the disk full, as on the Mac.
    public static string? SpaceProblem()
    {
        try
        {
            var have = File.Exists(Partial) ? Have(LoadLedger()) : 0;
            var need = Math.Max(0, Size - have) + 1_000_000_000;
            var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Folder))!).AvailableFreeSpace;
            return free >= need ? null : $"needs {Gigabytes(need)} free and the disk has {Gigabytes(free)}";
        }
        catch { return null; }
    }

    static async Task<string?> Download(CancellationToken token, Action<double> progress, Action<bool> waiting)
    {
        Directory.CreateDirectory(Folder);
        if (SpaceProblem() is string space) { SpaceShort = space; return "there isn't enough disk space"; }
        if (!File.Exists(Partial))
        {
            File.Create(Partial).Dispose();
            File.Delete(Ledger);
        }
        var job = new Job(token, progress, waiting);
        return await job.Run();
    }

    /// The whole file is here: keep it if its checksum is the Mac's.
    static async Task<string?> Finish()
    {
        if (!await Matches(Partial))
        {
            // A damaged file can't be resumed into a good one.
            File.Delete(Partial);
            File.Delete(Ledger);
            return "the file was damaged";
        }
        File.Move(Partial, Target, true);
        File.Delete(Ledger);
        Diagnostics.Write("model download: the file is the right one");
        return null;
    }

    static void Estimate(double p)
    {
        if (rateStart is not (DateTime at, double from)) { rateStart = (DateTime.Now, p); return; }
        var elapsed = (DateTime.Now - at).TotalSeconds;
        if (elapsed < 5 || p <= from) return;
        var seconds = (1 - p) * elapsed / (p - from);
        TimeLeft = seconds < 60 ? "Less than a minute left"
            : seconds < 90 ? "About a minute left"
            : seconds < 3600 ? $"About {Math.Round(seconds / 60):0} minutes left"
            : $"About {seconds / 3600:0.#} hours left";
    }

    /// Whether the downloaded file is the right one: a file that won't load may just be damaged.
    public static async Task<bool> Verify()
    {
        Checking = true;
        Notify();
        try { return await Task.Run(() => Matches(Target)); }
        finally { Checking = false; Notify(); }
    }

    static async Task<bool> Matches(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.SequentialScan | FileOptions.Asynchronous);
        var hash = await SHA256.HashDataAsync(stream);
        return Convert.ToHexString(hash).Equals(Sha256, StringComparison.OrdinalIgnoreCase);
    }

    /// "1.2 GB"
    public static string Gigabytes(long bytes) => $"{bytes / 1e9:0.0} GB";

    /// A system error inside a sentence: "The operation timed out." → "the operation timed out".
    static string Plain(string s)
    {
        s = s.Trim();
        if (s.EndsWith('.')) s = s[..^1];
        return s.Length == 0 ? "something went wrong" : char.ToLowerInvariant(s[0]) + s[1..];
    }

    // MARK: pieces

    static long PieceStart(int i) => i * PieceSize;
    static long PieceEnd(int i) => Math.Min(Size, PieceStart(i) + PieceSize) - 1;   // inclusive

    static (HashSet<int> Finished, Dictionary<int, long> Started) LoadLedger()
    {
        var done = new HashSet<int>();
        var part = new Dictionary<int, long>();
        try
        {
            if (File.Exists(Ledger))
            {
                foreach (var line in File.ReadAllLines(Ledger))
                {
                    var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (f.Length == 0 || !int.TryParse(f[0], out var i) || i < 0 || i >= PieceCount) continue;
                    if (f.Length > 1 && long.TryParse(f[1], out var n)) part[i] = Math.Clamp(n, PieceStart(i), PieceEnd(i) + 1);
                    else done.Add(i);
                }
                foreach (var i in done) part.Remove(i);
                return (done, part);
            }
            // A .part file from the one-connection downloader: its whole pieces are good.
            var have = File.Exists(Partial) ? new FileInfo(Partial).Length : 0;
            for (var i = 0; i < Math.Min(have, Size) / PieceSize; i++) done.Add(i);
        }
        catch { }
        return (done, part);
    }

    static long Have((HashSet<int> Finished, Dictionary<int, long> Started) l) =>
        l.Finished.Sum(i => PieceEnd(i) - PieceStart(i) + 1) + l.Started.Sum(kv => kv.Value - PieceStart(kv.Key));

    static string HostName(int h) => Uri.TryCreate(Hosts[h], UriKind.Absolute, out var u) ? u.Host : Hosts[h];

    static bool Online()
    {
        try { return NetworkInterface.GetIsNetworkAvailable(); } catch { return true; }
    }

    /// One piece being fetched: its byte range, how far it has got, and its request.
    sealed class Piece
    {
        public readonly int Index;
        public readonly long Start, End;   // inclusive
        public long Next;                  // the next byte to write
        public int Host;
        public DateTime WindowStart;
        public long WindowBytes;
        public CancellationTokenSource? Request;
        public bool Slow;                  // dropped for crawling, not for silence
        public Piece(int i, long? from)
        {
            Index = i;
            Start = PieceStart(i);
            End = PieceEnd(i);
            Next = Math.Clamp(from ?? Start, Start, End + 1);
        }
        public bool Done => Next > End;
    }

    /// One run of the download, from the ledger to every piece in (or a stop, or giving up).
    sealed class Job
    {
        readonly object gate = new();
        readonly CancellationToken user;
        readonly CancellationTokenSource stop;
        readonly Action<double> progress;
        readonly Action<bool> waiting;
        HashSet<int> finished = new();
        Dictionary<int, long> started = new();
        readonly Queue<int> queue = new();
        readonly Dictionary<int, Piece> active = new();
        int host, hostFailures, rounds;
        string? failure, lastProblem;
        SafeFileHandle? file;
        HttpClient? http;
        DateTime lastReport;
        bool offline;

        public Job(CancellationToken token, Action<double> progress, Action<bool> waiting)
        {
            user = token;
            stop = CancellationTokenSource.CreateLinkedTokenSource(token);
            this.progress = progress;
            this.waiting = waiting;
        }

        public async Task<string?> Run()
        {
            (finished, started) = LoadLedger();
            // Listed at once (even if empty): pieces land anywhere in the file, so its size no
            // longer says how much of it is good.
            WriteLedger(Lines());
            if (finished.Count == PieceCount) return null;
            try { file = File.OpenHandle(Partial, FileMode.Open, FileAccess.Write, FileShare.Read); }
            catch (Exception e)
            {
                Diagnostics.Write("model download: can't open the file: " + e.Message);
                return $"can't write to {Folder}";
            }
            // Unfinished pieces first, so their bytes are kept.
            foreach (var i in Enumerable.Range(0, PieceCount).Where(i => !finished.Contains(i)).OrderBy(i => started.ContainsKey(i) ? 0 : 1).ThenBy(i => i))
                queue.Enqueue(i);
            var handler = new SocketsHttpHandler
            {
                // Each piece on its own connection (HTTP/1.1), not streams sharing one, which crawl together.
                MaxConnectionsPerServer = Connections * 2,
                ConnectTimeout = TimeSpan.FromSeconds(30),
                PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
                AutomaticDecompression = DecompressionMethods.None,
                DefaultProxyCredentials = CredentialCache.DefaultCredentials,
            };
            http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("LongyanReader-Windows");
            Report(force: true);
            var watch = Watch();
            try { await Task.WhenAll(Enumerable.Range(0, Connections).Select(_ => Worker())); }
            finally
            {
                stop.Cancel();
                try { await watch; } catch (OperationCanceledException) { }
                SaveLedger();
                file.Dispose();
                http.Dispose();
            }
            if (failure != null) return failure;
            user.ThrowIfCancellationRequested();
            return finished.Count == PieceCount ? null : lastProblem ?? "the download stopped early";
        }

        async Task Worker()
        {
            while (true)
            {
                Piece p;
                lock (gate)
                {
                    if (stop.IsCancellationRequested || queue.Count == 0) return;
                    var i = queue.Dequeue();
                    p = new Piece(i, started.Remove(i, out var from) ? from : null);
                    active[i] = p;
                }
                await Fetch(p);
                lock (gate)
                {
                    active.Remove(p.Index);
                    if (p.Done) finished.Add(p.Index);
                    else if (p.Next > p.Start) started[p.Index] = p.Next;   // stopped: kept for the next run
                }
                if (p.Done) { SaveLedger(); Report(force: true); }
            }
        }

        /// Fetches what's left of the piece, on a new connection each try, until it's in or the
        /// job stops.
        async Task Fetch(Piece p)
        {
            var buffer = new byte[256 << 10];
            while (!p.Done && !stop.IsCancellationRequested)
            {
                if (!await WaitForNetwork()) return;
                using var request = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                lock (gate)
                {
                    p.Host = host;
                    p.WindowStart = DateTime.UtcNow;
                    p.WindowBytes = 0;
                    p.Slow = false;
                    p.Request = request;
                }
                string? problem = null;
                try
                {
                    using var message = new HttpRequestMessage(HttpMethod.Get, Hosts[p.Host] + FilePath);
                    message.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(p.Next, p.End);
                    using var response = await http!.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, request.Token);
                    var code = (int)response.StatusCode;
                    var range = response.Content.Headers.ContentRange;
                    // Only the model itself goes in the file: a captive portal's page or an error
                    // page sent as 200 would spoil the download.
                    if (code == 206 && range is { HasRange: true } && range.From == p.Next && range.To == p.End && (!range.HasLength || range.Length == Size))
                    {
                        using var input = await response.Content.ReadAsStreamAsync(request.Token);
                        while (!p.Done)
                        {
                            var n = await input.ReadAsync(buffer, request.Token);
                            if (n == 0) break;
                            n = (int)Math.Min(n, p.End - p.Next + 1);
                            try { RandomAccess.Write(file!, buffer.AsSpan(0, n), p.Next); }
                            catch (IOException e)
                            {
                                var space = SpaceProblem();
                                lock (gate)
                                {
                                    if (space != null) SpaceShort = space;
                                    failure ??= space != null ? "there isn't enough disk space" : Plain(e.Message);
                                }
                                stop.Cancel();
                                return;
                            }
                            lock (gate) { p.Next += n; p.WindowBytes += n; hostFailures = 0; rounds = 0; }
                            Report();
                        }
                        if (p.Done) return;
                        problem = "the connection closed early";
                    }
                    else problem = code is 200 or 206 ? "the server sent something other than the model" : $"the server returned error {code}";
                }
                catch (OperationCanceledException) when (!stop.IsCancellationRequested)
                {
                    // The watchdog dropped it: crawling, so ask again at once; or silent, a failure.
                    if (p.Slow) continue;
                    problem = $"{HostName(p.Host)} didn't answer";
                }
                catch (OperationCanceledException) { return; }
                catch (HttpRequestException e) { problem = Describe(e, p.Host); }
                catch (IOException) { problem = "the connection closed early"; }
                finally { lock (gate) p.Request = null; }
                if (stop.IsCancellationRequested) return;
                if (Retry(p, problem!) is not TimeSpan pause) return;
                try { await Task.Delay(pause, stop.Token); } catch (OperationCanceledException) { return; }
            }
        }

        static string Describe(HttpRequestException e, int h) => e.HttpRequestError switch
        {
            HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError => $"couldn't reach {HostName(h)}",
            HttpRequestError.SecureConnectionError => $"the secure connection to {HostName(h)} failed",
            HttpRequestError.ProxyTunnelError => "the proxy refused the connection",
            HttpRequestError.ResponseEnded => "the connection closed early",
            _ => Plain(e.Message),
        };

        /// A piece that went wrong: how long to wait before asking again, or null to give up.
        TimeSpan? Retry(Piece p, string problem)
        {
            lock (gate)
            {
                lastProblem = problem;
                // Offline, every request fails at once: the next try waits for the network instead.
                if (!Online()) return TimeSpan.Zero;
                // A failure on a host already left behind says nothing about the one in use.
                if (p.Host == host && ++hostFailures >= 3)
                {
                    hostFailures = 0;
                    host = (host + 1) % Hosts.Length;
                    if (host == 0) rounds++;
                    Diagnostics.Write($"model download: {problem}; trying {HostName(host)}");
                }
                if (rounds >= 3)
                {
                    failure ??= problem;
                    stop.Cancel();
                    return null;
                }
                // A pause, so a host that's down isn't asked many times a second, and longer each
                // round, so a network that drops for a minute doesn't end the download.
                return TimeSpan.FromSeconds(new[] { 1, 10, 30 }[rounds]);
            }
        }

        /// False when the job stopped while waiting.
        async Task<bool> WaitForNetwork()
        {
            if (Online()) return true;
            lock (gate) { if (!offline) { offline = true; waiting(true); } }
            while (!Online())
            {
                try { await Task.Delay(2000, stop.Token); } catch (OperationCanceledException) { return false; }
            }
            lock (gate)
            {
                // Back online: a fresh start for every host.
                if (offline) { offline = false; hostFailures = 0; rounds = 0; waiting(false); }
            }
            return true;
        }

        /// Every 5 seconds: the ledger saved, and pieces that stalled dropped.
        async Task Watch()
        {
            while (true)
            {
                await Task.Delay(5000, stop.Token);
                SaveLedger();
                if (!Online()) continue;
                var now = DateTime.UtcNow;
                lock (gate)
                {
                    foreach (var p in active.Values)
                    {
                        if (p.Request == null || now - p.WindowStart < StallWindow) continue;
                        var rate = p.WindowBytes / (now - p.WindowStart).TotalSeconds;
                        if (p.WindowBytes == 0) { p.Slow = false; p.Request.Cancel(); }
                        else if (rate < StallRate) { p.Slow = true; p.Request.Cancel(); }
                        else { p.WindowStart = now; p.WindowBytes = 0; }
                    }
                }
            }
        }

        void Report(bool force = false)
        {
            double shown;
            lock (gate)
            {
                var now = DateTime.UtcNow;
                if (!force && (now - lastReport).TotalMilliseconds < 250) return;
                lastReport = now;
                var whole = finished.Sum(i => PieceEnd(i) - PieceStart(i) + 1);
                var inFlight = active.Values.Sum(p => p.Next - p.Start) + started.Sum(kv => kv.Value - PieceStart(kv.Key));
                shown = (double)(whole + inFlight) / Size;
            }
            progress(shown);
        }

        List<string> Lines()
        {
            lock (gate)
            {
                return finished.OrderBy(i => i).Select(i => i.ToString())
                    .Concat(active.Values.Where(p => p.Done).Select(p => p.Index.ToString()))
                    .Concat(active.Values.Where(p => !p.Done && p.Next > p.Start).Select(p => $"{p.Index} {p.Next}"))
                    .Concat(started.Select(kv => $"{kv.Key} {kv.Value}"))
                    .ToList();
            }
        }

        /// What the ledger will say is read first, then the file is flushed, then the ledger
        /// is written: it never claims more than is on the disk.
        void SaveLedger()
        {
            var lines = Lines();
            try { if (file is { IsClosed: false }) FlushFileBuffers(file); } catch (ObjectDisposedException) { }
            WriteLedger(lines);
        }

        /// One writer at a time: pieces finishing and the watchdog save it from different threads.
        static readonly object ledgerGate = new();

        static void WriteLedger(List<string> lines)
        {
            lock (ledgerGate)
            {
                try
                {
                    var temp = Ledger + ".new";
                    File.WriteAllText(temp, string.Join("\n", lines));
                    File.Move(temp, Ledger, true);
                }
                catch (Exception e) { Diagnostics.Write("model download: couldn't save the list of pieces: " + e.Message); }
            }
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FlushFileBuffers(SafeFileHandle file);
}
