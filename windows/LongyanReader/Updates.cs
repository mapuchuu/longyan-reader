using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace Longyan;

/// Updates through WinSparkle (WinSparkle.dll, the build for this app's arch), the Windows
/// port of the Mac's Sparkle. The feed is appcast-windows.xml on the windows-feed pre-release
/// (scripts/windows-feed.py writes it), and every installer is checked against the ed25519 key
/// in windows/update-key.txt before it runs. As on the Mac, WinSparkle asks on the second launch
/// whether to check automatically, then checks once a day; until the reader says yes, the app
/// only goes online for an update when they choose Check for Updates.
static class Updates
{
    // Built in from the csproj: the feed, the public key and the build number WinSparkle
    // compares (the commit count, as on the Mac).
    static string Meta(string key) =>
        Assembly.GetEntryAssembly()?.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == key)?.Value ?? "";

    static readonly string key = Meta("UpdateKey").Trim();
    static readonly string build = Meta("BuildNumber").Trim();
    static bool started;

    /// Only in a built app with its key: without one WinSparkle would run any installer it's given.
    public static bool Available { get; } = key.Length > 0 && build.Length > 0 && build != "0"
        && File.Exists(Path.Combine(Core.AppDirectory, "WinSparkle.dll"));

    /// The feed: settings.json's "updateFeed" to try an update from a local server (DEVELOPMENT.md),
    /// like the Mac's SUFeedURL default; otherwise the one built in.
    static string Feed()
    {
        try
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "settings.json");
            if (File.Exists(path) && JsonNode.Parse(File.ReadAllText(path)) is JsonObject o
                && o["updateFeed"] is JsonValue v && v.TryGetValue<string>(out var url) && url.Length > 0) return url;
        }
        catch { }
        return Meta("UpdateFeed");
    }

    // Kept so the collector never frees what WinSparkle calls back on its own threads.
    static readonly CanShutdown canShutdown = () => 1;
    static readonly Callback shutdown = () => System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => Program.ExitForUpdate());
    static readonly Callback error = () => Diagnostics.Write("updates: the check or download failed");
    static readonly Callback found = () => Diagnostics.Write("updates: found a new version");
    static readonly Callback notFound = () => Diagnostics.Write("updates: up to date");
    static readonly Callback cancelled = () => Diagnostics.Write("updates: cancelled");
    static readonly Callback skipped = () => Diagnostics.Write("updates: version skipped");
    static readonly Callback postponed = () => Diagnostics.Write("updates: remind me later");

    public static void Start()
    {
        if (!Available || started) return;
        try
        {
            var feed = Feed();
            win_sparkle_set_appcast_url(feed);
            if (win_sparkle_set_eddsa_public_key(key) != 1) { Diagnostics.Write("updates: the built-in key isn't valid, so updates are off"); return; }
            win_sparkle_set_app_details("Longyan Reader", "Longyan Reader", Diagnostics.Version.Split('+')[0]);
            win_sparkle_set_app_build_version(build);
            // Its settings (checking on or off, the last check, a skipped version) stay with the app's.
            win_sparkle_set_registry_path(@"Software\LongyanReader\Updates");
            win_sparkle_set_can_shutdown_callback(canShutdown);
            win_sparkle_set_shutdown_request_callback(shutdown);
            win_sparkle_set_error_callback(error);
            win_sparkle_set_did_find_update_callback(found);
            win_sparkle_set_did_not_find_update_callback(notFound);
            win_sparkle_set_update_cancelled_callback(cancelled);
            win_sparkle_set_update_skipped_callback(skipped);
            win_sparkle_set_update_postponed_callback(postponed);
            win_sparkle_init();
            started = true;
            Diagnostics.Write($"updates: build {build}, {RuntimeInformation.ProcessArchitecture}, automatic checks {(Automatic ? "on" : "off")}"
                + (feed != Meta("UpdateFeed") ? ", feed " + feed : ""));
        }
        catch (Exception e) { Diagnostics.Write("updates: couldn't start WinSparkle: " + Diagnostics.Describe(e)); }
    }

    /// Check for Updates: WinSparkle's window, which says when there's nothing new.
    public static void CheckNow()
    {
        if (!started) return;
        try { win_sparkle_check_update_with_ui(); }
        catch (Exception e) { Diagnostics.Write("updates: " + Diagnostics.Describe(e)); }
    }

    /// Automatic checks, once a day: the Settings switch and WinSparkle's own question.
    public static bool Automatic
    {
        get { try { return started && win_sparkle_get_automatic_check_for_updates() == 1; } catch { return false; } }
        set
        {
            if (!started) return;
            try { win_sparkle_set_automatic_check_for_updates(value ? 1 : 0); Diagnostics.Write("updates: automatic checks " + (value ? "on" : "off")); }
            catch (Exception e) { Diagnostics.Write("updates: " + Diagnostics.Describe(e)); }
        }
    }

    public static void Stop()
    {
        if (!started) return;
        started = false;
        win_sparkle_cleanup();
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int CanShutdown();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Callback();

    const string Dll = "WinSparkle.dll";
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_init();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_cleanup();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_appcast_url([MarshalAs(UnmanagedType.LPUTF8Str)] string url);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int win_sparkle_set_eddsa_public_key([MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)] static extern void win_sparkle_set_app_details(string company, string app, string version);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)] static extern void win_sparkle_set_app_build_version(string build);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_registry_path([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_automatic_check_for_updates(int state);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int win_sparkle_get_automatic_check_for_updates();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_check_update_with_ui();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_can_shutdown_callback(CanShutdown callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_shutdown_request_callback(Callback callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_error_callback(Callback callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_did_find_update_callback(Callback callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_did_not_find_update_callback(Callback callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_update_cancelled_callback(Callback callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_update_skipped_callback(Callback callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_set_update_postponed_callback(Callback callback);
}
