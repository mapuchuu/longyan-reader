using System;
using System.Windows.Media;
using Microsoft.Win32;

namespace Longyan;

/// The card's colours and fonts, as notes/card-spec.md gives the Mac card's: macOS's label
/// colours (black or white at an alpha), the system blue, and the tone colours
/// (Sources/LongyanReader/ToneColors.swift, the standard scheme). Light or dark as Windows is set.
static class Theme
{
    public static bool Dark = IsDark();

    // Label colours: primary, secondary and tertiary text.
    public static Brush Primary => Ink(Dark ? 0.85 : 0.85);
    public static Brush Secondary => Ink(Dark ? 0.55 : 0.50);
    public static Brush Tertiary => Ink(Dark ? 0.25 : 0.26);
    public static Brush Accent => Solid(Dark ? 0x0A84FF : 0x007AFF);

    /// Black (light) or white (dark) at `alpha`: the Mac card's Color.primary.opacity(x).
    public static Brush Ink(double alpha) => Solid(Dark ? 0xFFFFFF : 0x000000, alpha);

    public static Brush Surface => Solid(Dark ? 0x1F1F21 : 0xFFFFFF);
    public static Brush Hairline => Ink(0.10);
    public static Brush Divider => Ink(0.08);
    public static Brush NoteFill => Ink(0.045);
    public static Brush RowHover => Ink(0.05);
    public static Brush RowPressed => Ink(0.09);
    public static Brush ButtonHover => Ink(0.07);
    public static Brush Placeholder => Ink(0.12);

    public static Brush NoteLost => Solid(Dark ? 0xE6A3C2 : 0xB05C80);
    public static Brush NoteCulture => Solid(Dark ? 0x94C7C2 : 0x458280);

    /// The Mac renders' backdrop (underPageBackgroundColor), for the gallery.
    public static Brush Backdrop => Solid(Dark ? 0x1E1E1E : 0x8C8C8C);

    // Latin text in Segoe UI Variable (Segoe UI before Windows 11), Chinese in Microsoft YaHei UI.
    public static readonly FontFamily Text = new("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI");
    public static readonly FontFamily Chinese = new("Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI");
    /// YaHei's characters fill more of the em than PingFang's: this matches their height.
    public const double ChineseScale = 0.92;
    /// PingFang Medium is heavier than YaHei's Regular, and YaHei has no Medium: Bold stands in.
    public static System.Windows.FontWeight ChineseWeight(System.Windows.FontWeight w) =>
        w.ToOpenTypeWeight() >= 500 ? System.Windows.FontWeights.Bold : w;
    /// San Francisco's line spacing as a multiple of the size.
    public const double LineFactor = 1.2;
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    // Tones 1 to 4: brick, sage, slate, violet.
    static readonly int[] lightTones = { 0xA8544C, 0x4A8761, 0x4A73A6, 0x8061A3 };
    static readonly int[] darkTones = { 0xE39E94, 0x9ECCA8, 0xA1BDE3, 0xC2ABE0 };

    /// A character's colour: its tone's, or secondary for the neutral tone.
    public static Brush Hanzi(int tone) => tone is >= 1 and <= 4 ? Solid((Dark ? darkTones : lightTones)[tone - 1]) : Secondary;
    public static Brush PinyinColor(int tone) => Hanzi(tone);

    static Brush Solid(int rgb, double alpha = 1)
    {
        var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
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
