using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace Longyan;

/// Chromium browsers (Chrome, Edge, Brave, Opera, Vivaldi), Electron apps (VS Code, Slack,
/// QQ) and Firefox build a page's accessibility tree only once a UI Automation client asks for
/// it, and building takes a moment (Firefox: 2 to 6 s on CI). Until then the first selection reads as nothing. As the Mac does
/// (SelectionReader.prepare, on each app activation and again 2 s later), the tree is asked
/// for when such a window comes to the front, so it's there by the time text is selected.
/// LONGYAN_WAKE=0 turns this off (CompatCheck measures both).
static class AccessibilityWake
{
    static IntPtr hook;
    static WinEventProc? proc;   // kept alive while the hook is set
    static int busy;

    public static void Start()
    {
        if (Environment.GetEnvironmentVariable("LONGYAN_WAKE") == "0") return;
        proc = OnForeground;
        hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        Wake(GetForegroundWindow());
    }

    static void OnForeground(IntPtr h, uint e, IntPtr hwnd, int obj, int child, uint thread, uint time) => Wake(hwnd);

    static void Wake(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsChromium(hwnd)) return;
        _ = Ask(hwnd, 0);
        // An app still starting up may not have its page yet.
        _ = Ask(hwnd, 2000);
    }

    /// Chromium's top-level windows, in browsers and Electron apps alike, and Firefox's.
    static bool IsChromium(IntPtr hwnd)
    {
        var cls = new StringBuilder(64);
        GetClassName(hwnd, cls, cls.Capacity);
        return cls.ToString() is "Chrome_WidgetWin_1" or "MozillaWindowClass";
    }

    /// The window's document through UI Automation, off the app's thread and given up after
    /// 1 s: asking is what turns the tree on. One at a time, so a hung app can't pile them up.
    static async Task Ask(IntPtr hwnd, int delay)
    {
        if (delay > 0) await Task.Delay(delay);
        if (delay > 0 && GetForegroundWindow() != hwnd) return;
        if (Interlocked.Exchange(ref busy, 1) == 1) return;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var work = Task.Run(() =>
        {
            try
            {
                var root = AutomationElement.FromHandle(hwnd);
                var doc = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document));
                return doc != null && doc.TryGetCurrentPattern(TextPattern.Pattern, out _) ? "text" : doc != null ? "document" : "none";
            }
            catch (Exception) { return "failed"; }
        });
        var done = await Task.WhenAny(work, Task.Delay(1000)) == work;
        _ = work.ContinueWith(_ => Interlocked.Exchange(ref busy, 0));
        if (Core.Logging) Core.Log($"{{\"event\":\"wake\",\"found\":\"{(done ? work.Result : "no answer")}\",\"ms\":{clock.ElapsedMilliseconds},\"later\":{(delay > 0 ? "true" : "false")}}}");
    }

    delegate void WinEventProc(IntPtr hook, uint e, IntPtr hwnd, int obj, int child, uint thread, uint time);
    const uint EVENT_SYSTEM_FOREGROUND = 3, WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 2;
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
}
