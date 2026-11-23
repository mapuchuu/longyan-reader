using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Longyan;

/// The app in front: its process name (a UWP app's own, not its frame host's), its program's
/// path, whether Ctrl+C there copies (not in terminals, Emacs or Vim, where it interrupts or
/// starts a command, nor in apps run as administrator, which can't be sent keys from here),
/// and whether an unreadable double-click there may be text worth copying (the eye).
sealed record ForegroundApp(string Process, string Path, bool CopyWorks, bool MayBeText)
{
    // Where Ctrl+C isn't copy.
    static readonly HashSet<string> terminalClasses = new()
    {
        "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "PuTTY", "mintty", "VirtualConsoleClass", "Emacs", "Vim",
    };
    static readonly HashSet<string> terminalProcesses = new()
    {
        "windowsterminal", "putty", "kitty", "mintty", "conemu", "conemu64", "alacritty", "wezterm-gui", "emacs", "gvim",
    };
    // Where an unreadable double-click isn't a text selection: the desktop, the taskbar, file
    // windows, dialogs and spreadsheets.
    static readonly HashSet<string> notTextClasses = new()
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "CabinetWClass", "ExploreWClass", "#32770",
    };
    static readonly HashSet<string> notTextProcesses = new()
    {
        "explorer", "excel", "totalcmd", "totalcmd64", "dopus",
    };

    /// The app in front, or null for none or this app.
    public static ForegroundApp? Get()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;
        var cls = ClassOf(hwnd);
        GetWindowThreadProcessId(hwnd, out var pid);
        if (cls == "ApplicationFrameWindow")
        {
            var core = FindWindowEx(hwnd, IntPtr.Zero, "Windows.UI.Core.CoreWindow", null);
            if (core != IntPtr.Zero) GetWindowThreadProcessId(core, out pid);
        }
        if (pid == (uint)Environment.ProcessId) return null;
        var path = ImagePath(pid);
        if (path == null) return null;
        var process = System.IO.Path.GetFileNameWithoutExtension(path).ToLowerInvariant();
        // An app run as administrator can be named but not read or sent keys from here.
        var lower = OpenProcess(PROCESS_QUERY_INFORMATION, false, pid);
        var reachable = lower != IntPtr.Zero;
        if (reachable) CloseHandle(lower);
        var copies = reachable && !terminalClasses.Contains(cls) && !terminalProcesses.Contains(process);
        return new ForegroundApp(process, path, copies, copies && !notTextClasses.Contains(cls) && !notTextProcesses.Contains(process));
    }

    /// The name to show for an app: its program's description ("Microsoft Edge"), else its file name.
    public static string NameOf(string path)
    {
        try
        {
            var d = System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileDescription;
            if (!string.IsNullOrWhiteSpace(d)) return d.Trim();
        }
        catch { }
        return System.IO.Path.GetFileNameWithoutExtension(path);
    }

    static string ClassOf(IntPtr hwnd)
    {
        var cls = new StringBuilder(256);
        GetClassName(hwnd, cls, cls.Capacity);
        return cls.ToString();
    }

    static string? ImagePath(uint pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            var size = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
        }
        finally { CloseHandle(h); }
    }

    const uint PROCESS_QUERY_INFORMATION = 0x400, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? cls, string? title);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
}
