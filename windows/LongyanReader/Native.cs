using System;
using System.Runtime.InteropServices;

namespace Longyan;

/// The shared core's C interface (Sources/LongyanBridge/Bridge.swift) and the dispatch calls
/// that run its main actor on this app's main thread.
static class Bridge
{
    const string Dll = "LongyanBridge.dll";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void Callback(IntPtr json);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_start(byte[] resources, byte[]? model, Callback cb);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern long ly_lookup(byte[] passage, int start, int end);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_prepare(byte[] passage, int start, int end);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_cancel_prepare();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_pick(long id, int token, int sense);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_use_suggested(long id, int token);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_toggle_all(long id, int token);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_toggle_row(long id, int token);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern long ly_open_part_of(long id);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_close(long id);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_warm_up();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_refresh(byte[]? model);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ly_shutdown();

    /// NUL-terminated UTF-8, as the bridge reads strings.
    public static byte[] Utf8(string s)
    {
        var bytes = new byte[System.Text.Encoding.UTF8.GetByteCount(s) + 1];
        System.Text.Encoding.UTF8.GetBytes(s, 0, s.Length, bytes, 0);
        return bytes;
    }

    public static string FromUtf8(IntPtr p) => Marshal.PtrToStringUTF8(p) ?? "";

    // libdispatch's hooks for running the main queue from another event loop, as
    // CoreFoundation's run loop does: a handle that's signalled when work is queued, and the
    // call that runs it. Swift's main actor runs on the main queue.
    [DllImport("dispatch.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr _dispatch_get_main_queue_handle_4CF();
    [DllImport("dispatch.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void _dispatch_main_queue_callback_4CF(IntPtr msg);
}
