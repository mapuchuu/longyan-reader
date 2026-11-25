using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// UiCheck --packaged FAMILY_NAME OUT_DIR: the Store build, installed from its MSIX
/// (windows/store/test.ps1 installs it), opened from Start as a reader would. Checks what
/// differs from the GitHub build: the app runs with its package identity and no WinSparkle,
/// what it writes under %LOCALAPPDATA% (log, settings, the model's download) lands in the
/// package's own folder and not in the real one, and Open at login is the package's startup
/// task: on from the welcome window, read back at the next start, off and on again in Settings
/// with the same words, and never the Run key.
static partial class Program
{
    static int Packaged(string family, string output)
    {
        outDir = Path.GetFullPath(output);
        Directory.CreateDirectory(outDir);
        Console.OutputEncoding = new UTF8Encoding(false);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var real = Path.Combine(local, "LongyanReader");
        var kept = Path.Combine(local, "Packages", family, "LocalCache", "Local", "LongyanReader");
        var appLog = Path.Combine(kept, "logs", "longyan.log");
        Console.WriteLine($"[packaged] {family}: data should be in {kept}");
        if (Directory.Exists(real)) failures.Add($"packaged: {real} exists before the app ran (not a clean runner?)");

        // 1. Open from Start (the package's app entry): the welcome window, at once.
        var app = Open(family);
        var window = WaitForWindow("Welcome to Longyan Reader", TimeSpan.FromSeconds(60), exact: true);
        if (window == IntPtr.Zero) { failures.Add("packaged: no welcome window"); Shot("pk-0-no-welcome"); return Done(appLog); }
        Bring(window);
        Thread.Sleep(1000);
        Shot("pk-1-welcome");
        app ??= Running();
        if (app == null) { failures.Add("packaged: no LongyanReader process"); return Done(appLog); }
        var path = app.MainModule?.FileName ?? "";
        Console.WriteLine($"[packaged] running from {path}");
        if (!path.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase)) failures.Add($"packaged: the app runs from {path}, not the package");
        var root = AutomationElement.FromHandle(window);
        var text = WindowText(root);
        File.WriteAllText(Path.Combine(outDir, "pk-1-welcome.txt"), text, new UTF8Encoding(false));
        if (!text.Contains("Select Chinese text in any app")) failures.Add("packaged: the welcome window doesn't say what to do");
        if (Find(root, "OpenAtLogin") is not AutomationElement loginSwitch || loginSwitch.Current.IsOffscreen)
            failures.Add("packaged: no Open at login switch in the welcome window");
        else if (Toggled(loginSwitch) != true) failures.Add("packaged: Open at login isn't on by default in the welcome window");

        // 2. The log and settings: in the package's folder, never the real one.
        if (!WaitFor(() => File.Exists(appLog), 30)) failures.Add($"packaged: no log at {appLog}");
        var logText = ReadShared(appLog);
        if (!logText.Contains("packaged: ") || !logText.Contains("the Store build")) failures.Add("packaged: the log doesn't say it's the packaged Store build");
        if (logText.Contains("updates: ")) failures.Add("packaged: WinSparkle started");
        app.Refresh();
        var modules = app.Modules.Cast<ProcessModule>().Select(m => m.ModuleName).ToList();
        if (modules.Any(m => m.Equals("WinSparkle.dll", StringComparison.OrdinalIgnoreCase))) failures.Add("packaged: WinSparkle.dll is loaded");
        if (File.Exists(Path.Combine(Path.GetDirectoryName(path)!, "WinSparkle.dll"))) failures.Add("packaged: WinSparkle.dll is in the package");

        // 3. The model's download: starts into the package's models folder; Stop keeps the pieces.
        var button = Find(root, "ModelButton");
        if (!WaitFor(() => button?.Current.IsEnabled == true, 90)) failures.Add("packaged: the Download button never became usable");
        if (button?.Current.Name == "Download" && button.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern download)
        {
            download.Invoke();
            var models = Path.Combine(kept, "models");
            var part = Path.Combine(models, "qwen3.5-4b-q4_k_m.gguf.part");
            var started = WaitFor(() => File.Exists(part) && Downloaded(root) >= 0.1, 180);
            Shot("pk-2-downloading");
            Console.WriteLine($"[packaged] download: {Downloaded(root):0.0} GB, part file {(File.Exists(part) ? new FileInfo(part).Length / 1e6 : 0):0} MB");
            if (!started) failures.Add($"packaged: the download didn't write {part}");
            if (Find(root, "ModelButton") is AutomationElement stop && stop.Current.Name == "Stop" && stop.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern s) s.Invoke();
            WaitFor(() => Find(root, "ModelButton")?.Current.Name == "Resume", 30);
            if (!File.Exists(Path.Combine(models, "qwen3.5-4b-q4_k_m.gguf.pieces"))) failures.Add("packaged: no list of pieces after Stop");
            if (Directory.Exists(Path.Combine(real, "models"))) failures.Add("packaged: the model went to the real %LOCALAPPDATA%");
        }
        else failures.Add($"packaged: the model's button says \"{button?.Current.Name}\", not Download");

