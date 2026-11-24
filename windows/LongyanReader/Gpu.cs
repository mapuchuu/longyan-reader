using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Longyan;

/// The reading model on the GPU, when that's faster and gives the same answers. The GPU
/// backends are in the app's gpu folder (ggml-vulkan.dll on x64, ggml-opencl.dll on ARM64).
/// The app never loads one until a self-test in a separate process (LongyanReader.exe
/// --gpu-test) has shown that it works here: the same fixed pick on the CPU and on the GPU,
/// timed, the GPU kept only if its numbers are the CPU's and it's faster. The test runs once,
/// a minute after the model is ready, and again after the app or a display driver changes.
/// Its choice is in settings.json ("gpu"), and its lines in the log. LONGYAN_GPU=0 keeps the
/// CPU, LONGYAN_GPU=1 uses the GPU without the test.
static class Gpu
{
    static readonly string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader");
    /// Written by the core while the model is on the GPU, removed when it's let go.
    static readonly string inUseFile = Path.Combine(root, "gpu-in-use");
    static readonly string? env = Environment.GetEnvironmentVariable("LONGYAN_GPU");
    static bool scheduled;
    static Process? running;

    /// For the report and Settings: "GPU (…)" or "CPU (why)".
    public static string Status { get; private set; } = "CPU";

    public static string[] Backends =>
        Directory.Exists(Path.Combine(Core.AppDirectory, "gpu"))
            ? Directory.GetFiles(Path.Combine(Core.AppDirectory, "gpu"), "ggml-*.dll")
                .Select(f => Path.GetFileNameWithoutExtension(f)["ggml-".Length..]).OrderBy(n => n).ToArray()
            : Array.Empty<string>();

    /// What the test's answer depends on: this app's build and the display drivers.
    public static string Fingerprint
    {
        get
        {
            var parts = new List<string> { Diagnostics.Version };
            try
            {
                var bridge = new FileInfo(Path.Combine(Core.AppDirectory, "LongyanBridge.dll"));
                if (bridge.Exists) parts.Add($"{bridge.Length}");
                foreach (var b in Backends) parts.Add(b + ":" + new FileInfo(Path.Combine(Core.AppDirectory, "gpu", "ggml-" + b + ".dll")).Length);
            }
            catch { }
            parts.AddRange(Drivers());
            return string.Join("|", parts);
        }
    }

