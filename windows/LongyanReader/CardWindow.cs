using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace Longyan;

/// The card's window: a transparent frame 28 larger than the card on every side, to hold its
/// shadow, over the other app and never taking the focus from it (notes/card-spec.md, 1 and 6).
sealed class CardWindow : Window, ICardActions
{
    static CardWindow? current;
    static bool pinned;
    static Point? pinnedTopLeft;   // device pixels
    static double zoom = 1;
    /// True while a press has become a move, so the control under it doesn't count a click.
    public static bool WasDrag;

    const double Frame = 28, Gap = 8, Inset = 8;

    long cardID;
    readonly CardView view;
    readonly Grid frame = new();             // the window's content: the card in its shadow margin
    readonly Grid card = new();              // shadow layers and the card, moved on reveal
    readonly Border surface;
    readonly ScrollViewer scroller;
    readonly ScaleTransform revealScale = new(1, 1);
    readonly TranslateTransform revealShift = new();
    readonly ScaleTransform zoomScale = new(1, 1);
    readonly bool offscreen;

    // Placement, in device pixels: the selection, and whether the card hangs below it.
    Rect anchor;
    bool below = true, placed, moved, revealed, closing, isHint;
    double scale = 1;
    double shownHeight;                       // the card's target height, DIPs
    double cardLeft, edge;                    // device pixels: the card's left, and its top (below) or bottom (above)
    DispatcherTimer? shrink, hold;
    JsonObject? last;

    public bool Pinned => pinned;
    public bool CanListen => offscreen || Speech.Available;

    // MARK: Opening

    public static void Present(Selected selected)
    {
        var old = current;
        current = new CardWindow(selected.Bounds, false);
        if (pinned && old != null && !old.isHint) current.HangFrom(old.CardTopLeft(), old.scale);
        current.Open(selected);
        old?.Dismiss();
    }

    public static void Hint(string message)
    {
        if (pinned && current != null && !current.isHint)
        {
            // A hint beside a pinned card opens in a window of its own by the pointer.
            new CardWindow(null, false).ShowHint(message);
            return;
        }
        current?.Dismiss();
        current = new CardWindow(null, false);
        current.ShowHint(message);
    }

    /// Draws `card` as the card would show it, at twice the size (as a Retina screenshot of the
    /// Mac card is), on the Mac renders' grey backdrop with 12 around it and no shadow.
    public static void RenderToFile(JsonObject json, string path)
    {
        var w = new CardWindow(null, true);
        w.view.Show(json, animate: false);
        w.Content = null;
        w.card.Children.RemoveRange(0, 2);
        w.card.Margin = new Thickness(0);
        w.card.Width = w.view.Width;
        w.scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        var backdrop = new Border { Background = Theme.Backdrop, Padding = new Thickness(12), Child = w.frame };
        TextOptions.SetTextFormattingMode(backdrop, TextFormattingMode.Ideal);
        backdrop.Measure(new Size(w.view.Width + 24, double.PositiveInfinity));
        backdrop.Arrange(new Rect(backdrop.DesiredSize));
        backdrop.UpdateLayout();
        var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(backdrop.ActualWidth * 2), (int)Math.Ceiling(backdrop.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32);
        bmp.Render(backdrop);
        var png = new System.Windows.Media.Imaging.PngBitmapEncoder();
        png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
        using var f = System.IO.File.Create(path);
        png.Save(f);
    }

    CardWindow(Rect? selection, bool offscreen)
    {
        this.offscreen = offscreen;
        view = new CardView(this);
        GetCursorPos(out var p);
        anchor = selection ?? new Rect(p.X - 20, p.Y - 10, 40, 20);

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Opacity = 0;
        Cursor = Cursors.Arrow;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);