        // 4. Done: Open at login on, as the package's startup task.
        if (Find(root, "Done")?.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern done) done.Invoke();
        else failures.Add("packaged: no Done button");
        Thread.Sleep(3000);
        logText = ReadShared(appLog);
        if (!logText.Contains("open at login on (startup task: Enabled)")) failures.Add("packaged: Done didn't turn the startup task on");
        StartupTaskState(family, "after Done");
        RunKeyUntouched();
        if (Directory.Exists(real)) failures.Add($"packaged: the app wrote to the real {real}");
        if (Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\LongyanReader") != null) failures.Add(@"packaged: HKCU\Software\LongyanReader exists outside the package");

        // 5. The next start reads it back, and opening it again shows Settings with the same switch.
        try { app.Kill(); app.WaitForExit(10000); } catch { }
        Thread.Sleep(1000);
        // Two lookups in the package's history, for the History window from Settings (6).
        var historyFile = Path.Combine(kept, "History", "lookups.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(historyFile)!);
        var at = DateTime.UtcNow.AddHours(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
        File.WriteAllText(historyFile,
            new System.Text.Json.Nodes.JsonObject { ["at"] = at, ["event"] = "word", ["word"] = "干杯", ["pinyin"] = "gān bēi", ["meaningHere"] = "cheers", ["gloss"] = "to drink a toast; cheers!", ["sentence"] = "来，大家干杯！" }.ToJsonString() + "\n" +
            new System.Text.Json.Nodes.JsonObject { ["at"] = at, ["event"] = "phrase", ["text"] = "明天再说吧。", ["translation"] = "Let's talk tomorrow." }.ToJsonString() + "\n",
            new UTF8Encoding(false));
        var lines = ReadShared(appLog).Split('\n').Length;
        app = Open(family);
        WaitFor(() => ReadShared(appLog).Split('\n').Skip(lines - 1).Any(l => l.Contains("open at login: startup task")), 60);
        var since = string.Join("\n", ReadShared(appLog).Split('\n').Skip(lines - 1));
        if (!since.Contains("open at login: startup task Enabled")) failures.Add("packaged: the next start doesn't see the startup task as on");
        Open(family);   // the running copy opens Settings
        var settings = WaitForWindow("Longyan Reader settings", TimeSpan.FromSeconds(30), exact: true);
        if (settings == IntPtr.Zero) failures.Add("packaged: opening it again didn't show Settings");
        else
        {
            Bring(settings);
            Thread.Sleep(1000);
            Shot("pk-3-settings");
            var sroot = AutomationElement.FromHandle(settings);
            var stext = WindowText(sroot);
            File.WriteAllText(Path.Combine(outDir, "pk-3-settings.txt"), stext, new UTF8Encoding(false));
            if (!stext.Contains("Opens Longyan Reader when you log in to Windows.")) failures.Add("packaged: Settings doesn't say what Open at login does");
            if (stext.Contains("Check for updates")) failures.Add("packaged: Settings offers WinSparkle's updates");
            var sw = Find(sroot, "OpenAtLogin");
            if (sw == null || Toggled(sw) != true) failures.Add("packaged: Settings' Open at login switch isn't on");
            else
            {
                var before = ReadShared(appLog).Length;
                ((TogglePattern)sw.GetCurrentPattern(TogglePattern.Pattern)).Toggle();
                Thread.Sleep(1500);
                if (!ReadShared(appLog)[before..].Contains("open at login off (startup task: Disabled)")) failures.Add("packaged: turning Open at login off didn't disable the startup task");
                StartupTaskState(family, "after off");
                before = ReadShared(appLog).Length;
                ((TogglePattern)sw.GetCurrentPattern(TogglePattern.Pattern)).Toggle();
                Thread.Sleep(1500);
                if (!ReadShared(appLog)[before..].Contains("open at login on (startup task: Enabled)")) failures.Add("packaged: turning Open at login on again didn't enable the startup task");
                StartupTaskState(family, "after on");
                RunKeyUntouched();
                Shot("pk-4-settings-after");
            }
            // 6. Lookup history from Settings' Open: drawn whole.
            HistoryCheck.FromSettings(() => Open(family), app!, outDir, failures, "pk-5-history-from-settings");
        }
        return Done(appLog);
    }

    /// The package's app, as Start opens it.
    static Process? Open(string family)
    {
        Process.Start(new ProcessStartInfo("explorer.exe", $"shell:AppsFolder\\{family}!App") { UseShellExecute = false });
        Process? app = null;
        WaitFor(() => (app = Running()) != null, 30);
        return app;
    }

    static Process? Running() => Process.GetProcessesByName("LongyanReader").FirstOrDefault();

    static bool? Toggled(AutomationElement e)
    {
        try { return ((TogglePattern)e.GetCurrentPattern(TogglePattern.Pattern)).Current.ToggleState == ToggleState.On; }
        catch { return null; }
    }

    /// Where Windows keeps a package's startup tasks (for the log; the app's own log is the check).
    static void StartupTaskState(string family, string when)
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey($@"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\{family}\LongyanReaderAtLogin");
            Console.WriteLine($"[packaged] startup task {when}: State = {key?.GetValue("State") ?? "(no key)"}");
        }
        catch (Exception e) { Console.WriteLine($"[packaged] startup task {when}: {e.Message}"); }
    }

    static void RunKeyUntouched()
    {
        using var run = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (run?.GetValue("Longyan Reader") != null) failures.Add("packaged: the Run key has a Longyan Reader value");
    }

    static int Done(string appLog)
    {
        File.WriteAllText(Path.Combine(outDir, "longyan.log"), ReadShared(appLog), new UTF8Encoding(false));
        foreach (var p in Process.GetProcessesByName("LongyanReader")) { try { p.Kill(); p.WaitForExit(10000); } catch { } }
        foreach (var f in failures) Console.WriteLine("FAILED: " + f);
        if (failures.Count == 0) Console.WriteLine("[packaged] all checks passed");
        return failures.Count == 0 ? 0 : 1;
    }
}
