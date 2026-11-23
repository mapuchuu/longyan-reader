using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Longyan;

/// The word under the pointer, for the shortcut with nothing selected, as the Mac's
/// TextCapture does with Accessibility: UI Automation's text pattern gives the character at
/// the point, and the text around it (400 each way) is the passage. The core then picks the
/// word that character is in. A spreadsheet cell with no text pattern gives its whole text.
/// Apps without a text pattern (only a LegacyIAccessible value, which has no character
/// bounds) can't be pointed at.
static class PointReader
{
    const int Around = 400;   // UTF-16 units each way, as the Mac

    /// Why the last read found nothing ("text" or "cell" when it found something), for the
    /// log. Never the text.
    public static string Found { get; private set; } = "";

    sealed record Read(Selected? Selection, string Found);

    static Task<Read>? pending;

    /// Reads at the pointer on a thread of its own, given up after `timeout`, as
    /// SelectionReader.ProbeAsync: an app that doesn't answer must not freeze ours.
    public static async Task<Selected?> ReadAsync(int timeout = 500)
    {
        if (!GetCursorPos(out var p)) { Found = "no pointer"; return null; }
        if (pending is { IsCompleted: false }) { Found = "busy"; return null; }
        var point = new Point(p.X, p.Y);
        var work = pending = Task.Run(() => At(point));
        if (await Task.WhenAny(work, Task.Delay(timeout)) != work) { Found = "no answer"; return null; }
        Found = work.Result.Found;
        return work.Result.Selection;
    }

    /// The point is in device pixels (the app is per-monitor DPI aware), as UI Automation wants.
    static Read At(Point point)
    {
        try
        {
            var element = AutomationElement.FromPoint(point);
            if (element == null) return new Read(null, "no element");
            if (element.Current.ProcessId == Environment.ProcessId) return new Read(null, "own window");
            // The element at the point is often a piece of a document (a run of text in a web
            // page): the text pattern is on it or on one of its parents.
            var walker = TreeWalker.RawViewWalker;
            var e = element;
            for (var depth = 0; e != null && depth < 12; depth++)
            {
                if (e.TryGetCurrentPattern(TextPattern.Pattern, out var p) && p is TextPattern text)
                    return e.Current.IsPassword ? new Read(null, "password") : InText(text, point);
                e = walker.GetParent(e);
            }
            return Cell(element);
        }
        catch (Exception)
        {
            return new Read(null, "failed");   // the app went away or doesn't answer
        }
    }

    static Read InText(TextPattern text, Point point)
    {
        // RangeFromPoint gives the nearest place between characters (Notepad's, the one after
        // the middle of a character), even past the end of a line or below the text: the
        // character after it, or the one before, must really be under the pointer.
        var near = text.RangeFromPoint(point);
        near.ExpandToEnclosingUnit(TextUnit.Character);
        TextPatternRange? at = null;
        string? ch = null, missed = null;
        foreach (var shift in new[] { 0, -1, 1 })
        {
            var r = near.Clone();
            if (shift != 0)
            {
                r.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, shift);
                r.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, shift);
            }
            var t = r.GetText(-1);
            if (string.IsNullOrEmpty(t)) continue;
            var rects = r.GetBoundingRectangles().Where(x => !x.IsEmpty && x.Width > 0).ToArray();
            if (rects.Length == 0) continue;
            if (rects.Any(x => { x.Inflate(3, 3); return x.Contains(point); })) { at = r; ch = t; break; }
            missed ??= FormattableString.Invariant($"not under the pointer: {point.X:0},{point.Y:0} and {rects[0].X:0},{rects[0].Y:0} {rects[0].Width:0}x{rects[0].Height:0}");
        }
        if (at == null || ch == null) return new Read(null, missed ?? "no character bounds");

        var wide = at.Clone();
        wide.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -Around);
        wide.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, Around);
        var before = wide.Clone();
        before.MoveEndpointByRange(TextPatternRangeEndpoint.End, at, TextPatternRangeEndpoint.Start);
        var passage = wide.GetText(-1);
        var index = before.GetText(-1).Length;
        // Some apps report ranges that don't line up: the character alone, then.
        if (index + ch.Length > passage.Length || passage.Substring(index, ch.Length) != ch) { passage = ch; index = 0; }
        if (!SelectionReader.HasChinese(new Selected(passage, index, index + ch.Length, null))) return new Read(null, "not Chinese");
        // Start == End: the core looks up the word at Start.
        return new Read(new Selected(passage, index, index, null), "text");
    }

    /// A spreadsheet cell gives its text but not where each character is: the whole cell is
    /// looked up instead of one word, as on the Mac.
    static Read Cell(AutomationElement element)
    {
        var info = element.Current;
        if (info.ControlType != ControlType.DataItem) return new Read(null, "no text pattern");
        var value = element.TryGetCurrentPattern(ValuePattern.Pattern, out var v) && v is ValuePattern vp ? vp.Current.Value : null;
        Rect? bounds = info.BoundingRectangle is { IsEmpty: false } r ? r : null;
        foreach (var t in new[] { value, info.Name })
        {
            if (string.IsNullOrEmpty(t)) continue;
            var s = new Selected(t, 0, t.Length, bounds);
            if (SelectionReader.HasChinese(s)) return new Read(s, "cell");
        }
        return new Read(null, "cell without Chinese");
    }

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
}