    /// Each display adapter and its driver's version, from the display class in the registry.
    static IEnumerable<string> Drivers()
    {
        var found = new List<string>();
        try
        {
            using var cls = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}");
            foreach (var name in cls?.GetSubKeyNames() ?? Array.Empty<string>())
            {
                if (name.Length != 4 || !name.All(char.IsDigit)) continue;
                try
                {
                    using var k = cls!.OpenSubKey(name);
                    if (k?.GetValue("DriverDesc") is string desc) found.Add(desc + "=" + (k.GetValue("DriverVersion") as string ?? "?"));
                }
                catch { }
            }
        }
        catch { }
        found.Sort(StringComparer.Ordinal);
        return found;
    }

    /// At start, before the core: the GPU if the last test chose it for this app and these
    /// drivers, else the CPU. A run that ended badly with the model on the GPU turns it off.
    public static void Apply(bool lastRunEndedBadly)
    {
        if (env == "0") { Status = "CPU (LONGYAN_GPU=0)"; Use(null, 0); return; }
        // The core reads it itself; this only sets up the core's GPU lines for the log.
        if (env == "1") { Status = "GPU (LONGYAN_GPU=1)"; Use(null, 0); return; }
        if (File.Exists(inUseFile))
        {
            try { File.Delete(inUseFile); } catch { }
            if (lastRunEndedBadly && Settings.Gpu is JsonObject g && Flag(g, "use"))
            {
                g["use"] = false;
                g["why"] = "the app closed unexpectedly while the model was on the GPU";
                Settings.Gpu = g;
                Diagnostics.Write("gpu: off, the app closed unexpectedly while the model was on the GPU");
            }
        }
        var saved = Settings.Gpu;
        if (saved != null && Text(saved, "fingerprint") == Fingerprint && Flag(saved, "use") && Text(saved, "backend") is { Length: > 0 } backend)
        {
            var layers = saved["layers"] is JsonValue v && v.TryGetValue<int>(out var l) ? l : 99;
            Use(backend, layers);
            Status = Describe(saved);
        }
        else
        {
            Use(null, 0);
            Status = saved != null && Text(saved, "fingerprint") == Fingerprint ? Describe(saved) : "CPU (GPU not tested yet)";
        }
        Diagnostics.Write("gpu at start: " + Status);
    }

    static void Use(string? backend, int layers) => Bridge.ly_use_gpu(backend == null ? null : Bridge.Utf8(backend), layers);

    /// The model is ready: the self-test a minute later, unless this app and these drivers
    /// were tested already.
    public static void ModelReady()
    {
        if (scheduled || env is "0" or "1" || Backends.Length == 0) return;
        if (Settings.Gpu is JsonObject g && Text(g, "fingerprint") == Fingerprint) return;
        scheduled = true;
        var delay = double.TryParse(Environment.GetEnvironmentVariable("LONGYAN_GPU_TEST_DELAY"), out var d) ? d : 60;
        Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(delay));
            var result = RunTests();
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => Chosen(result));
        });
    }

    /// Runs each backend's test in a process of its own and returns the best result.
    static JsonObject RunTests()
    {
        JsonObject? best = null;
        var notes = new List<string>();
        foreach (var backend in Backends)
        {
            var r = RunTest(backend);
            Diagnostics.Write("gpu test: " + r.ToJsonString());
            Core.Log("{\"event\":\"gpu-test\",\"result\":" + r.ToJsonString() + "}");
            notes.Add(backend + ": " + Text(r, "why"));
            if (Flag(r, "use") && (best == null || Number(r, "gpuMs") < Number(best, "gpuMs"))) best = r;
        }
        best ??= new JsonObject { ["use"] = false, ["why"] = notes.Count > 0 ? string.Join("; ", notes) : "no GPU backend" };
        best["fingerprint"] = Fingerprint;
        best["at"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        return best;
    }

    /// One backend's test: LongyanReader.exe --gpu-test BACKEND OUT, at most 6 minutes. A crash
    /// or a hang is the test's answer: the CPU.
    static JsonObject RunTest(string backend)
    {
        var output = Path.Combine(Path.GetTempPath(), $"longyan-gpu-{backend}-{Environment.ProcessId}.json");
        var clock = Stopwatch.StartNew();
        try
        {
            File.Delete(output);
            var exe = Environment.ProcessPath ?? Path.Combine(Core.AppDirectory, "LongyanReader.exe");
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
            start.ArgumentList.Add("--gpu-test");
            start.ArgumentList.Add(backend);
            start.ArgumentList.Add(output);
            start.Environment["LONGYAN_TIMING"] = "1";
            using var p = Process.Start(start)!;
            running = p;
            var stderr = p.StandardError.ReadToEndAsync();
            var minutes = double.TryParse(Environment.GetEnvironmentVariable("LONGYAN_GPU_TEST_MINUTES"), out var m) ? m : 6;
            if (!p.WaitForExit(TimeSpan.FromMinutes(minutes)))
            {
                try { p.Kill(true); } catch { }
                Save(backend, stderr);
                return Failed(backend, $"the test took over {minutes} minutes", clock);
            }
            Save(backend, stderr);
            if (p.ExitCode != 0 || !File.Exists(output))
                return Failed(backend, $"the test process ended with 0x{p.ExitCode:X8} (a GPU driver problem)", clock);
            var r = JsonNode.Parse(File.ReadAllText(output)) as JsonObject ?? Failed(backend, "the test's answer couldn't be read", clock);
            r["seconds"] = Math.Round(clock.Elapsed.TotalSeconds, 1);
            return r;
        }
        catch (Exception e) { return Failed(backend, "the test couldn't run: " + e.Message, clock); }
        finally
        {
            running = null;
            try { File.Delete(output); } catch { }
            // The test's own model use never counts as the app's.
            try { File.Delete(inUseFile); } catch { }
        }
    }

    /// The test's stderr (llama.cpp's timing lines) in logs\gpu-test-BACKEND.txt.
    static void Save(string backend, Task<string> stderr)
    {
        try
        {
            if (!stderr.Wait(TimeSpan.FromSeconds(5))) return;
            Directory.CreateDirectory(Diagnostics.LogDirectory);
            File.WriteAllText(Path.Combine(Diagnostics.LogDirectory, $"gpu-test-{backend}.txt"), stderr.Result);
        }
        catch { }
    }

    static JsonObject Failed(string backend, string why, Stopwatch clock) =>
        new() { ["backend"] = backend, ["use"] = false, ["why"] = why, ["seconds"] = Math.Round(clock.Elapsed.TotalSeconds, 1) };

    /// The test's choice: kept in settings, used from the next card on.
    static void Chosen(JsonObject result)
    {
        Settings.Gpu = result;
        Status = Describe(result);
        Diagnostics.Write("gpu: " + Status);
        Core.Log("{\"event\":\"gpu-choice\",\"use\":" + (Flag(result, "use") ? "true" : "false") + ",\"status\":" + JsonValue.Create(Status).ToJsonString() + "}");
        if (Flag(result, "use")) Use(Text(result, "backend"), result["layers"] is JsonValue v && v.TryGetValue<int>(out var l) ? l : 99);
    }

    /// The core's GPU lines ({"event":"gpu"}): logged, and a failure turns the GPU off.
    public static void OnEvent(JsonObject e)
    {
        if (e["message"] is JsonValue m) Diagnostics.Write("gpu: " + (string?)m);
        if (e["failed"] is JsonValue f)
        {
            var why = (string?)f ?? "";
            Diagnostics.Write("gpu failed: " + why);
            if (env != "1" && Settings.Gpu is JsonObject g)
            {
                g["use"] = false;
                g["why"] = "failed in the app: " + why;
                Settings.Gpu = g;
            }
            Status = "CPU (the GPU failed: " + why + ")";
        }
    }

    static string Describe(JsonObject r)
    {
        if (!Flag(r, "use")) return "CPU (" + Text(r, "why") + ")";
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        return string.Format(inv, "GPU ({0}, {1}, {2} of {3} layers, {4:0} ms against {5:0} ms on the CPU)", Text(r, "backend"), Text(r, "device"),
            Number(r, "layers"), Number(r, "layerCount"), Number(r, "gpuMs"), Number(r, "cpuMs"));
    }

    static string Text(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
    static bool Flag(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;
    static double Number(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : double.MaxValue;

    /// Exit: a test still running ends with the app.
    public static void Stop()
    {
        try { if (running is { HasExited: false } p) p.Kill(true); } catch { }
    }

    // MARK: Commands

    /// --gpu-test BACKEND OUT: the test itself, in this process (run by RunTest).
    public static int TestCommand(string backend, string output)
    {
        // A driver that crashes ends this process at once, with no crash dialog left waiting.
        SetErrorMode(0x0001 | 0x0002);   // SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX
        try
        {
            return Bridge.ly_gpu_test(Bridge.Utf8(Core.ResourcesDirectory), Bridge.Utf8(Core.ModelPath), Bridge.Utf8(backend), Bridge.Utf8(output));
        }
        catch (Exception e) { Console.Error.WriteLine("gpu test: " + e); return 2; }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern uint SetErrorMode(uint mode);

    /// --gpu-check: what the app would do a minute after the model is ready, now and in the
    /// foreground: each backend's test, the choice saved and logged (for CI and beta testers).
    public static int CheckCommand()
    {
        Diagnostics.Write($"gpu check: backends {string.Join(",", Backends)}, fingerprint {Fingerprint}");
        var result = RunTests();
        Settings.Gpu = result;
        Status = Describe(result);
        Diagnostics.Write("gpu: " + Status);
        return 0;
    }
}
