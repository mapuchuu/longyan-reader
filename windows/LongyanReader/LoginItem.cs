using System;
using Microsoft.Win32;

namespace Longyan;

/// Open at login: a value under HKCU\...\CurrentVersion\Run with the exe's quoted path, the
/// way Windows lists startup apps (Settings > Apps > Startup and Task Manager, where it can be
/// turned off too). The registry is the setting: nothing else remembers it.
static class LoginItem
{
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
}