        // The shadow: two layers cast by copies of the card's outline behind it.
        card.Margin = new Thickness(Frame);
        card.VerticalAlignment = VerticalAlignment.Top;
        card.HorizontalAlignment = HorizontalAlignment.Left;
        card.Children.Add(Shadow(32, 8, 0.16));
        card.Children.Add(Shadow(3, 0.5, 0.08));
        scroller = new ScrollViewer
        {
            Content = view.Root, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false,
            VerticalAlignment = VerticalAlignment.Top,
        };
        view.Root.LayoutTransform = zoomScale;
        surface = new Border
        {
            Background = Theme.Surface, BorderBrush = Theme.Hairline, BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(16), Child = scroller, VerticalAlignment = VerticalAlignment.Top,
        };
        surface.SizeChanged += (_, _) => scroller.Clip = new RectangleGeometry(new Rect(new Size(Math.Max(0, surface.ActualWidth - 1), Math.Max(0, surface.ActualHeight - 1))), 15.5, 15.5);
        card.Children.Add(surface);
        var group = new TransformGroup();
        group.Children.Add(revealScale);
        group.Children.Add(revealShift);
        card.RenderTransform = group;
        card.RenderTransformOrigin = new Point(0.5, 0);
        frame.Children.Add(card);
        Content = frame;
        if (offscreen) return;

        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };
        Closed += (_, _) =>
        {
            Hooks.Remove(this);
            if (cardID != 0) Core.Shared.Close(cardID);
            if (current == this) current = null;
        };
        PreviewMouseLeftButtonDown += PressStart;
        PreviewMouseMove += PressMove;
        PreviewMouseLeftButtonUp += PressEnd;
        PreviewMouseWheel += Wheel;
        zoomScale.ScaleX = zoomScale.ScaleY = zoom;
    }

    static Border Shadow(double blur, double y, double alpha) => new()
    {
        CornerRadius = new CornerRadius(16), Background = Theme.Surface, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Top,
        Effect = new DropShadowEffect { BlurRadius = blur, ShadowDepth = y, Direction = 270, Opacity = alpha, Color = Colors.Black, RenderingBias = RenderingBias.Quality },
    };

    /// Opens at a fixed top-left corner (a pinned card, or one opened from inside another).
    void HangFrom(Point topLeft, double scale)
    {
        placed = true;
        below = true;
        moved = true;
        cardLeft = topLeft.X;
        edge = topLeft.Y;
        this.scale = scale;
    }

    void Open(Selected s)
    {
        cardID = Core.Shared.Lookup(s.Passage, s.Start, s.End, Update, ShowHint);
    }

    void ShowHint(string message)
    {
        if (cardID != 0) { Core.Shared.Close(cardID); cardID = 0; }
        isHint = true;
        view.Hint(message);
        Arrive();
        // A hint goes by itself.
        After(1.8, Dismiss);
    }

    // MARK: Updates

    void Update(JsonObject json)
    {
        if (closing) return;
        last = json;
        if (!revealed)
        {
            // Hold a word card up to 0.4 s for the model's pick, so it opens complete.
            var reading = (string?)json["kind"] != "phrase" && (string?)json["status"] == "Reading the sentence…";
            view.Show(json, animate: false);
            if (reading) { hold ??= After(0.4, Arrive); return; }
            Arrive();
            return;
        }
        view.Show(json, animate: true);
        Resize(animated: true);
    }

    /// First content: measure, place, then reveal.
    void Arrive()
    {
        if (revealed || closing) return;
        revealed = true;
        hold?.Stop();
        Width = view.Width * zoom + 2 * Frame;
        Height = 200;
        if (!IsVisible) { Show(); Hooks.Add(this); }
        scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        Resize(animated: false);
        Reveal();
    }

    double Measure()
    {
        view.Root.Measure(new Size(view.Width, double.PositiveInfinity));
        var content = view.Root.DesiredSize.Height * zoom;
        return Math.Ceiling(Math.Min(content, MaxHeight()));
    }

    void Reveal()
    {
        card.RenderTransformOrigin = new Point(0.5, below ? 0 : 1);
        if (Motion.Reduced || moved || pinned)
        {
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, new Duration(TimeSpan.FromSeconds(moved || pinned ? 0.12 : 0.14))));
            return;
        }
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, new Duration(TimeSpan.FromSeconds(0.14))));
        Motion.Animate(revealScale, ScaleTransform.ScaleXProperty, 0.96, 1, Motion.RevealDuration, Motion.Reveal);
        Motion.Animate(revealScale, ScaleTransform.ScaleYProperty, 0.96, 1, Motion.RevealDuration, Motion.Reveal);
        Motion.Animate(revealShift, TranslateTransform.YProperty, below ? -4 : 4, 0, Motion.RevealDuration, Motion.Reveal);
    }

    /// Sets the card's height for its content: the window grows at once and the card animates
    /// inside it; when it shrinks, the window follows 0.32 s later.
    void Resize(bool animated)
    {
        var width = view.Width * zoom;
        card.Width = width;
        var target = Measure();
        foreach (FrameworkElement layer in card.Children) layer.Width = width;
        shrink?.Stop();
        if (!animated)
        {
            foreach (FrameworkElement layer in card.Children) { layer.BeginAnimation(HeightProperty, null); layer.Height = target; }
            shownHeight = target;
            SetFrame(target);
            return;
        }
        var from = surface.ActualHeight > 0 ? surface.ActualHeight : shownHeight;
        if (Math.Abs(target - from) < 0.5) return;
        if (target > from) SetFrame(target);
        foreach (FrameworkElement layer in card.Children)
        {
            var a = new DoubleAnimation(from, target, Motion.Reduced ? new Duration(TimeSpan.FromSeconds(0.15)) : Motion.CardDuration)
            {
                EasingFunction = Motion.Reduced ? new QuadraticEase { EasingMode = EasingMode.EaseInOut } : Motion.Card,
            };
            layer.BeginAnimation(HeightProperty, a);
        }
        shownHeight = target;
        if (target < from) shrink = After(0.32, () => SetFrame(target));
    }

    /// Sizes the window for a card `height` tall and places it by the selection.
    void SetFrame(double height)
    {
        Width = view.Width * zoom + 2 * Frame;
        Height = height + 2 * Frame;
        Place(height);
        card.VerticalAlignment = below ? VerticalAlignment.Top : VerticalAlignment.Bottom;
        foreach (FrameworkElement layer in card.Children) layer.VerticalAlignment = card.VerticalAlignment;
    }

    // MARK: Placement

    System.Windows.Forms.Screen Screen()
    {
        var r = new System.Drawing.Rectangle((int)anchor.X, (int)anchor.Y, Math.Max(1, (int)anchor.Width), Math.Max(1, (int)anchor.Height));
        return System.Windows.Forms.Screen.FromRectangle(r);
    }

    /// The tallest the card may be: the room on its side of the selection, at most 0.8 of the
    /// screen, at least 120.
    double MaxHeight()
    {
        var area = Screen().WorkingArea;
        var s = scale <= 0 ? 1 : scale;
        double room;
        if (placed && below && moved) room = (area.Bottom - edge) / s - Inset;
        else room = below ? (area.Bottom - anchor.Bottom) / s - Gap - Inset : (anchor.Top - area.Top) / s - Gap - Inset;
        return Math.Max(120, Math.Min(room, area.Height / s * 0.8));
    }

    void Place(double height)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var area = Screen().WorkingArea;
        var s = scale;
        if (!placed)
        {
            placed = true;
            view.Root.Measure(new Size(view.Width, double.PositiveInfinity));
            var content = view.Root.DesiredSize.Height * zoom;
            var roomBelow = (area.Bottom - anchor.Bottom) / s - 16;
            var roomAbove = (anchor.Top - area.Top) / s - 16;
            below = roomBelow >= Math.Max(content, 320) || roomBelow >= roomAbove;
            cardLeft = anchor.Left;
            edge = below ? anchor.Bottom + Gap * s : anchor.Top - Gap * s;
        }
        var w = view.Width * zoom * s;
        var h = height * s;
        var left = Math.Max(area.Left + Inset * s, Math.Min(cardLeft, area.Right - Inset * s - w));
        var top = below ? edge : edge - h;
        top = Math.Max(area.Top + Inset * s, Math.Min(top, area.Bottom - Inset * s - h));
        var m = Frame * s;
        SetWindowPos(hwnd, IntPtr.Zero, (int)Math.Round(left - m), (int)Math.Round(top - m),
            (int)Math.Round(w + 2 * m), (int)Math.Round(h + 2 * m), SWP_NOACTIVATE | SWP_NOZORDER);
    }

    /// The card's top-left corner on screen, in device pixels.
    Point CardTopLeft()
    {
        GetWindowRect(new WindowInteropHelper(this).Handle, out var r);
        var m = Frame * scale;
        var top = below ? r.Top + m : r.Bottom - m - surface.ActualHeight * scale;
        return new Point(r.Left + m, top);
    }

    // MARK: Moving

    bool pressing;
    POINT pressScreen;
    RECT pressWindow;

    void PressStart(object sender, MouseButtonEventArgs e)
    {
        WasDrag = false;
        pressing = true;
        GetCursorPos(out pressScreen);
        GetWindowRect(new WindowInteropHelper(this).Handle, out pressWindow);
        // A card placed above hangs from its top edge from the first click on.
        if (!below && !isHint)
        {
            var tl = CardTopLeft();
            below = true;
            edge = tl.Y;
            SetFrame(shownHeight);
            GetWindowRect(new WindowInteropHelper(this).Handle, out pressWindow);
        }
    }

    void PressMove(object sender, MouseEventArgs e)
    {
        if (!pressing || e.LeftButton != MouseButtonState.Pressed) return;
        GetCursorPos(out var now);
        double dx = now.X - pressScreen.X, dy = now.Y - pressScreen.Y;
        if (!WasDrag && Math.Sqrt(dx * dx + dy * dy) < 4 * scale) return;
        if (!WasDrag) { WasDrag = true; CaptureMouse(); }
        SetWindowPos(new WindowInteropHelper(this).Handle, IntPtr.Zero, pressWindow.Left + (int)dx, pressWindow.Top + (int)dy, 0, 0, SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE);
        e.Handled = true;
    }

    void PressEnd(object sender, MouseButtonEventArgs e)
    {
        pressing = false;
        if (!WasDrag) return;
        ReleaseMouseCapture();
        moved = true;
        var tl = CardTopLeft();
        cardLeft = tl.X;
        edge = tl.Y;
        if (pinned) pinnedTopLeft = tl;
        e.Handled = true;
        Dispatcher.BeginInvoke(() => WasDrag = false, DispatcherPriority.Input);
    }

    /// Ctrl and the wheel change the text size, as a pinch does on the Mac.
    void Wheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0 || isHint) return;
        zoom = Math.Clamp(zoom * (e.Delta > 0 ? 1.1 : 1 / 1.1), 0.8, 2.2);
        zoomScale.ScaleX = zoomScale.ScaleY = zoom;
        Resize(animated: false);
        e.Handled = true;
    }

    // MARK: Closing

    public void Dismiss()
    {
        if (closing) return;
        closing = true;
        hold?.Stop();
        Hooks.Remove(this);
        Speech.Stop();
        if (!IsVisible) { Close(); return; }
        var a = new DoubleAnimation(Opacity, 0, new Duration(TimeSpan.FromSeconds(0.12)));
        a.Completed += (_, _) => Close();
        BeginAnimation(OpacityProperty, a);
    }

    /// From the hooks: a click or scroll somewhere else, or Esc.
    public void Outside(Hooks.Kind kind, POINT at)
    {
        if (closing || pinned && !isHint) return;
        if (kind == Hooks.Kind.Escape) { Dismiss(); return; }
        if (Contains(at)) return;
        if (kind == Hooks.Kind.Scroll && moved) return;
        Dismiss();
    }

    bool Contains(POINT p)
    {
        GetWindowRect(new WindowInteropHelper(this).Handle, out var r);
        var m = Frame * scale;
        return p.X >= r.Left + m && p.X <= r.Right - m && p.Y >= r.Top + m && p.Y <= r.Bottom - m;
    }

    DispatcherTimer After(double seconds, Action act)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); act(); };
        t.Start();
        return t;
    }

    // MARK: ICardActions

    public void Pick(int token, int sense) => Bridge.ly_pick(cardID, token, sense);
    public void UseSuggested(int token) => Bridge.ly_use_suggested(cardID, token);
    public void ToggleAll(int token) => Bridge.ly_toggle_all(cardID, token);
    public void ToggleRow(int token) => Bridge.ly_toggle_row(cardID, token);

    /// Part of: a new card replaces this one, hanging from the same corner.
    public void OpenPartOf()
    {
        var next = new CardWindow(null, false);
        next.HangFrom(CardTopLeft(), scale);
        next.cardID = Core.Shared.OpenPartOf(cardID, next.Update, next.ShowHint);
        current = next;
        Dismiss();
    }

    public void Copy(string text) { try { Clipboard.SetText(text); } catch { } }
    public void Listen(string text) => Speech.Say(text);

    public void TogglePin()
    {
        pinned = !pinned;
        pinnedTopLeft = pinned ? CardTopLeft() : null;
        if (pinned) { below = true; moved = true; edge = pinnedTopLeft!.Value.Y; cardLeft = pinnedTopLeft.Value.X; SetFrame(shownHeight); }
        if (last != null) view.Show(last, animate: true);
    }

    // MARK: Win32

    const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
    const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}

