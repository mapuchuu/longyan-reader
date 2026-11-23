using System;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Longyan;

/// Downloads the reading model, the same file and checksum as the Mac app
/// (Sources/LongyanReader/ModelDownloader.swift), into %LOCALAPPDATA%\LongyanReader\models.
/// One connection, resumed from where it stopped; the first host that answers is used.
/// The tray, the welcome window and Settings all show its state (Changed, on the app's thread).
static class ModelDownload
{
    const string FilePath = "unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf";
    static readonly string[] Hosts = { "https://hf-mirror.com/", "https://huggingface.co/" };
    public const long Size = 2_740_937_888;
    const string Sha256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4";

    public static bool Running { get; private set; }
    /// Checking a downloaded file's checksum.
    public static bool Checking { get; private set; }
    /// 0 to 1 while running.
    public static double Progress { get; private set; }
    /// Why the last download failed, until the next one starts ("stopped" when cancelled).
    public static string? LastError { get; set; }
    /// "About 4 minutes left", once the download has run long enough to tell.
    public static string? TimeLeft { get; private set; }
    public static event Action? Changed;
    static CancellationTokenSource? cancel;
    static (DateTime At, double Progress)? rateStart;

    public static bool IsDownloaded => File.Exists(Core.ModelPath) && new FileInfo(Core.ModelPath).Length == Size;

    /// Bytes of the model on disk: the file, or what's downloaded of it so far.
    public static long OnDisk
    {
        get
        {
            try
            {
                if (File.Exists(Core.ModelPath)) return new FileInfo(Core.ModelPath).Length;
                var partial = Core.ModelPath + ".part";
                return File.Exists(partial) ? new FileInfo(partial).Length : 0;
            }
            catch { return 0; }
        }
    }

    public static void Notify() => Changed?.Invoke();

    /// The task ends with null, or why it failed. Call it from the app's thread.
    public static async Task<string?> Run()
    {
        if (Running) return null;
        Running = true;
        Progress = (double)OnDisk / Size;
        LastError = null;
        TimeLeft = null;
        rateStart = null;
        cancel = new CancellationTokenSource();
        var progress = new Progress<double>(p => { Progress = p; Estimate(p); Notify(); });
        Notify();
        string? error;
        try
        {
            Directory.CreateDirectory(Core.ModelsDirectory);
            var partial = Core.ModelPath + ".part";
            error = null;
            foreach (var host in Hosts)
            {
                try
                {
                    await Fetch(new Uri(host + FilePath), partial, progress, cancel.Token);
                    Checking = true;
                    Notify();
                    if (!await Matches(partial)) { File.Delete(partial); error = "the download was damaged: try again"; break; }
                    File.Move(partial, Core.ModelPath, true);
                    error = null;
                    break;
                }
                catch (OperationCanceledException) { error = "stopped"; break; }
                catch (Exception e) { error = e.Message; }
            }
        }
        catch (Exception e) { error = e.Message; }
        finally { Running = false; Checking = false; TimeLeft = null; }
        LastError = error;
        Notify();
        return error;
    }

    public static void Stop() => cancel?.Cancel();

    static async Task Fetch(Uri url, string partial, IProgress<double> progress, CancellationToken token)
    {
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("LongyanReader-Windows");
        var have = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (have >= Size) return;
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (have > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        // A server that ignores the range sends the whole file again.
        if (have > 0 && response.StatusCode != System.Net.HttpStatusCode.PartialContent) have = 0;
        using var input = await response.Content.ReadAsStreamAsync(token);
        using var output = new FileStream(partial, have > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
        var buffer = new byte[1 << 20];
        long done = have;
        int n;
        var lastReport = DateTime.MinValue;
        while ((n = await input.ReadAsync(buffer, token)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, n), token);
            done += n;
            if ((DateTime.Now - lastReport).TotalMilliseconds > 250) { progress.Report((double)done / Size); lastReport = DateTime.Now; }
        }
        if (done != Size) throw new IOException("the download stopped early");
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
        try { return await Matches(Core.ModelPath); }
        finally { Checking = false; Notify(); }
    }

    static async Task<bool> Matches(string path)
    {
        using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream);
        return Convert.ToHexString(hash).Equals(Sha256, StringComparison.OrdinalIgnoreCase);
    }

    /// "1.2 GB"
    public static string Gigabytes(long bytes) => $"{bytes / 1e9:0.0} GB";
}
