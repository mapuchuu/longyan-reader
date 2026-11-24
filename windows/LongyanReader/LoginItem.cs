using System;
using Microsoft.Win32;

namespace Longyan;

/// Open at login: a value under HKCU\...\CurrentVersion\Run with the exe's quoted path, the
/// way Windows lists startup apps (Settings > Apps > Startup and Task Manager, where it can be
/// turned off too). The registry is the setting: nothing else remembers it. The Store build
/// uses its package's startup task instead (below).
static class LoginItem
{
#if STORE
    // The Store build: the package's startup task (windows.startupTask in
    // windows/store/AppxManifest.xml). It shows in the same places (Settings > Apps > Startup,
    // Task Manager), and Windows removes it with the app. Turned off there, the app can't turn it
    // back on (DisabledByUser): only the reader can, in those places.
    const string TaskId = "LongyanReaderAtLogin";
    static Windows.ApplicationModel.StartupTask? task;
    static bool looked;

    static Windows.ApplicationModel.StartupTask? Task
    {
        get
        {
            if (looked) return task;
            looked = true;
            try { task = Windows.ApplicationModel.StartupTask.GetAsync(TaskId).AsTask().GetAwaiter().GetResult(); }
            catch (Exception e) { Diagnostics.Write("open at login: no startup task (" + e.Message + ")"); }
            return task;
        }
    }

    public static bool Available => Task != null;

    public static bool IsEnabled
    {
        get
        {
            try { return Task?.State is Windows.ApplicationModel.StartupTaskState.Enabled or Windows.ApplicationModel.StartupTaskState.EnabledByPolicy; }
            catch { return false; }
        }
    }

    public static void Set(bool on)
    {
        try
        {
            if (Task is not { } t) return;
            if (on) t.RequestEnableAsync().AsTask().GetAwaiter().GetResult();
            else t.Disable();
            Diagnostics.Write("open at login " + (on ? "on" : "off") + " (startup task: " + t.State + ")");
        }
        catch (Exception e) { Diagnostics.Write("couldn't change open at login: " + e.Message); }
    }

    /// The package's path doesn't change with updates, so there's nothing to point anywhere.
    public static void Refresh()
    {
        try { if (Task is { } t) Diagnostics.Write("open at login: startup task " + t.State); }
        catch (Exception e) { Diagnostics.Write("couldn't check open at login: " + e.Message); }
    }
#else
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    // Where Task Manager and Settings note a startup app they turned off.
    const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const string Name = "Longyan Reader";

    static string Command => "\"" + Environment.ProcessPath + "\"";

    /// Not from a temporary folder (a zip opened in place): the path would go away.
    public static bool Available =>
        Environment.ProcessPath is string p && !p.StartsWith(System.IO.Path.GetTempPath(), StringComparison.OrdinalIgnoreCase);

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var run = Registry.CurrentUser.OpenSubKey(RunKey);
                if (run?.GetValue(Name) is not string) return false;
                using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
                // An odd first byte means turned off there (02 on, 03 off).
                return !(approved?.GetValue(Name) is byte[] b && b.Length > 0 && (b[0] & 1) == 1);
            }
            catch { return false; }
        }
    }

    public static void Set(bool on)
    {
        try
        {
            using var run = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) run.SetValue(Name, Command);
            else run.DeleteValue(Name, false);
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, true);
            approved?.DeleteValue(Name, false);
            Diagnostics.Write("open at login " + (on ? "on" : "off"));
        }
        catch (Exception e) { Diagnostics.Write("couldn't change open at login: " + e.Message); }
    }

    /// At launch: when it's on but the exe has moved (a new folder after an update), point it here.
    public static void Refresh()
    {
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey, true);
            if (run?.GetValue(Name) is string old && !string.Equals(old, Command, StringComparison.OrdinalIgnoreCase) && Available)
            {
                run.SetValue(Name, Command);
                Diagnostics.Write("open at login: the app moved, so it now opens from its new folder");
            }
        }
        catch (Exception e) { Diagnostics.Write("couldn't check open at login: " + e.Message); }
    }
#endif
}
