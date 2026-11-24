using System;
using System.Runtime.InteropServices;

namespace Longyan;

/// The Windows build the app runs on, and the parts of Windows that depend on it. The oldest
/// supported is Windows 10 1809 (17763); the installer refuses older ones.
///
/// Windows 10 has no Mica (22H2 and later), no caption colour and no Segoe UI Variable or
/// Segoe Fluent Icons (Windows 11), and before 20H1 its dark title bar is attribute 19, not 20.
/// The card is drawn by the app and looks the same; the windows around it get square corners
/// and a solid background, as Windows 10's own windows have.
///
/// LONGYAN_WINDOWS_BUILD=19045 (dev and CI only) makes the app act as on that build, so a
/// Windows 11 runner can draw the Windows 10 look (gallery.yml). windows/Win10Check tests the
/// gates themselves.
static class WindowsBuild
{
    public static readonly int RealBuild = Environment.OSVersion.Version.Build;
    public static readonly int Build = Faked(Environment.GetEnvironmentVariable("LONGYAN_WINDOWS_BUILD")) ?? RealBuild;
    public static bool IsFaked => Build != RealBuild;

    public const int Windows10_1809 = 17763, Windows10_20H1 = 19041, Windows11 = 22000, Windows11_22H2 = 22621;

    public static bool Is11 => Is11On(Build);
    public static bool HasMica => HasMicaOn(Build);
    public static bool HasCaptionColor => HasCaptionColorOn(Build);
    public static int DarkModeAttribute => DarkModeAttributeOn(Build);

    // The same, for any build (Win10Check).
    public static bool Is11On(int build) => build >= Windows11;
    /// DWMWA_SYSTEMBACKDROP_TYPE (38) came in 22H2. 21H2 had an undocumented attribute instead.
    public static bool HasMicaOn(int build) => build >= Windows11_22H2;
    /// DWMWA_CAPTION_COLOR (35), DWMWA_WINDOW_CORNER_PREFERENCE (33) and the border colour: Windows 11.
    public static bool HasCaptionColorOn(int build) => build >= Windows11;
    /// DWMWA_USE_IMMERSIVE_DARK_MODE is 20 from 20H1 (19041); 1809 to 1909 know it as 19.
    /// 18985 is the first preview build that took 20.
    public static int DarkModeAttributeOn(int build) => build >= 18985 ? 20 : 19;

    /// The fonts as Windows 11 has them, or as Windows 10 does: the same lists, less the
    /// Windows 11 fonts, which Windows 10 would skip anyway. Spelled out, so a faked build
    /// draws with what Windows 10 has.
    public static string Fonts(string windows11, string windows10) => Is11 ? windows11 : windows10;

    static int? Faked(string? value) =>
        int.TryParse(value, out var b) && b >= 10240 && b < 100000 ? b : null;

    /// The title bar dark or light, with the attribute this build knows. On Windows 10 a title
    /// bar already on screen keeps its old colour until the frame is drawn again, so it's redrawn.
    public static void DarkTitleBar(IntPtr hwnd, bool dark)
    {
        if (hwnd == IntPtr.Zero) return;
        try
        {
            var on = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DarkModeAttribute, ref on, 4);
            if (!Is11 && IsWindowVisible(hwnd))
                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        catch { }
    }

    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
