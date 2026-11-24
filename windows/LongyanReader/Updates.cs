using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Longyan;

/// Updates through WinSparkle (WinSparkle.dll, the build for this app's arch), the Windows
/// port of the Mac's Sparkle. The feed is appcast-windows.xml on the windows-feed pre-release
/// (scripts/windows-feed.py writes it), and every installer is checked against the ed25519 key
/// in windows/update-key.txt before it runs. As on the Mac, WinSparkle asks on the second launch
/// whether to check automatically, then checks once a day; until the reader says yes, the app
/// only goes online for an update when they choose Check for Updates.
///
/// The installer runs silently (the feed's sparkle:installerArguments, /VERYSILENT ... /OPEN=1)
/// and opens the app again. The x64 app on an ARM PC moves to the ARM64 build at its next
/// update: WinSparkle picks the enclosure for the arch it was built for, so that copy reads
/// appcast-windows-x64-on-arm64.xml, the same items with the ARM64 installer in the x64 place
/// (scripts/windows-feed.py writes both).
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
    /// Never in the Store build or any packaged copy: the Store updates those.
    public static bool Available { get; } = !Store.Build && !Store.Packaged && key.Length > 0 && build.Length > 0 && build != "0"
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

    /// The x64 build running under emulation on an ARM64 PC.
    public static bool X64OnArm64 { get; } = DetectX64OnArm64();

    static bool DetectX64OnArm64()
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.X64) return false;
        try { return IsWow64Process2(GetCurrentProcess(), out _, out var native) && native == 0xAA64; } // IMAGE_FILE_MACHINE_ARM64
        catch { return RuntimeInformation.OSArchitecture == Architecture.Arm64; }
    }

    /// The feed for this copy: on an ARM PC, the x64 app reads the one that offers the ARM64 build.
    public static string FeedFor(string feed, bool x64OnArm64)
    {
        const string name = "appcast-windows.xml";
        if (!x64OnArm64 || !feed.EndsWith("/" + name, StringComparison.OrdinalIgnoreCase)) return feed;
        return feed[..^name.Length] + "appcast-windows-x64-on-arm64.xml";
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
            var feed = FeedFor(Feed(), X64OnArm64);
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
            WatchWindows();
            win_sparkle_init();
            started = true;
            Diagnostics.Write($"updates: build {build}, {RuntimeInformation.ProcessArchitecture}{(X64OnArm64 ? " on ARM64, so the ARM64 build next" : "")}, automatic checks {(Automatic ? "on" : "off")}"
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

    // WinSparkle's windows open on its own thread, often while another app is in front: the
    // second launch's question comes as the app starts, and Windows doesn't give the focus to an
    // app the reader isn't using, so it opened behind. Each one is brought forward as it shows,
    // with the focus if Windows allows it, otherwise above the other windows with its taskbar
    // button flashing. Its title bar gets the app's icon: WinSparkle puts its own there, from its
    // DLL (the icon inside the window is the exe's first one, which is already the app's).
    static WinEventProc? onShow;   // kept alive while the hook is set
    static IntPtr smallIcon, bigIcon;
    static uint uiThread;

    static void WatchWindows()
    {
        uiThread = GetCurrentThreadId();
        var ico = Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        if (File.Exists(ico))
        {
            smallIcon = LoadImage(IntPtr.Zero, ico, IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE);
            bigIcon = LoadImage(IntPtr.Zero, ico, IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE);
        }
        onShow = OnShow;
        if (SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, onShow, (uint)Environment.ProcessId, 0, WINEVENT_OUTOFCONTEXT) == IntPtr.Zero)
            Diagnostics.Write("updates: can't watch for WinSparkle's windows");
        if (smallIcon == IntPtr.Zero || bigIcon == IntPtr.Zero) Diagnostics.Write("updates: couldn't load the app's icon for WinSparkle's windows");
    }

    static void OnShow(IntPtr hook, uint e, IntPtr hwnd, int obj, int child, uint thread, uint time)
    {
        if (obj != OBJID_WINDOW || hwnd == IntPtr.Zero || thread == uiThread || GetAncestor(hwnd, GA_ROOT) != hwnd) return;
        var cls = new StringBuilder(64);
        GetClassName(hwnd, cls, cls.Capacity);
        var style = GetWindowLong(hwnd, GWL_STYLE);
        Diagnostics.Write($"updates: a window showed on WinSparkle's thread, {cls} {style:x8}");
        if ((style & WS_CAPTION) != WS_CAPTION) return;
        if (!cls.ToString().StartsWith("wx", StringComparison.Ordinal)) return;   // wxWidgets, which WinSparkle is drawn with
        // Posted, not sent: WinSparkle's thread never waits on this one.
        if (smallIcon != IntPtr.Zero) PostMessage(hwnd, WM_SETICON, ICON_SMALL, smallIcon);
        if (bigIcon != IntPtr.Zero) PostMessage(hwnd, WM_SETICON, ICON_BIG, bigIcon);
        if (SetForegroundWindow(hwnd) && GetForegroundWindow() == hwnd) return;
        const uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags);
        SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags);   // above the other windows, but not kept on top
        var flash = new FLASHWINFO { cbSize = (uint)Marshal.SizeOf<FLASHWINFO>(), hwnd = hwnd, dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG };
        FlashWindowEx(ref flash);
        Diagnostics.Write("updates: another app has the focus, so the update window is on top with its taskbar button flashing");
    }

    delegate void WinEventProc(IntPtr hook, uint e, IntPtr hwnd, int obj, int child, uint thread, uint time);
    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    const uint EVENT_OBJECT_SHOW = 0x8002, WINEVENT_OUTOFCONTEXT = 0, IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10, WM_SETICON = 0x80, GA_ROOT = 2;
    const uint SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOACTIVATE = 0x10, FLASHW_ALL = 3, FLASHW_TIMERNOFG = 12;
    const int OBJID_WINDOW = 0, SM_CXICON = 11, SM_CYICON = 12, SM_CXSMICON = 49, SM_CYSMICON = 50, GWL_STYLE = -16, WS_CAPTION = 0xC00000;
    static readonly IntPtr ICON_SMALL = 0, ICON_BIG = 1, HWND_TOPMOST = -1, HWND_NOTOPMOST = -2;
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO info);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int CanShutdown();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Callback();

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

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
