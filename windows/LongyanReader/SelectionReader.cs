using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Longyan;

/// What the reader selected, with the text around it so the core can read the sentence.
/// `OneLine`: the selection's text is on one line (its rects share a line), so the eye goes
/// beside it whatever the line's height.
/// `Trimmed`: white space at its end (a line break, a space) was left out of `Bounds`, and its
/// highlight on screen goes further.
record Selected(string Passage, int Start, int End, Rect? Bounds, bool OneLine = false, bool Trimmed = false);

/// Reads the selection in another app, as the Mac app does with Accessibility: through UI
/// Automation's text pattern when the app offers one, else by copying (Ctrl+C) and putting
/// the clipboard back.
static class SelectionReader
{
    const int Around = 200;   // characters of context each way

    public enum Found { Selection, NothingSelected, Unreadable }

    /// What a probe found, the focused element's kind and where it is on screen (device pixels).
    public sealed record Probed(Found Found, Selected? Selection, ControlType? Role = null, Rect? Area = null);

    public static Selected? ReadAutomation() => Probe().Selection;

    static Task<Probed>? pending;

    /// UI Automation on a thread of its own, given up after `timeout`: an app that doesn't
    /// answer must not freeze ours (the Mac caps its Accessibility calls at 0.5 s the same way).
    /// While an earlier probe is still stuck in a hung app, a new one doesn't pile up behind it.
    public static async Task<Probed> ProbeAsync(int timeout = 500)
    {
        if (pending is { IsCompleted: false }) return new Probed(Found.Unreadable, null);
        var work = pending = Task.Run(Probe);
        return await Task.WhenAny(work, Task.Delay(timeout)) == work ? work.Result : new Probed(Found.Unreadable, null);
    }

