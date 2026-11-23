using System.Windows.Media;
using Microsoft.Win32;

namespace Longyan;

/// The card's colours, light or dark as Windows is set, and the Mac app's tone colours
/// (Sources/LongyanReader/ToneColors.swift, the standard scheme).
static class Theme
{
    public static bool Dark = IsDark();

    public static Brush Card => Solid(Dark ? 0x2A2A2C : 0xFCFCFC);
    public static Brush Edge => Solid(Dark ? 0x3E3E42 : 0xE0E0E0);
    public static Brush Primary => Solid(Dark ? 0xF2F2F2 : 0x1C1C1E);
    public static Brush Secondary => Solid(Dark ? 0xA8A8AD : 0x6C6C70);
    public static Brush Tertiary => Solid(Dark ? 0x7C7C80 : 0x9C9CA0);
    public static Brush Accent => Solid(Dark ? 0x5AA9FF : 0x0A66D0);
    public static Brush NoteFill => Solid(Dark ? 0x35353A : 0xF1F1F3);

    /// The Mac renders' backdrop (underPageBackgroundColor).
    public static Brush Backdrop => Solid(Dark ? 0x1E1E1E : 0x8C8C8C);

    public static readonly FontFamily Latin = new("Segoe UI");
    public static readonly FontFamily Chinese = new("Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI");

    // Tones 1 to 4: brick, sage, slate, violet.
    static readonly (double r, double g, double b)[] light = { (0.66, 0.33, 0.30), (0.29, 0.53, 0.38), (0.29, 0.45, 0.65), (0.50, 0.38, 0.64) };
    static readonly (double r, double g, double b)[] dark = { (0.89, 0.62, 0.58), (0.62, 0.80, 0.66), (0.63, 0.74, 0.89), (0.76, 0.67, 0.88) };
    static Brush[] tones => Enumerate();

    public static Brush Hanzi(int tone) => tone is >= 1 and <= 4 ? tones[tone - 1] : Primary;
    public static Brush PinyinColor(int tone) => tone is >= 1 and <= 4 ? tones[tone - 1] : Secondary;

    static Brush[] Enumerate()
    {
        var set = Dark ? dark : light;
        var brushes = new Brush[4];
        for (var i = 0; i < 4; i++)
        {
            var b = new SolidColorBrush(Color.FromRgb((byte)(set[i].r * 255 + 0.5), (byte)(set[i].g * 255 + 0.5), (byte)(set[i].b * 255 + 0.5)));
            b.Freeze();
            brushes[i] = b;
        }
        return brushes;
    }

    static Brush Solid(int rgb)
    {
        var b = new SolidColorBrush(Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        b.Freeze();
        return b;
    }

    static bool IsDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }
}
