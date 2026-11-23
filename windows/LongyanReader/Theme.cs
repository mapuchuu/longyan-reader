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
    public static Brush Accent => Solid(0x0A60FF);   // macOS's control accent (blue), as the Mac renders it in both modes

    /// Black (light) or white (dark) at `alpha`: the Mac card's Color.primary.opacity(x).
    public static Brush Ink(double alpha) => Solid(Dark ? 0xFFFFFF : 0x000000, alpha);

    /// The Mac card's Color.primary.opacity(x): its primary is itself at 0.85, so this is
    /// black or white at 0.85 × x.
    public static Brush Fill(double x) => Ink(0.85 * x);

    public static Brush Surface => Solid(Dark ? 0x1F1F21 : 0xFFFFFF);
    public static Brush Hairline => Fill(0.10);
    public static Brush Divider => Fill(0.08);
    public static Brush NoteFill => Fill(0.045);
    public static Brush RowHover => Fill(0.05);
    public static Brush RowPressed => Fill(0.09);
    public static Brush ButtonHover => Fill(0.07);
    public static Brush Placeholder => Fill(0.12);

    public static Brush NoteLost => Solid(Dark ? 0xE6A3C2 : 0xB05C80);
    public static Brush NoteCulture => Solid(Dark ? 0x94C7C2 : 0x458280);

    /// The Mac renders' backdrop (underPageBackgroundColor), for the gallery.
    public static Brush Backdrop => Solid(Dark ? 0x282828 : 0x969696);

    // Latin text in Segoe UI Variable (Segoe UI before Windows 11), Chinese in Microsoft YaHei UI.
    public static readonly FontFamily Text = new("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI");
    public static readonly FontFamily Chinese = new("Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI");
    /// YaHei's characters fill more of the em than PingFang's: this matches their height.
    public const double ChineseScale = 0.92;
    /// PingFang Medium is heavier than YaHei's Regular, and YaHei has no Medium: Bold stands in.
    public static System.Windows.FontWeight ChineseWeight(System.Windows.FontWeight w) =>
        w.ToOpenTypeWeight() >= 500 ? System.Windows.FontWeights.Bold : w;
    /// Segoe draws a little smaller and narrower than San Francisco at the same size: Latin
    /// text is set this much larger, which matches the Mac's x-height and most of its width
    /// (measured on the gallery's cards). Line heights stay the Mac's.
    public const double LatinScale = 1.04;
    public static double Latin(double size) => size * LatinScale;
    /// San Francisco's Medium is about as heavy as Segoe's Semibold, which has no Medium.
    public static System.Windows.FontWeight LatinWeight(System.Windows.FontWeight w) =>
        w.ToOpenTypeWeight() >= 500 ? System.Windows.FontWeights.SemiBold : w;
    /// How much wider San Francisco sets a line than Segoe at `LatinScale`, by size: Latin text
    /// is stretched this much across, so lines are as long, and break, where the Mac's do.
    /// San Francisco tightens its letters as the size grows, so it's wider at small sizes and a
    /// little narrower around 16. Measured on the gallery's cards.
    public static double LatinStretch(double size)
    {
        (double Size, double Factor)[] table = { (10, 1.035), (12, 1.035), (13, 1.01), (14, 1.0), (15, 0.99), (16, 0.98), (17, 0.98), (19, 1.0) };
        if (size <= table[0].Size) return table[0].Factor;
        for (var i = 1; i < table.Length; i++)
            if (size <= table[i].Size)
            {
                var (a, b) = (table[i - 1], table[i]);
                return a.Factor + (b.Factor - a.Factor) * (size - a.Size) / (b.Size - a.Size);
            }
        return table[^1].Factor;
    }
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

    /// Whether Windows is set to dark for apps now (CardWindow re-reads it when that changes).
    /// Dev only: --show --appearance light|dark holds the cards in one, whatever Windows is set to.
    public static bool? Forced;

    public static bool SystemDark() => Forced ?? IsDark();

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
