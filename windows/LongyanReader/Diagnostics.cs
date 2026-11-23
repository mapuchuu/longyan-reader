using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Longyan;

/// The app's own log, %LOCALAPPDATA%\LongyanReader\logs\longyan.log: starts, exits, model
/// changes and crashes. Never the text the reader selected: Chinese characters are taken out
/// of every line before it's written, and the user's folder is shortened to %USERPROFILE%.
static class Diagnostics
{
    static readonly string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader");
    public static readonly string LogDirectory = Path.Combine(root, "logs");
    static readonly string logFile = Path.Combine(LogDirectory, "longyan.log");
    static readonly string oldLogFile = Path.Combine(LogDirectory, "longyan.1.log");
    // Written at start, removed on a clean exit: still there at the next start means the last
    // run ended badly (a Swift trap or a crash takes the process down before any handler).
    static readonly string runningFile = Path.Combine(root, "running");
    const long MaxLog = 256 * 1024;
    static readonly object gate = new();

    /// Called when something went wrong but the app kept running: the tray offers a report.
    public static Action? Failed;

    public static string Version =>
        (System.Reflection.Assembly.GetEntryAssembly()?.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .FirstOrDefault() as System.Reflection.AssemblyInformationalVersionAttribute)?.InformationalVersion ?? "dev";

    public static void Write(string message)
    {
        var line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff") + "Z " + Clean(message);
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(LogDirectory);
                if (File.Exists(logFile) && new FileInfo(logFile).Length > MaxLog) File.Move(logFile, oldLogFile, true);
                File.AppendAllText(logFile, line + "\r\n");
            }
            catch { }
        }
    }

    static readonly string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// No Chinese text (it could only have come from a selection or a card) and no user name.
    static string Clean(string s)
    {
        if (home.Length > 3) s = s.Replace(home, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        var b = new StringBuilder(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (char.IsHighSurrogate(c) && i + 1 < s.Length) { b.Append('?'); i++; continue; }
            b.Append(c >= '⺀' && c <= '鿿' || c >= '豈' && c <= '﫿' || c >= '＀' && c <= '￯' ? '?' : c);
        }
        return b.ToString();
    }

    /// The handlers, and the run marker. True when the last run didn't exit cleanly.
    public static bool Start()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Write("crash: " + Describe(e.ExceptionObject as Exception) + (e.IsTerminating ? " (the app closed)" : ""));
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Write("unobserved task error: " + Describe(e.Exception));
            e.SetObserved();
        };
        Write($"start {Version}, {WindowsVersion}, {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}, {Environment.ProcessorCount} cores");
        var bad = false;
        try
        {
            bad = File.Exists(runningFile);
            if (bad) Write("the last run didn't exit cleanly");
            Directory.CreateDirectory(root);
            File.WriteAllText(runningFile, Version);
        }
        catch { }
        return bad;
    }

    /// An error on the app's thread: logged, and the app carries on.
    public static void Watch(System.Windows.Application app)
    {
        app.DispatcherUnhandledException += (_, e) =>
        {
            Write("error: " + Describe(e.Exception));
            e.Handled = true;
            Failed?.Invoke();
        };
    }

    public static void ExitedCleanly()
    {
        try { File.Delete(runningFile); } catch { }
    }

    public static string Describe(Exception? e)
    {
        if (e == null) return "unknown";
        var s = $"{e.GetType().FullName}: {e.Message}\r\n{e.StackTrace}";
        for (var inner = e.InnerException; inner != null; inner = inner.InnerException)
            s += $"\r\n  inner {inner.GetType().FullName}: {inner.Message}\r\n{inner.StackTrace}";
        return s;
    }

    // MARK: This PC

    public static string WindowsVersion
    {
        get
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
                var build = int.TryParse(key?.GetValue("CurrentBuild") as string, out var b) ? b : Environment.OSVersion.Version.Build;
                var release = key?.GetValue("DisplayVersion") as string ?? key?.GetValue("ReleaseId") as string ?? "";
                var ubr = key?.GetValue("UBR") is int u ? "." + u : "";
                // ProductName still says Windows 10 on Windows 11.
                return $"Windows {(build >= 22000 ? "11" : "10")} {release} ({build}{ubr})".Replace("  ", " ");
            }
            catch { return Environment.OSVersion.VersionString; }
        }
    }

    static string Processor
    {
        get
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
                return (key?.GetValue("ProcessorNameString") as string)?.Trim() ?? "unknown CPU";
            }
            catch { return "unknown CPU"; }
        }
    }

    static string Memory => $"{Math.Round(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1073741824.0)} GB";

    // MARK: Report a problem

    /// A prefilled GitHub issue: versions, this PC, the model's state and the end of the log
    /// (which holds no card text). Kept under 2,000 characters, which every browser and
    /// ShellExecute take.
    public static void Report(string modelStatus)
    {
        var head = """
            **What happened**


            **What you expected**


            **Which app the text was in** (for example Edge, Word, WeChat)


            **Steps or text to reproduce** (a sentence and the word you looked up help most)


            ---
            """ + $"\nLongyan Reader {Version} for Windows, {WindowsVersion}, {Processor}, {Memory}, {Environment.ProcessorCount} cores, reading model: {modelStatus}\n";
        var tail = "\nThe whole log is in %LOCALAPPDATA%\\LongyanReader\\logs, if you'd like to attach it.";
        const string start = "https://github.com/mapuchuu/longyan-reader/issues/new?body=";
        const int limit = 2000;
        var lines = LastLines(40);
        string url;
        while (true)
        {
            var log = lines.Count == 0 ? "" : "\nThe log's last lines:\n```\n" + string.Join("\n", lines) + "\n```\n";
            url = start + Uri.EscapeDataString(head + log + tail);
            if (url.Length <= limit || lines.Count == 0) break;
            lines.RemoveAt(0);
        }
        if (url.Length > limit) url = start + Uri.EscapeDataString(head + tail);
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { Write("couldn't open the browser: " + e.Message); }
    }

    static List<string> LastLines(int count)
    {
        try
        {
            lock (gate)
            {
                if (!File.Exists(logFile)) return new();
                return File.ReadAllLines(logFile).TakeLast(count).Select(l => l.Length > 160 ? l[..160] + "…" : l).ToList();
            }
        }
        catch { return new(); }
    }
}
