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

    public static Selected? ReadAutomation()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return null;
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var p) || p is not TextPattern text) return null;
            var selection = text.GetSelection().FirstOrDefault();
            if (selection == null) return null;
            var selected = selection.GetText(-1);
            if (string.IsNullOrEmpty(selected)) return null;

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
            Rect? bounds = null;
            var rects = selection.GetBoundingRectangles();
            if (rects.Length > 0)
            {
                var r = rects[0];
                foreach (var x in rects.Skip(1)) r.Union(x);
                bounds = r;
            }
            return new Selected(passage, start, start + selected.Length, bounds);
        }
        catch (Exception)
        {
            return null;   // the app went away or doesn't answer
        }
    }

    /// Copies the selection and reads it from the clipboard, then puts back what was there.
    public static async Task<Selected?> ReadByCopying()
    {
        // The shortcut's own keys must be up first, or Ctrl+C arrives as Ctrl+Alt+C.
        for (var i = 0; i < 40 && (Down(VK_MENU) || Down(VK_SHIFT) || Down(VK_LWIN) || Down(VK_RWIN)); i++) await Task.Delay(25);
        IDataObject? saved = null;
        try { saved = Clipboard.GetDataObject(); } catch { }
        var marker = "longyan-" + Guid.NewGuid();
        try { Clipboard.SetText(marker); } catch { return null; }
        SendCopy();
        string? text = null;
        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(25);
            try { text = Clipboard.ContainsText() ? Clipboard.GetText() : null; } catch { }
            if (text != null && text != marker) break;
        }
        try { if (saved != null) Clipboard.SetDataObject(saved, true); else Clipboard.Clear(); } catch { }
        if (string.IsNullOrWhiteSpace(text) || text == marker) return null;
        return new Selected(text, 0, text.Length, null);
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
