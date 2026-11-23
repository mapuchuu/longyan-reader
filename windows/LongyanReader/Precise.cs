using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Longyan;

/// Waits to the millisecond, as the Mac's asyncAfter does. Task.Delay ends on the system's
/// 15.6 ms timer ticks; a high-resolution waitable timer (Windows 10 1803 and later) doesn't,
/// and doesn't change the timer resolution for the rest of the system.
static class Precise
{
    /// Done `ms` after the Stopwatch timestamp `from` (at once if that has passed).
    public static Task Until(long from, double ms)
    {
        var left = ms - Stopwatch.GetElapsedTime(from).TotalMilliseconds;
        if (left <= 0.5) return Task.CompletedTask;
        var timer = CreateWaitableTimerExW(IntPtr.Zero, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
        if (timer == IntPtr.Zero) return Task.Delay(TimeSpan.FromMilliseconds(left));
        var handle = new SafeWaitHandle(timer, ownsHandle: true);
        var due = -(long)(left * 10_000);   // relative, in 100 ns
        if (!SetWaitableTimer(handle, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
        {
            handle.Dispose();
            return Task.Delay(TimeSpan.FromMilliseconds(left));
        }
        var done = new TaskCompletionSource();
        var wait = new Timer(handle);
        var registered = ThreadPool.RegisterWaitForSingleObject(wait, (_, _) => done.TrySetResult(), null, Timeout.Infinite, executeOnlyOnce: true);
        done.Task.ContinueWith(_ => { registered.Unregister(null); wait.Dispose(); }, TaskScheduler.Default);
        return done.Task;
    }

    sealed class Timer : WaitHandle { public Timer(SafeWaitHandle h) => SafeWaitHandle = h; }

    const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x2, TIMER_ALL_ACCESS = 0x1F0003;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWaitableTimerExW(IntPtr attributes, string? name, uint flags, uint access);
    [DllImport("kernel32.dll")] static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long due, int period, IntPtr completion, IntPtr arg, bool resume);
}
