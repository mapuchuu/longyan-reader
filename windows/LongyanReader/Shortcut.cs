using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Longyan;

/// A key with modifiers, as RegisterHotKey takes them.
readonly record struct Combo(uint Modifiers, uint Key)
{
    public const uint Alt = 1, Ctrl = 2, Shift = 4, Win = 8;

    public bool Has(uint modifier) => (Modifiers & modifier) != 0;

    /// "Ctrl+Alt+L", "Win+Ctrl+Y": Windows' own order.
    public string Name => Prefix(Modifiers) + KeyName(Key);

    /// "Ctrl+Alt+": the modifiers alone, as the picker shows them while they're held.
    public static string Prefix(uint modifiers)
    {
        var s = new StringBuilder();
        if ((modifiers & Win) != 0) s.Append("Win+");
        if ((modifiers & Ctrl) != 0) s.Append("Ctrl+");
        if ((modifiers & Alt) != 0) s.Append("Alt+");
        if ((modifiers & Shift) != 0) s.Append("Shift+");
        return s.ToString();
    }

    public static string KeyName(uint vk)
    {
        if (vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A) return ((char)vk).ToString();
        if (vk is >= 0x70 and <= 0x87) return "F" + (vk - 0x6F);
        if (vk is >= 0x60 and <= 0x69) return "Num " + (vk - 0x60);
        switch (vk)
        {
            case 0x08: return "Backspace";
            case 0x09: return "Tab";
            case 0x0D: return "Enter";
            case 0x13: return "Pause";
            case 0x1B: return "Esc";
            case 0x20: return "Space";
            case 0x21: return "Page Up";
            case 0x22: return "Page Down";
            case 0x23: return "End";
            case 0x24: return "Home";
            case 0x25: return "Left";
            case 0x26: return "Up";
            case 0x27: return "Right";
            case 0x28: return "Down";
            case 0x2C: return "Print Screen";
            case 0x2D: return "Insert";
            case 0x2E: return "Delete";
            case 0x6A: return "Num *";
            case 0x6B: return "Num +";
            case 0x6D: return "Num -";
            case 0x6E: return "Num .";
            case 0x6F: return "Num /";
        }
        // Punctuation keys: what the key types on the current layout, as Windows names them.
        var c = MapVirtualKey(vk, 2 /* MAPVK_VK_TO_CHAR */) & 0x7FFF;
        if (c > 0x20) return char.ToUpperInvariant((char)c).ToString();
        return $"Key {vk}";
    }

    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
}

/// The look-up shortcut, anywhere in Windows (RegisterHotKey on a hidden window). The default
/// is Ctrl+Alt+L, unless that types a character on one of the keyboard layouts installed: on
/// Polish, Czech, Hungarian and other AltGr layouts Ctrl+Alt is AltGr, and AltGr+L is ł, which
/// a hot key would stop anyone typing. Then the default is Win+Ctrl+Y. A shortcut the reader
/// picked is kept as it is, whatever the layouts.
static class Shortcut
{
    /// The first of these that types nothing on any installed layout is the default.
    /// Win+Ctrl+Y: a Win combination never types a character on any layout, and Windows doesn't
    /// use Win+Ctrl+Y (its Win+Ctrl ones are C, D, F, N, O, Q, S, V, Enter, Space, arrows and
    /// F4). Not L with Win: Win+L locks the computer below the level hot keys see. Not
    /// Ctrl+Alt+Shift, which is AltGr+Shift (Ł on Polish), nor Ctrl+Shift+letter, which apps
    /// use (Ctrl+Shift+L is filters in Excel, select all matches in VS Code).
    static readonly Combo[] defaults =
    {
        new(Combo.Ctrl | Combo.Alt, 0x4C),
        new(Combo.Win | Combo.Ctrl, 0x59),
    };

    public static readonly Combo Usual = defaults[0];

