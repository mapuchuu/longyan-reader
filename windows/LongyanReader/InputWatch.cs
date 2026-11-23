using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Longyan;

/// Mouse buttons, the wheel and keys anywhere on the desktop, watched through Raw Input: a copy
/// of each event, as the Mac's global event monitors give. Unlike a low-level hook it sits
/// outside the input path, so a busy app thread can't lag the system's mouse, and it doesn't
/// look like a keylogger to antivirus heuristics. It runs on its own thread (moves arrive
/// there at the mouse's rate) and hands only buttons, wheel and key presses to the app's thread.
static class InputWatch
{
    public enum Button { Left, Right, Middle }

    /// A button went down. `ours` is true over one of this app's windows.
    public static event Action<Button, POINT, bool>? Down;
    /// The primary button came up: where, the click count (2 for a double-click), whether it
    /// moved past the drag distance since it went down, and whether it went down over our window.
    public static event Action<POINT, int, bool, bool>? Up;
    public static event Action? Wheel;
    public static event Action? Key;

    static Dispatcher? app;
    static Thread? thread;

    public static void Start()
    {
        if (thread != null) return;
        app = Dispatcher.CurrentDispatcher;
        thread = new Thread(Run) { IsBackground = true, Name = "Longyan input watch" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    static void Run()
    {
        // A message-only window (parent HWND_MESSAGE) receives WM_INPUT for the whole desktop.
        var source = new HwndSource(new HwndSourceParameters("LongyanInputWatch") { ParentWindow = new IntPtr(-3), Width = 0, Height = 0, WindowStyle = 0 });
        source.AddHook(Hook);
        var devices = new[]
        {
            new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = RIDEV_INPUTSINK, hwndTarget = source.Handle },   // mouse
            new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 6, dwFlags = RIDEV_INPUTSINK, hwndTarget = source.Handle },   // keyboard
        };
        if (!RegisterRawInputDevices(devices, (uint)devices.Length, (uint)Marshal.SizeOf<RAWINPUTDEVICE>()))
            Core.Log($"{{\"event\":\"input-watch\",\"error\":{Marshal.GetLastWin32Error()}}}");
        Dispatcher.Run();
    }

    // Click counting and drags, kept on the watch thread.
    static POINT downAt, lastDownAt;
    static long lastDownTime = -1;
    static int clicks;
    static bool downOurs;

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_INPUT) return IntPtr.Zero;
        var size = 0u;
        var header = (uint)Marshal.SizeOf<RAWINPUTHEADER>();
        GetRawInputData(lParam, RID_INPUT, IntPtr.Zero, ref size, header);
        if (size == 0 || size > 256) return IntPtr.Zero;
        var buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (GetRawInputData(lParam, RID_INPUT, buffer, ref size, header) != size) return IntPtr.Zero;
            var type = Marshal.ReadInt32(buffer);
            if (type == RIM_TYPEMOUSE) Mouse((ushort)Marshal.ReadInt16(buffer, (int)header + 4));
            else if (type == RIM_TYPEKEYBOARD)
            {
                var flags = (ushort)Marshal.ReadInt16(buffer, (int)header + 2);
                if ((flags & RI_KEY_BREAK) == 0) Post(() => Key?.Invoke());
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return IntPtr.Zero;
    }

    static void Mouse(ushort flags)
    {
        if (flags == 0) return;   // a move
        // Raw Input reports the physical buttons; with the buttons swapped, the right one is primary.
        var swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
        ushort primaryDown = swapped ? RI_RIGHT_DOWN : RI_LEFT_DOWN, primaryUp = swapped ? RI_RIGHT_UP : RI_LEFT_UP;
        ushort secondaryDown = swapped ? RI_LEFT_DOWN : RI_RIGHT_DOWN;
        GetCursorPos(out var p);
        if ((flags & primaryDown) != 0)
        {
            var now = Environment.TickCount64;
            var near = Math.Abs(p.X - lastDownAt.X) <= GetSystemMetrics(SM_CXDOUBLECLK) / 2 && Math.Abs(p.Y - lastDownAt.Y) <= GetSystemMetrics(SM_CYDOUBLECLK) / 2;
            clicks = lastDownTime >= 0 && now - lastDownTime <= GetDoubleClickTime() && near ? clicks + 1 : 1;
            lastDownTime = now; lastDownAt = downAt = p;
            downOurs = Ours(p);
            var ours = downOurs;
            Post(() => Down?.Invoke(Button.Left, p, ours));
        }
        if ((flags & secondaryDown) != 0) { var ours = Ours(p); Post(() => Down?.Invoke(Button.Right, p, ours)); }
        if ((flags & RI_MIDDLE_DOWN) != 0) { var ours = Ours(p); Post(() => Down?.Invoke(Button.Middle, p, ours)); }
        if ((flags & primaryUp) != 0)
        {
            var dragged = Math.Abs(p.X - downAt.X) > GetSystemMetrics(SM_CXDRAG) || Math.Abs(p.Y - downAt.Y) > GetSystemMetrics(SM_CYDRAG);
            int count = clicks; bool ours = downOurs;
            Post(() => Up?.Invoke(p, count, dragged, ours));
        }
        if ((flags & (RI_WHEEL | RI_HWHEEL)) != 0) Post(() => Wheel?.Invoke());
    }

    /// True when the window under `p` belongs to this app (a card, the eye, a menu of ours).
    public static bool Ours(POINT p)
    {
        var root = GetAncestor(WindowFromPoint(p), GA_ROOT);
        if (root == IntPtr.Zero) return false;
        GetWindowThreadProcessId(root, out var pid);
        return pid == (uint)Environment.ProcessId;
    }

    static void Post(Action a) => app?.BeginInvoke(a, DispatcherPriority.Input);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usUsagePage, usUsage; public uint dwFlags; public IntPtr hwndTarget; }
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTHEADER { public uint dwType, dwSize; public IntPtr hDevice, wParam; }

    const int WM_INPUT = 0x00FF, RIM_TYPEMOUSE = 0, RIM_TYPEKEYBOARD = 1, GA_ROOT = 2;
    const uint RID_INPUT = 0x10000003, RIDEV_INPUTSINK = 0x100;
    const ushort RI_LEFT_DOWN = 0x1, RI_LEFT_UP = 0x2, RI_RIGHT_DOWN = 0x4, RI_RIGHT_UP = 0x8, RI_MIDDLE_DOWN = 0x10, RI_WHEEL = 0x400, RI_HWHEEL = 0x800, RI_KEY_BREAK = 1;
    const int SM_CXDOUBLECLK = 36, SM_CYDOUBLECLK = 37, SM_CXDRAG = 68, SM_CYDRAG = 69, SM_SWAPBUTTON = 23;

    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr input, uint command, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern uint GetDoubleClickTime();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, int flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
}
