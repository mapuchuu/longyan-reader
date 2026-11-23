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
static class ModelDownload
{
    const string FilePath = "unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf";
    static readonly string[] Hosts = { "https://hf-mirror.com/", "https://huggingface.co/" };
    public const long Size = 2_740_937_888;
    const string Sha256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4";

    public static bool Running { get; private set; }
    static CancellationTokenSource? cancel;

    public static bool IsDownloaded => File.Exists(Core.ModelPath) && new FileInfo(Core.ModelPath).Length == Size;

    /// `progress` gets 0 to 1 while downloading; the task ends with null, or why it failed.
    public static async Task<string?> Run(IProgress<double> progress)
    {
        if (Running) return null;
        Running = true;
        cancel = new CancellationTokenSource();
        try
        {
            Directory.CreateDirectory(Core.ModelsDirectory);
            var partial = Core.ModelPath + ".part";
            string? lastError = null;
            using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("LongyanReader-Windows");
            foreach (var host in Hosts)
            {
                try
                {
                    await Fetch(http, host + FilePath, partial, progress, cancel.Token);
                    if (!await Matches(partial)) { File.Delete(partial); return "the download was damaged: try again"; }
                    File.Move(partial, Core.ModelPath, true);
                    return null;
                }
                catch (OperationCanceledException) { return "stopped"; }
                catch (Exception e) { lastError = e.Message; }
            }
            return lastError ?? "no server answered";
        }
        finally { Running = false; }
    }

    public static void Stop() => cancel?.Cancel();

    static async Task Fetch(HttpClient http, string url, string partial, IProgress<double> progress, CancellationToken token)
    {
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

    static async Task<bool> Matches(string path)
    {
        using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream);
        return Convert.ToHexString(hash).Equals(Sha256, StringComparison.OrdinalIgnoreCase);
    }
}