    /// Called on the shortcut, and with a sentence for the reader when something needs them
    /// (the shortcut is taken, or the one they picked now types a character), and whether to
    /// open the picker for it.
    static Action? pressed;
    static Action<string, bool>? notice;
    static HwndSource? source;
    static IntPtr[] layouts = Array.Empty<IntPtr>();
    static bool paused;
    static Combo applied;   // the one last registered (or tried)

    /// Raised when the shortcut in use, or whether it works, changes.
    public static event Action? Changed;

    /// The shortcut picked in the window, or null for the default.
    public static Combo? Chosen => Settings.ChosenShortcut is (uint m, uint k) ? new Combo(m, k) : null;

    /// The default on the layouts installed now.
    public static Combo Default => DefaultFor(Layouts());

    /// The shortcut in use (or meant to be, when it's taken).
    public static Combo Current => Chosen ?? Default;

    public static string Name => Current.Name;

    /// Whether the shortcut is registered, so pressing it works.
    public static bool Registered { get; private set; }

    public static void Start(Action onPress, Action<string, bool> onNotice)
    {
        pressed = onPress;
        notice = onNotice;
        source = new HwndSource(new HwndSourceParameters("LongyanReaderHotKey") { Width = 0, Height = 0, WindowStyle = 0 });
        source.AddHook(Hook);
        layouts = Layouts();
        Apply();
        if (!Registered) notice?.Invoke(TakenText, true);
        // Layouts added or removed in Settings send no message to a window without the focus,
        // so look every few seconds (the list is a cheap call).
        var timer = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, (_, _) => LayoutsMaybeChanged(), Dispatcher.CurrentDispatcher);
        timer.Start();
    }

    static void LayoutsMaybeChanged()
    {
        var now = Layouts();
        if (now.SequenceEqual(layouts)) return;
        var before = applied;
        var added = now.Except(layouts).ToList();
        layouts = now;
        if (Chosen is Combo chosen)
        {
            // The reader's own pick stays; say if it now types a character.
            foreach (var hkl in added)
                if (Types(chosen, hkl) is string c) { notice?.Invoke($"{chosen.Name} types {c} on the {LayoutName(hkl)} keyboard, so you can't type {c} while Longyan Reader runs. Choose another shortcut.", true); break; }
            return;
        }
        if (Current == before) return;
        Apply();
        var typing = added.FirstOrDefault(h => Types(before, h) != null);
        if (!Registered) notice?.Invoke(TakenText, true);
        else if (typing != IntPtr.Zero) notice?.Invoke($"The shortcut is now {Name}, since {before.Name} types {Types(before, typing)} on the {LayoutName(typing)} keyboard.", false);
        else notice?.Invoke($"The shortcut is {Name} again.", false);
    }

    static string TakenText => $"{Name} is used by another app. Choose another shortcut for Longyan Reader.";

    /// Registers the shortcut in use, in place of the one before.
    static void Apply()
    {
        if (source == null) return;
        UnregisterHotKey(source.Handle, 1);
        // While paused it stays off, and Registered says how it was; Resume puts it back.
        applied = Current;
        if (!paused) Registered = RegisterHotKey(source.Handle, 1, applied.Modifiers | MOD_NOREPEAT, applied.Key);
        Changed?.Invoke();
    }

    /// Lets the shortcut's keys through while the picker records keys, so pressing the one in
    /// use shows in the field instead of looking up.
    public static void Pause()
    {
        if (source == null || paused) return;
        paused = true;
        UnregisterHotKey(source.Handle, 1);
    }

    public static void Resume()
    {
        if (source == null || !paused) return;
        paused = false;
        Apply();
    }

    /// What's wrong with a shortcut for the picker, or null when it can be used. Tries it with
    /// RegisterHotKey, so call it while paused.
    public static string? Problem(Combo c)
    {
        if (!c.Has(Combo.Ctrl) && !c.Has(Combo.Alt) && !c.Has(Combo.Win)) return "Include Ctrl, Alt or Win";
        if (c.Has(Combo.Win) && c.Key == 0x4C) return "Win+L locks the computer";
        foreach (var hkl in Layouts())
            if (Types(c, hkl) is string ch) return $"{c.Name} types {ch} on the {LayoutName(hkl)} keyboard";
        if (source != null)
        {
            if (!RegisterHotKey(source.Handle, 2, c.Modifiers | MOD_NOREPEAT, c.Key)) return "Another app is using this shortcut";
            UnregisterHotKey(source.Handle, 2);
        }
        return null;
    }

    /// Saves a pick (null for the default) and registers it. False when it can't be registered.
    public static bool Use(Combo? pick)
    {
        var old = Settings.ChosenShortcut;
        Settings.ChosenShortcut = pick is Combo p ? (p.Modifiers, p.Key) : null;
        paused = false;
        Apply();
        if (Registered || pick == null) return true;
        Settings.ChosenShortcut = old;
        Apply();
        return false;
    }

    static Combo DefaultFor(IntPtr[] hkls) =>
        defaults.FirstOrDefault(d => hkls.All(h => Types(d, h) == null), defaults[^1]);

    /// The character a shortcut types on a layout, or null. Win combinations never type; nor
    /// does Alt without Ctrl (that's the menu keys). Ctrl+Alt is AltGr on layouts that have it.
    public static string? Types(Combo c, IntPtr hkl)
    {
        if (c.Has(Combo.Win) || !c.Has(Combo.Ctrl)) return null;
        var state = new byte[256];
        if (c.Has(Combo.Ctrl)) state[VK_CONTROL] = state[VK_LCONTROL] = 0x80;
        if (c.Has(Combo.Alt)) state[VK_MENU] = state[VK_LMENU] = 0x80;
        if (c.Has(Combo.Shift)) state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
        var scan = MapVirtualKeyEx(c.Key, 0 /* MAPVK_VK_TO_VSC */, hkl);
        var buffer = new StringBuilder(8);
        // Flag 4: leave the keyboard's state (dead keys) as it was.
        var n = ToUnicodeEx(c.Key, scan, state, buffer, buffer.Capacity, 4, hkl);
        if (n < 0) return buffer.Length > 0 && buffer[0] > 0x20 ? buffer[0].ToString() : "an accent";
        var typed = buffer.ToString(0, Math.Min(Math.Max(n, 0), buffer.Length));
        return typed.Any(ch => ch >= 0x20 && ch != 0x7F) ? typed : null;
    }

    public static IntPtr[] Layouts()
    {
        var n = GetKeyboardLayoutList(0, null);
        var list = new IntPtr[Math.Max(n, 0)];
        if (n > 0) n = GetKeyboardLayoutList(n, list);
        return list.Take(Math.Max(n, 0)).ToArray();
    }

    /// "Polish (Poland)": the layout's language, in English as the app is.
    public static string LayoutName(IntPtr hkl)
    {
        try { return CultureInfo.GetCultureInfo((int)((long)hkl & 0xFFFF)).EnglishName; }
        catch { return $"{(long)hkl & 0xFFFFFFFF:X8}"; }
    }

    /// --check-shortcut: for each installed layout, whether Ctrl+Alt+L types a character there,
    /// and the default these layouts get (windows/UiCheck reads it).
    public static int Check()
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var hkls = Layouts();
        foreach (var hkl in hkls)
        {
            var typed = Types(Usual, hkl);
            Console.WriteLine($"layout {(long)hkl & 0xFFFFFFFF:X8} {LayoutName(hkl)}: {Usual.Name} {(typed == null ? "types nothing" : $"types {typed} (U+{(int)typed[0]:X4})")}");
        }
        Console.WriteLine($"default {DefaultFor(hkls).Name}");
        return 0;
    }

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && (int)wParam == 1) { handled = true; pressed?.Invoke(); }
        return IntPtr.Zero;
    }

    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;
    const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LSHIFT = 0xA0, VK_LCONTROL = 0xA2, VK_LMENU = 0xA4;
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int n, IntPtr[]? list);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyEx(uint code, uint type, IntPtr hkl);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buffer, int size, uint flags, IntPtr hkl);
}
