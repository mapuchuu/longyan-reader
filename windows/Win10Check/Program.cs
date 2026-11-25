using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;

namespace Longyan;

/// Win10Check REPO: exits 1 if a check fails.
static class Program
{
    static int failures;

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "ok    " : "FAIL  ") + what);
        if (!ok) failures++;
    }

    [STAThread]
    static int Main(string[] args)
    {
        var repo = args.Length > 0 ? args[0] : ".";
        Gates();
        Glyphs(Path.Combine(repo, "windows", "LongyanReader"));
        Fonts();
        Installer(Path.Combine(repo, "windows", "installer", "LongyanReader.iss"));
        Console.WriteLine(failures == 0 ? "all passed" : $"{failures} failed");
        return failures == 0 ? 0 : 1;
    }

    // 1809, 1903, 1909, 2004, 20H2, 21H1, 21H2, 22H2; Windows 11 21H2, 22H2, 23H2, 24H2, 25H2.
    static void Gates()
    {
        (int Build, bool Is11, bool Mica, bool Caption, int Dark)[] table =
        {
            (17763, false, false, false, 19), (18362, false, false, false, 19), (18363, false, false, false, 19),
            (19041, false, false, false, 20), (19042, false, false, false, 20), (19043, false, false, false, 20),
            (19044, false, false, false, 20), (19045, false, false, false, 20),
            (22000, true, false, true, 20), (22621, true, true, true, 20), (22631, true, true, true, 20),
            (26100, true, true, true, 20), (26200, true, true, true, 20),
        };
        foreach (var t in table)
        {
            var got = (WindowsBuild.Is11On(t.Build), WindowsBuild.HasMicaOn(t.Build), WindowsBuild.HasCaptionColorOn(t.Build), WindowsBuild.DarkModeAttributeOn(t.Build));
            Check(got == (t.Is11, t.Mica, t.Caption, t.Dark),
                $"build {t.Build}: Windows {(t.Is11 ? 11 : 10)}, Mica {t.Mica}, caption colour {t.Caption}, dark title bar attribute {t.Dark}");
        }
        Console.WriteLine($"      this runner: build {WindowsBuild.RealBuild}, acting as {WindowsBuild.Build}");
    }

    /// Every private-use character in the app's code (the icon glyphs) must be in Segoe MDL2
    /// Assets, since Windows 10 has no Segoe Fluent Icons. The runner's copy of MDL2 may be
    /// newer than 1809's, so each code point must also be on a list checked by hand.
    static void Glyphs(string dir)
    {
        var found = new SortedDictionary<int, List<string>>();
        var pattern = new Regex(@"\\u([0-9A-Fa-f]{4})|&#x([0-9A-Fa-f]{4});");
        foreach (var file in Directory.GetFiles(dir, "*.cs"))
        {
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                var codes = lines[i].Where(c => c >= 0xE000 && c <= 0xF8FF).Select(c => (int)c).ToList();
                foreach (Match m in pattern.Matches(lines[i]))
                    codes.Add(int.Parse(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value, NumberStyles.HexNumber));
                foreach (var c in codes.Where(c => c >= 0xE000 && c <= 0xF8FF))
                {
                    if (!found.TryGetValue(c, out var at)) found[c] = at = new List<string>();
                    at.Add($"{Path.GetFileName(file)}:{i + 1}");
                }
            }
        }
        Check(found.Count > 0, $"{found.Count} icon glyphs in the app's code");
        var mdl2 = Typeface(@"C:\Windows\Fonts\segmdl2.ttf");
        var fluent = Typeface(@"C:\Windows\Fonts\SegoeIcons.ttf");
        Check(mdl2 != null, "Segoe MDL2 Assets on this runner");
        foreach (var (code, at) in found)
        {
            var name = $"U+{code:X4} ({string.Join(", ", at.Distinct())})";
            if (mdl2 != null) Check(mdl2.CharacterToGlyphMap.ContainsKey(code), name + " in Segoe MDL2 Assets");
            if (fluent != null) Check(fluent.CharacterToGlyphMap.ContainsKey(code), name + " in Segoe Fluent Icons");
            Check(Windows10Glyphs.Contains(code), name + " on the checked list");
        }
    }

    /// The glyphs the app uses, each on Microsoft's Segoe MDL2 Assets list (learn.microsoft.com,
    /// "Segoe MDL2 Assets icons"). A new glyph goes here once it's checked there; on a real
    /// Windows 10 PC, the welcome and settings windows show them all.
    static readonly HashSet<int> Windows10Glyphs = new()
    {
        0xE70D, // ChevronDown
        0xE70E, // ChevronUp
        0xE712, // More
        0xE721, // Search
        0xE73E, // CheckMark
        0xE765, // KeyboardClassic
        0xE774, // Globe (the card's cultural note)
        0xE7E8, // PowerButton
        0xE81C, // History
        0xE890, // View
        0xE895, // Sync
        0xE8C1, // Characters
        0xE8F1, // Library
        0xE962, // Mouse
        0xED15, // Feedback
        0xF2B7, // LocaleLanguage (the card's lost-in-translation note)
    };

    static GlyphTypeface? Typeface(string path)
    {
        try { return File.Exists(path) ? new GlyphTypeface(new Uri(path)) : null; }
        catch { return null; }
    }

    /// Which files WPF draws the app's font lists with here, for the log.
    static void Fonts()
    {
        foreach (var family in new[] { "Segoe UI Variable Text, Segoe UI", "Segoe UI", "Segoe Fluent Icons, Segoe MDL2 Assets", "Segoe MDL2 Assets", "Microsoft YaHei UI" })
        {
            var t = new System.Windows.Media.Typeface(new FontFamily(family), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
            var file = t.TryGetGlyphTypeface(out var g) ? Path.GetFileName(g.FontUri.LocalPath) : "none";
            Console.WriteLine($"      \"{family}\" draws with {file}");
        }
    }

    /// .NET 8 needs Windows 10 1607, and the app is checked down to 1809.
    static void Installer(string iss)
    {
        var text = File.ReadAllText(iss);
        Check(Regex.IsMatch(text, @"^MinVersion=10\.0\.17763\s*$", RegexOptions.Multiline), "installer: MinVersion=10.0.17763 (Windows 10 1809)");
    }
}
