using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Longyan;

static partial class Program
{
    /// Classic Notepad on Windows 11 (the runner's, once the Store one is gone) shows "A new
    /// version of Notepad is available" over its text, which leaves the short window room for
    /// two lines and a half. Ctrl+End (each eye case presses it) then scrolls by a line, and
    /// a place read before it points at the line below. Taller by what's missing, so every line
    /// shows as on Windows Server, where there's no bar.
    static void FitNotepad(IntPtr window)
    {
        var edit = FindWindowEx(window, IntPtr.Zero, "Edit", null);
        if (edit == IntPtr.Zero) { Console.WriteLine("[notepad] no Edit box"); return; }
        var lines = (int)SendMessage(edit, EM_GETLINECOUNT, IntPtr.Zero, IntPtr.Zero);
        int Y(int line) => (short)((long)SendMessage(edit, EM_POSFROMCHAR, SendMessage(edit, EM_LINEINDEX, (IntPtr)line, IntPtr.Zero), IntPtr.Zero) >> 16 & 0xFFFF);
        var lineHeight = lines > 1 ? Y(1) - Y(0) : 0;
        GetClientRect(edit, out var c);
        var need = lines * lineHeight + 4;
        Console.WriteLine($"[notepad] {lines} lines of {lineHeight} px; the text box is {c.Bottom} px tall");
        if (lineHeight <= 0 || c.Bottom >= need) return;
        GetWindowRect(window, out var r);
        SetWindowPos(window, IntPtr.Zero, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top + need - c.Bottom, 0x4 /* SWP_NOZORDER */);
        Thread.Sleep(300);
        GetClientRect(edit, out c);
        Console.WriteLine($"[notepad] made it taller: the text box is {c.Bottom} px");
    }

    /// For the log: Notepad's selection (character offsets), its first line on screen, and
    /// which window has the focus.
    internal static string NotepadState(IntPtr window)
    {
        var edit = FindWindowEx(window, IntPtr.Zero, "Edit", null);
        var sb = new StringBuilder(256);
        var fg = GetForegroundWindow();
        GetWindowText(fg, sb, 256);
        GetWindowThreadProcessId(fg, out var pid);
        string name;
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch { name = "?"; }
        if (edit == IntPtr.Zero) return $"no Edit box; in front: {name} \"{sb}\"";
        int start = 0, end = 0;
        SendMessage(edit, EM_GETSEL, ref start, ref end);
        var first = (int)SendMessage(edit, EM_GETFIRSTVISIBLELINE, IntPtr.Zero, IntPtr.Zero);
        return $"selection {start}..{end}, first line shown {first}; in front: {name} \"{sb}\"";
    }

    const int EM_GETSEL = 0xB0, EM_GETLINECOUNT = 0xBA, EM_LINEINDEX = 0xBB, EM_GETFIRSTVISIBLELINE = 0xCE, EM_POSFROMCHAR = 0xD6;
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string? title);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, ref int w, ref int l);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
}
