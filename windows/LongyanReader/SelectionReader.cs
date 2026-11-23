using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Longyan;

/// What the reader selected, with the text around it so the core can read the sentence.
record Selected(string Passage, int Start, int End, Rect? Bounds);

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
            return new Probed(Found.Selection, new Selected(passage, start, start + selected.Length, Bounds(selection)), role, area);
        }
        catch (Exception)
        {
            return new Probed(Found.Unreadable, null);   // the app went away or doesn't answer
        }
    }

    /// Where the selection is on screen: its lines' rectangles together, as the Mac's
    /// AXBoundsForRange gives. Notepad on Windows 11 counts the page's top margin (16 at 100%)
    /// as part of the first line, which put the eye that much above the text: a top line taller
    /// than the next line by a quarter, or than its font allows, is cut to a normal line's
    /// height from the bottom, where its text is.
    /// White space at the selection's end is left out: a double-click in Chromium on Windows
    /// takes the space after the word, and a line's selection its line break, which the Mac's
    /// double-click doesn't, and the eye would sit that much further right.
    static Rect? Bounds(TextPatternRange selection)
    {
        selection = WithoutTrailingSpace(selection);
        var rects = selection.GetBoundingRectangles();
        if (rects.Length == 0) return null;
        var top = rects.OrderBy(x => x.Top).First();
        var line = LineHeight(selection, rects, top);
        if (line > 0 && top.Height > line * 1.25)
        {
            var cut = top.Bottom - line;
            for (var i = 0; i < rects.Length; i++)
                if (rects[i].Top < cut && rects[i].Bottom > cut) rects[i] = new Rect(rects[i].X, cut, rects[i].Width, rects[i].Bottom - cut);
        }
        var r = rects[0];
        foreach (var x in rects.Skip(1)) r.Union(x);
        return r;
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
        var em = Em(selection, top);
        if (em > 0 && top.Height <= em * 1.6) return 0;
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
        return em > 0 ? Math.Round(em * 1.33) : 0;
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