/// Low-level mouse and keyboard hooks, so clicks, scrolls and Esc in other apps reach the
/// card, which never has the focus.
static class Hooks
{
    public enum Kind { Click, Scroll, Escape }
    static readonly System.Collections.Generic.List<CardWindow> cards = new();
    static IntPtr mouse, keyboard;
    static readonly HookProc mouseProc = MouseHook, keyProc = KeyHook;

    public static void Add(CardWindow w)
    {
        if (!cards.Contains(w)) cards.Add(w);
        if (mouse != IntPtr.Zero) return;
        var module = GetModuleHandle(null);
        mouse = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, module, 0);
        keyboard = SetWindowsHookEx(WH_KEYBOARD_LL, keyProc, module, 0);
    }

    public static void Remove(CardWindow w)
    {
        cards.Remove(w);
        if (cards.Count > 0 || mouse == IntPtr.Zero) return;
        UnhookWindowsHookEx(mouse);
        UnhookWindowsHookEx(keyboard);
        mouse = keyboard = IntPtr.Zero;
    }

    static void Tell(Kind kind, CardWindow.POINT at)
    {
        // Later, on the app's thread: a hook must return quickly.
        Application.Current?.Dispatcher.BeginInvoke(() => { foreach (var c in cards.ToArray()) c.Outside(kind, at); });
    }

    static IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var m = (int)wParam;
            if (m is WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_MOUSEWHEEL)
                Tell(m == WM_MOUSEWHEEL ? Kind.Scroll : Kind.Click, Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam).pt);
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    static IntPtr KeyHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (int)wParam == WM_KEYDOWN && Marshal.ReadInt32(lParam) == 0x1B) Tell(Kind.Escape, default);
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14, WM_KEYDOWN = 0x100, WM_LBUTTONDOWN = 0x201, WM_RBUTTONDOWN = 0x204, WM_MOUSEWHEEL = 0x20A;
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public CardWindow.POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string? name);
}

/// Listen: Windows' own Chinese voice, when one is installed.
static class Speech
{
    static System.Speech.Synthesis.SpeechSynthesizer? synth;
    static bool looked, found;

    public static bool Available { get { Find(); return found; } }

    static void Find()
    {
        if (looked) return;
        looked = true;
        try
        {
            synth = new System.Speech.Synthesis.SpeechSynthesizer();
            foreach (var v in synth.GetInstalledVoices())
            {
                if (!v.Enabled || !v.VoiceInfo.Culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) continue;
                synth.SelectVoice(v.VoiceInfo.Name);
                synth.SetOutputToDefaultAudioDevice();
                found = true;
                break;
            }
        }
        catch { found = false; }
    }

    public static void Say(string text)
    {
        Find();
        if (!found || synth == null) return;
        synth.SpeakAsyncCancelAll();
        synth.SpeakAsync(text);
    }

    public static void Stop() { try { synth?.SpeakAsyncCancelAll(); } catch { } }
}