    /// The focused element's selection; or that it has a text pattern and nothing is selected;
    /// or that the app doesn't say (no text pattern, or no answer). Never a password field's.
    public static Probed Probe()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return new Probed(Found.Unreadable, null);
            var info = element.Current;
            var role = info.ControlType;
            Rect? area = info.BoundingRectangle is { IsEmpty: false } r0 ? r0 : null;
            if (info.IsPassword) return new Probed(Found.NothingSelected, null, role, area);
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern text) return new Probed(Found.Unreadable, null, role, area);
            var selection = text.GetSelection().FirstOrDefault();
            if (selection == null) return new Probed(Found.NothingSelected, null, role, area);
            var selected = selection.GetText(-1);
            if (string.IsNullOrEmpty(selected)) return new Probed(Found.NothingSelected, null, role, area);

            var wide = selection.Clone();
            wide.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -Around);
            wide.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, Around);
            var before = wide.Clone();
            before.MoveEndpointByRange(TextPatternRangeEndpoint.End, selection, TextPatternRangeEndpoint.Start);
            var passage = wide.GetText(-1);
            var start = before.GetText(-1).Length;
            // Some apps report ranges that don't line up: fall back to the selection alone.
            if (start + selected.Length > passage.Length || passage.Substring(start, selected.Length) != selected)
            {
                passage = selected; start = 0;
            }
            var (bounds, oneLine) = Bounds(selection);
            return new Probed(Found.Selection, new Selected(passage, start, start + selected.Length, bounds, oneLine, selected.TrimEnd().Length < selected.Length), role, area);
        }
        catch (Exception)
        {
            return new Probed(Found.Unreadable, null);   // the app went away or doesn't answer
        }
    }

    /// Where the selection is on screen: its lines' rectangles together, as the Mac's
    /// AXBoundsForRange gives. Notepad on Windows 11 counts the page's top margin (16 at 100%)
    /// as part of the first line, which put the eye that much above the text: a top line taller
    /// than the next line by a quarter and than 1.5 em (Microsoft YaHei's line is about 1.32 em)
    /// is cut to a normal line's height from the bottom, where its text is.
    /// White space at the selection's end is left out: a double-click in Chromium on Windows
    /// takes the space after the word, and a line's selection its line break, which the Mac's
    /// double-click doesn't, and the eye would sit that much further right.
    /// Also whether its text is on one line: every rect overlaps the first one by more than half
    /// of the lower of the two (a line break past the end, its rect on the next line, is left
    /// out with the white space). Never throws: no position is better than no eye.
    static (Rect?, bool) Bounds(TextPatternRange selection)
    {
        try
        {
            selection = WithoutTrailingSpace(selection);
            var rects = selection.GetBoundingRectangles().Where(x => !x.IsEmpty && x.Height > 0 && double.IsFinite(x.Left) && double.IsFinite(x.Top)).ToArray();
            if (rects.Length == 0) return (null, false);
            var top = rects.OrderBy(x => x.Top).First();
            var oneLine = rects.All(x => Math.Min(x.Bottom, top.Bottom) - Math.Max(x.Top, top.Top) > Math.Min(x.Height, top.Height) / 2);
            var line = LineHeight(selection, rects, top);
            if (line > 0 && top.Height > line * 1.25)
            {
                var cut = top.Bottom - line;
                for (var i = 0; i < rects.Length; i++)
                    if (rects[i].Top < cut && rects[i].Bottom > cut) rects[i] = new Rect(rects[i].X, cut, rects[i].Width, rects[i].Bottom - cut);
            }
            var r = rects[0];
            foreach (var x in rects.Skip(1)) r.Union(x);
            return (r, oneLine);
        }
        catch (Exception) { return (null, false); }
    }

    /// The selection as drawn, read from the screen within its rect (a little wider): the right
    /// edge of its highlight and the middle of its text's ink. On the Mac the line's box, its
    /// highlight and its ink share a centre; on Windows the box is up to 2 px off the ink, and its
    /// right edge up to a point off the highlight's. Null for either when it can't be told (no
    /// one colour covers a third of the rect, or the ink is too short to be a line of text).
    public static (double? Right, double? InkMid) Drawn(Rect b, double s)
    {
        try
        {
            // Classic Notepad's rects fall short of its highlight by up to a character at 175%.
            int x0 = (int)Math.Floor(b.Left), x1 = (int)Math.Ceiling(b.Right + b.Height + 6 * s), y0 = (int)Math.Floor(b.Top), y1 = (int)Math.Ceiling(b.Bottom);
            int w = x1 - x0, h = y1 - y0;
            if (w < 2 || h < 4 || w * h > 4_000_000) return (null, null);
            using var bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(x0, y0, 0, 0, new System.Drawing.Size(w, h));
            var data = bmp.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            var px = new int[w * h];
            for (var y = 0; y < h; y++) Marshal.Copy(data.Scan0 + y * data.Stride, px, y * w, w);
            bmp.UnlockBits(data);
            static int Diff(int a, int c) => Math.Abs(((a >> 16) & 255) - ((c >> 16) & 255)) + Math.Abs(((a >> 8) & 255) - ((c >> 8) & 255)) + Math.Abs((a & 255) - (c & 255));
            // The highlight: the commonest colour inside the rect.
            var inside = Math.Min((int)Math.Round(b.Right) - x0, w);
            var counts = new Dictionary<int, int>();
            for (var y = 0; y < h; y++) for (var x = 0; x < inside; x++) { var c = px[y * w + x] & 0xFFFFFF; counts[c] = counts.GetValueOrDefault(c) + 1; }
            if (counts.Count == 0) return (null, null);
            var (bg, n) = counts.MaxBy(kv => kv.Value);
            if (n * 3 < inside * h) return (null, null);
            // Its rows: Chromium's is the font's height, less than the line's box.
            int hTop = -1, hBottom = -1;
            for (var y = 0; y < h; y++)
            {
                var k = 0;
                for (var x = 0; x < inside; x++) if (Diff(px[y * w + x], bg) <= 6) k++;
                if (k * 5 < inside) continue;
                if (hTop < 0) hTop = y;
                hBottom = y;
            }
            if (hTop < 0 || hBottom - hTop < 3) return (null, null);
            // A caret (Notepad shows one at the selection's moving end, blinking): a column of one
            // colour, not the highlight's, all the way down the highlight. Left out of the ink, and
            // counted as highlight at the edge.
            var caret = new bool[w];
            // The page past the selection's end: the commonest colour there.
            var after = new Dictionary<int, int>();
            for (var y = hTop; y <= hBottom; y++) for (var x = inside; x < w; x++) { var c = px[y * w + x] & 0xFFFFFF; after[c] = after.GetValueOrDefault(c) + 1; }
            var page = after.Count > 0 ? after.MaxBy(kv => kv.Value).Key : -1;
            for (var x = 0; x < w; x++)
            {
                // Its middle rows (its height needn't be the highlight's).
                int c0y = hTop + (hBottom - hTop) / 4, c1y = hBottom - (hBottom - hTop) / 4;
                // Mostly one colour (over the text's ink it inverts that instead), no highlight in it.
                var col = new Dictionary<int, int>();
                var lit = false;
                for (var y = c0y; y <= c1y && !lit; y++) { var c = px[y * w + x] & 0xFFFFFF; lit = Diff(c, bg) <= 6; col[c] = col.GetValueOrDefault(c) + 1; }
                if (lit || col.Count == 0) continue;
                var (c0, k0) = col.MaxBy(kv => kv.Value);
                if (page >= 0 && Diff(c0, page) <= 6) continue;
                // The caret inverts what it covers: over the highlight, the highlight's inverse.
                // (A glyph's stem next to the highlight is the text's colour, not that.)
                caret[x] = k0 * 10 >= (c1y - c0y + 1) * 6 && Diff(c0, ~bg & 0xFFFFFF) <= 48;
            }
            // Its right edge: the last column holding it, row by row in its middle rows, the median
            // (a rich edit box draws some rows of it a few pixels longer than the rest).
            var ends = new List<int>();
            int m0 = hTop + (hBottom - hTop) / 4, m1 = hBottom - (hBottom - hTop) / 4;
            for (var y = m0; y <= m1; y++)
                for (var x = w - 1; x >= 0; x--)
                {
                    if (Diff(px[y * w + x], bg) > 6) continue;
                    var end = x;
                    while (end + 1 < w && caret[end + 1] && end - x < 3) end++;
                    ends.Add(end);
                    break;
                }
            ends.Sort();
            var right = ends.Count > 0 ? ends[ends.Count / 2] : -1;
            double? edge = right >= 0 && x0 + right + 1 >= b.Right - b.Height && x0 + right + 1 <= b.Right + b.Height ? x0 + right + 1 : null;
            // The text's ink: far from the highlight's colour, between its first and last pixel on
            // each row (not the page around it: Chromium's highlight is shorter than the box, and
            // a highlighted line break may stand taller than the text), within the rect.
            var last = Math.Min(edge is double e ? (int)e - x0 : inside, inside);
            int top = -1, bottom = -1;
            for (var y = hTop; y <= hBottom; y++)
            {
                int lo = -1, hi = -1;
                for (var x = 0; x < w; x++) if (Diff(px[y * w + x], bg) <= 6) { if (lo < 0) lo = x; hi = x; }
                if (lo < 0) continue;
                for (var x = lo + 1; x < Math.Min(hi, last); x++)
                {
                    if (caret[x] || Diff(px[y * w + x], bg) <= 150) continue;
                    if (top < 0) top = y;
                    bottom = y;
                    break;
                }
            }
            double? mid = top >= 0 && bottom - top + 1 >= (hBottom - hTop + 1) * 0.4 ? y0 + (top + bottom + 1) / 2.0 : null;
            return (edge, mid);
        }
        catch (Exception) { return (null, null); }
    }

    static TextPatternRange WithoutTrailingSpace(TextPatternRange selection)
    {
        try
        {
            var text = selection.GetText(-1);
            var trimmed = text.TrimEnd();
            if (trimmed.Length == text.Length || trimmed.Length == 0) return selection;
            var r = selection.Clone();
            // One step a character; apps count a line break as one or two, so check as it goes.
            for (var i = 0; i < 8 && r.GetText(-1).Length > trimmed.Length; i++)
                if (r.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, -1) == 0) break;
            return r.GetText(-1) == trimmed ? r : selection;
        }
        catch (Exception) { return selection; }
    }

    /// A normal line's height near the selection's top line: the selection's next line, else
    /// the document's line after or before it, else about 1.33 of the font (Microsoft YaHei's
    /// line). Zero when there's nothing to go by.
    static double LineHeight(TextPatternRange selection, Rect[] rects, Rect top)
    {
        // Only worth the extra calls when the top line is taller than its font would make it.
        // A font size the app doesn't give: no cut (a heading followed by small text isn't a margin).
        var em = Em(selection, top);
        if (em <= 0 || top.Height <= em * 1.5) return 0;
        foreach (var x in rects) if (x.Top >= top.Bottom - 1 && x.Height > 0) return x.Height;
        foreach (var step in new[] { 1, -1 })
        {
            try
            {
                var r = selection.Clone();
                if (step > 0) r.MoveEndpointByRange(TextPatternRangeEndpoint.Start, r, TextPatternRangeEndpoint.End);
                else r.MoveEndpointByRange(TextPatternRangeEndpoint.End, r, TextPatternRangeEndpoint.Start);
                if (r.Move(TextUnit.Line, step) != step) continue;
                r.ExpandToEnclosingUnit(TextUnit.Line);
                foreach (var x in r.GetBoundingRectangles())
                    if (x.Height > 0 && (step > 0 ? x.Top >= top.Bottom - 1 : x.Bottom <= top.Top + 1)) return x.Height;
            }
            catch (Exception) { }
        }
        return Math.Round(em * 1.33);
    }

    /// The selection's font size in device pixels where it is, or zero when the app doesn't say.
    static double Em(TextPatternRange selection, Rect at)
    {
        try
        {
            if (selection.GetAttributeValue(TextPattern.FontSizeAttribute) is not double points || points <= 0) return 0;
            var p = new InputWatch.POINT { X = (int)at.Left, Y = (int)at.Top };
            return points / 72 * 96 * Chip.ScaleAt(p);
        }
        catch (Exception) { return 0; }
    }

    /// True when the selected part has a Chinese character (CJK ideographs, extensions included).
    public static bool HasChinese(Selected s)
    {
        var text = s.Passage.Substring(s.Start, s.End - s.Start);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c is >= '\u3400' and <= '\u9FFF' or >= '\uF900' and <= '\uFAFF') return true;
            if (i + 1 < text.Length && char.IsSurrogatePair(c, text[i + 1]) && char.ConvertToUtf32(c, text[i + 1]) is >= 0x20000 and <= 0x3134F) return true;
        }
        return false;
    }

    /// The selected part's length without the white space around it, in characters.
    public static int Length(Selected s) => s.Passage.Substring(s.Start, s.End - s.Start).Trim().Length;

    /// Copies the selection and reads it from the clipboard, then puts back what was there.
    public static async Task<Selected?> ReadByCopying()
    {
        // The shortcut's own keys must be up first, or Ctrl+C arrives as Ctrl+Alt+C.
        for (var i = 0; i < 40 && (Down(VK_MENU) || Down(VK_SHIFT) || Down(VK_LWIN) || Down(VK_RWIN)); i++) await Task.Delay(25);
        IDataObject? saved = null;
        try { saved = Clipboard.GetDataObject(); } catch { }
        var marker = "longyan-" + Guid.NewGuid();
        try { Clipboard.SetDataObject(Private(marker), false); } catch { return null; }
        SendCopy();
        string? text = null;
        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(25);
            try { text = Clipboard.ContainsText() ? Clipboard.GetText() : null; } catch { }
            if (text != null && text != marker) break;
        }
        try { if (saved != null) Clipboard.SetDataObject(Private(saved), true); else Clipboard.Clear(); } catch { }
        if (string.IsNullOrWhiteSpace(text) || text == marker) return null;
        return new Selected(text, 0, text.Length, null);
    }

    /// Clipboard contents marked to stay out of Win+V history and cloud clipboard sync, so the
    /// marker and the put-back don't show up there. (The app's own copy of the selection can't
    /// be marked: that one is the copied app's.)
    static DataObject Private(object content)
    {
        var data = new DataObject();
        if (content is string text) data.SetText(text);
        else if (content is IDataObject saved)
        {
            foreach (var format in saved.GetFormats(false))
            {
                try { if (saved.GetData(format, false) is object value) data.SetData(format, value, false); } catch { }
            }
        }
        var no = new System.IO.MemoryStream(BitConverter.GetBytes(0));
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new System.IO.MemoryStream(new byte[] { 0 }), false);
        data.SetData("CanIncludeInClipboardHistory", no, false);
        data.SetData("CanUploadToCloudClipboard", new System.IO.MemoryStream(BitConverter.GetBytes(0)), false);
        return data;
    }

    static bool Down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    static void SendCopy()
    {
        var inputs = new[]
        {
            Key(VK_CONTROL, false), Key(VK_C, false), Key(VK_C, true), Key(VK_CONTROL, true),
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    static INPUT Key(int vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        u = new InputUnion { ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } },
    };

    const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_C = 0x43, VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 2;

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
}
