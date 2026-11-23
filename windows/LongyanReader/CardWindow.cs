using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Longyan;

/// The card's window: a transparent frame 28 larger than the card on every side, to hold its
/// shadow, over the other app and never taking the focus from it (notes/card-spec.md, 1 and 6).
sealed partial class CardWindow : Window, ICardActions
{
    static CardWindow? current;
    // Kept in settings.json as the Mac keeps them in UserDefaults (card.zoom, card.width.word,
    // card.width.phrase, card.pinned, card.pinnedTopLeft), so a restart opens cards as they were left.
    static bool pinned = Settings.CardFlag("cardPinned");
    static double zoom = Math.Clamp(Settings.CardNumber("cardZoom") ?? 1, 0.8, 2.2);
    static double? wordWidth = Settings.CardNumber("cardWidthWord"), phraseWidth = Settings.CardNumber("cardWidthPhrase");   // set by dragging an edge, DIPs as drawn
    static Point? pinnedAt = OnAScreen(Settings.CardNumber("cardPinnedX"), Settings.CardNumber("cardPinnedY"));   // a pinned card's top-left corner, device pixels
    /// Every card window on screen, for re-theming them live.
    static readonly System.Collections.Generic.List<CardWindow> open = new();
    /// True while a press has become a move, so the control under it doesn't count a click.
    public static bool WasDrag;

    const double Frame = 28, Gap = 8, Inset = 8, Narrowest = 240, Widest = 1000;

    long cardID;
    readonly CardView view;
    readonly Grid frame = new();             // the window's content: the card in its shadow margin
    readonly Grid card = new();              // shadow layers, the card, its resize bands and badge
    readonly Border surface;
    readonly Grid overlay = new();           // inside the card: content, buttons, grips, hairline
    readonly ScrollViewer scroller;
    readonly FrameworkElement[] layers;      // what takes the card's height: shadows and surface
    readonly ScaleTransform revealScale = new(1, 1);
    readonly TranslateTransform revealShift = new();
    readonly ScaleTransform zoomScale = new(1, 1);
    readonly Canvas grip = new() { Width = 13, Height = 13, Opacity = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 3, 3) };
    readonly Border grabber = new() { Width = 3, CornerRadius = new CornerRadius(1.5), Opacity = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 3, 0) };
    readonly Grid badge = new() { Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(-7, -7, 0, 0), Opacity = 0, Visibility = Visibility.Collapsed, ToolTip = "Close" };
    readonly ScaleTransform badgeScale = new(0.7, 0.7);
    readonly System.Collections.Generic.List<FrameworkElement> bands = new();
    readonly bool offscreen;
    IntPtr Handle => new WindowInteropHelper(this).Handle;

    // Placement, in device pixels: the selection, and whether the card hangs below it.
    Rect anchor;
    bool below = true, placed, moved, revealed, closing, isHint, hovered, resizing;
    bool dragged;                             // moved by the user (a drag or a resize), not just hung
    bool gone;                                // the window has closed
    double scale = 1;
    CardWindow? swapping;                     // the card this one replaces, kept up until this one has faded in
    readonly LinearGradientBrush fadeMask = new() { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
    readonly GradientStop[] fadeStops = new GradientStop[5];
    bool fadeTop, fadeBottom;
    double shownHeight;                       // the card's target height, DIPs
    double cardLeft, edge;                    // device pixels: the card's left, and its top (below) or bottom (above)
    DispatcherTimer? shrink, hold;
    Stopwatch? firstContent;
    readonly Stopwatch opened = Stopwatch.StartNew();   // from the lookup, as the Mac's hold runs from show()
    JsonObject? last;
    bool ankiDecided;                         // whether the card has an Anki button is settled as it opens

    public bool Pinned => pinned;
    public bool CanListen => offscreen || Speech.Available;
    double Zoom => isHint ? 1 : zoom;
    double CardWidth => view.Width * Zoom;

    /// A saved corner, if it's still on a screen (a monitor may have gone since).
    static Point? OnAScreen(double? x, double? y)
    {
        if (x is not double px || y is not double py) return null;
        foreach (var s in System.Windows.Forms.Screen.AllScreens)
            if (s.WorkingArea.Contains((int)px, (int)py)) return new Point(px, py);
        return null;
    }

    /// Saves the text size, the widths and the pin, as the Mac saves them after every change.
    static void SaveCard()
    {
        if (showing != null) return;   // --show keeps them for the run only
        Settings.SetCard(new()
        {
            ["cardZoom"] = zoom, ["cardWidthWord"] = wordWidth, ["cardWidthPhrase"] = phraseWidth,
            ["cardPinned"] = pinned ? 1 : 0, ["cardPinnedX"] = pinnedAt?.X, ["cardPinnedY"] = pinnedAt?.Y,
        });
    }

    // MARK: Light and dark

    static bool watching;

    /// Open cards switch to light or dark the moment Windows does, as the Mac's do
    /// (CC:262-270, PU:709-712): the colours change in place, with no closing or motion.
    static void WatchTheme()
    {
        if (watching) return;
        watching = true;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is not (Microsoft.Win32.UserPreferenceCategory.General or Microsoft.Win32.UserPreferenceCategory.VisualStyle or Microsoft.Win32.UserPreferenceCategory.Color)) return;
            Application.Current?.Dispatcher.BeginInvoke(ThemeChanged);
        };
    }

    static void ThemeChanged()
    {
        var dark = Theme.SystemDark();
        if (dark == Theme.Dark) return;
        Theme.Dark = dark;
        foreach (var w in open.ToArray()) w.Retheme();
        Core.Log($"{{\"event\":\"theme\",\"dark\":{(dark ? "true" : "false")},\"cards\":{open.Count}}}");
    }

    readonly Border hairline = new() { BorderThickness = new Thickness(0.5), CornerRadius = new CornerRadius(16), IsHitTestVisible = false, UseLayoutRounding = false };
    readonly Border badgeCircle = new() { Width = 20, Height = 20, CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(0.5), UseLayoutRounding = false };
    readonly Path badgeX = new() { Data = Geometry.Parse("M 7,7 L 13,13 M 13,7 L 7,13"), StrokeThickness = 1.6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Width = 20, Height = 20 };
    string? hintText;

    /// The chrome's colours from the theme, as now.
    void Paint()
    {
        surface.Background = Theme.Surface;
        ((Border)layers[0]).Background = Theme.Surface;
        ((Border)layers[1]).Background = Theme.Surface;
        hairline.BorderBrush = Theme.Hairline;
        foreach (Line l in grip.Children) l.Stroke = Theme.Fill(resizing ? 0.45 : 0.22);
        grabber.Background = Theme.Fill(resizing ? 0.40 : 0.20);
        badgeCircle.Background = Theme.Surface;
        badgeCircle.BorderBrush = Theme.Fill(0.12);
        badgeX.Stroke = badge.IsMouseOver ? Theme.Primary : Theme.Secondary;
    }

    /// Light or dark changed: the chrome and the content again in the new colours, in place.
    void Retheme()
    {
        if (gone) return;
        Paint();
        if (isHint && hintText != null) view.Hint(hintText);
        else if (last != null) view.Show(last, animate: false);
        view.SetHovered(hovered);
    }

    // MARK: Opening

    public static void Present(Selected selected) => Present(selected.Bounds, w => w.Open(selected));

    static void Present(Rect? bounds, Action<CardWindow> open)
    {
        var old = current;
        current = new CardWindow(bounds, false);
        // A pinned card opens at its corner for every lookup.
        if (pinned && old != null && !old.isHint && old.IsVisible && !old.closing)
        {
            current.HangFrom(old.CardTopLeft());
            current.TakeOver(old);
            old = null;
        }
        else if (pinned && pinnedAt is Point at) current.HangFrom(at);
        open(current);
        old?.Dismiss();
    }

    /// The saved card JSON --show is showing, if it is.
    static string? showing;

    /// Dev only: `--show CARD.json X Y` (App.cs). Opens the live card for a saved card JSON, as
    /// a lookup of a selection at (X, Y, 60, 20) DIPs on the primary screen would, so it can be
    /// filmed beside the Mac's (`LongyanReader --show` there, same JSON, same numbers). When it
    /// closes it opens again a second later in the same place. The card starts at the usual
    /// size, unpinned; nothing is saved, and nothing goes in the history.
    public static void Show(string json, double x, double y)
    {
        showing = json;
        showX = x; showY = y;
        pinned = false; zoom = 1; wordWidth = phraseWidth = null; pinnedAt = null;
        ShowAgain(x, y);
        var away = false;
        var watch = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(50) };
        watch.Tick += (_, _) =>
        {
            // Closed (Esc, a click away, the close button): open again a second later, as the Mac does.
            if (away || current is { closing: false }) return;
            away = true;
            var again = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromSeconds(1) };
            again.Tick += (_, _) => { again.Stop(); away = false; ShowAgain(x, y); };
            again.Start();
        };
        watch.Start();
    }

    static void ShowAgain(double x, double y)
    {
        Present(null, w =>
        {
            // Points from the primary screen's top-left, in that screen's device pixels.
            var s = w.DpiFor(new Rect(0, 0, 1, 1));
            w.anchor = new Rect(x * s, y * s, 60 * s, 20 * s);
            w.cardID = Core.Shared.Fixture(showing!, w.Update, w.ShowHint);
        });
    }

    /// Draws one card out of sight at launch, so the first real card doesn't pay for WPF's first
    /// window, the fonts and the first compile.
    public static void Warm()
    {
        const string sample = """
            {"kind":"word","word":"中华","copy":"中华","meaning":"China","contextual":false,"note":null,
             "pinyin":[{"text":"Zhōng","tone":1},{"text":"huá","tone":2}],
             "senses":[{"chosen":true,"dimmed":false,"gloss":"China","hasNote":false,"index":0,"number":1,"tip":"China"}]}
            """;
        if (JsonNode.Parse(sample) is not JsonObject json) return;
        Anki.Start();   // asks AnkiConnect, so the first card knows whether to offer Add to Anki
        var w = new CardWindow(null, false) { Left = -30000, Top = -30000, Width = 400, Height = 300 };
        w.view.Show(json, animate: false);
        w.Show();
        w.UpdateLayout();
        w.Dispatcher.BeginInvoke(() => w.Close(), DispatcherPriority.ApplicationIdle);
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
    public static void RenderToFile(JsonObject json, string path, bool pin = false)
    {
        pinned = pin;
        var w = new CardWindow(null, true);
        w.view.AnkiState = (string?)json["anki"];   // the gallery's cards say which Anki state to draw
        w.view.Show(json, animate: false);
        w.Content = null;
        // "shadow": true keeps the shadow, with the window's margin around it (gallery shadow.json).
        var shadow = json["shadow"]?.GetValue<bool>() == true;
        if (!shadow)
        {
            w.card.Children.Remove(w.layers[0]);
            w.card.Children.Remove(w.layers[1]);
        }
        else w.layers[0].VerticalAlignment = w.layers[1].VerticalAlignment = VerticalAlignment.Stretch;
        foreach (var b in w.bands) b.Visibility = Visibility.Collapsed;
        w.card.Margin = new Thickness(shadow ? Frame : 0);
        w.card.Width = w.view.Width;
        w.scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        var backdrop = new Border { Background = Theme.Backdrop, Padding = new Thickness(12), Child = w.frame };
        TextOptions.SetTextFormattingMode(backdrop, TextFormattingMode.Ideal);
        backdrop.Measure(new Size(w.view.Width + 24 + (shadow ? 2 * Frame : 0), double.PositiveInfinity));
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
        view = new CardView(this) { Zoom = zoom, WidthFor = phrase => (phrase ? phraseWidth : wordWidth) / zoom };
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

        card.Margin = new Thickness(Frame);
        card.VerticalAlignment = VerticalAlignment.Top;
        card.HorizontalAlignment = HorizontalAlignment.Left;

        // Content scrolls under the buttons, with no scroll bar; the hairline is drawn over it.
        scroller = new ScrollViewer
        {
            Content = view.Root, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false,
        };
        scroller.ScrollChanged += (_, _) => Fades();
        for (var i = 0; i < fadeStops.Length; i++)
        {
            fadeStops[i] = new GradientStop(Colors.Black, i < 2 ? 0 : 1);
            fadeMask.GradientStops.Add(fadeStops[i]);
        }
        view.Root.LayoutTransform = zoomScale;
        for (var i = 0; i < 3; i++)
        {
            var inset = i * 3.5 + 2;
            grip.Children.Add(new Line { X1 = 11, Y1 = inset, X2 = inset, Y2 = 11, StrokeThickness = 1, Stroke = Theme.Fill(0.22) });
        }
        grabber.Background = Theme.Fill(0.20);
        overlay.Children.Add(scroller);
        overlay.Children.Add(view.Buttons);
        overlay.Children.Add(grip);
        overlay.Children.Add(grabber);
        // No layout rounding here, or the 0.5 line rounds to nothing at 100%.
        overlay.Children.Add(hairline);
        surface = new Border { CornerRadius = new CornerRadius(16), Child = overlay, VerticalAlignment = VerticalAlignment.Top };
        overlay.SizeChanged += (_, _) =>
        {
            overlay.Clip = new RectangleGeometry(new Rect(overlay.RenderSize), 16, 16);
            grabber.Height = Math.Min(22, overlay.ActualHeight * 0.3);
            grabber.Visibility = overlay.ActualHeight > 60 ? Visibility.Visible : Visibility.Hidden;
            Fades();
        };

        // The shadow: two layers cast by copies of the card's outline behind it.
        // WPF's blur radius is three of the Gaussian's sigma; the Mac's shadow radius is one.
        layers = new FrameworkElement[] { Shadow(48, 8, 0.16), Shadow(4.5, 0.5, 0.08), surface };
        foreach (var l in layers) card.Children.Add(l);
        Bands();
        Badge();
        card.Children.Add(badge);
        if (pinned && !offscreen) badge.Visibility = Visibility.Visible;

        var group = new TransformGroup();
        group.Children.Add(revealScale);
        group.Children.Add(revealShift);
        card.RenderTransform = group;
        card.RenderTransformOrigin = new Point(0.5, 0);
        frame.Children.Add(card);
        Content = frame;
        Paint();
        if (offscreen) return;
        WatchTheme();
        open.Add(this);

        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
            HwndSource.FromHwnd(hwnd)?.AddHook(PointerHook);
        };
        // A card that opens under a pointer at rest isn't hovered until the pointer moves, as on
        // the Mac (a tracking area sends no mouseEntered until then): no row highlight, and no
        // edge grabber, which read as a scroll bar. WPF would hover it at once.
        GetCursorPos(out stillAt);
        frame.IsHitTestVisible = false;
        // The Mac shows no tooltips here: AppKit shows them only in the active app, and the card
        // never makes its app active. (Each control keeps its help as its UI Automation name.)
        // (ToolTipOpening goes to the element alone, so it's caught for every element, in cards only.)
        if (!tipsOff)
        {
            tipsOff = true;
            EventManager.RegisterClassHandler(typeof(FrameworkElement), FrameworkElement.ToolTipOpeningEvent,
                new ToolTipEventHandler((sender, e) => { if (sender is DependencyObject d && GetWindow(d) is CardWindow) e.Handled = true; }));
        }
        Closed += (_, _) =>
        {
            gone = true;
            open.Remove(this);
            DropSwap(fade: false);
            Hooks.Remove(this);
            if (cardID != 0) { Anki.Close(cardID); Core.Shared.Close(cardID); }
            if (current == this) current = null;
        };
        card.MouseEnter += (_, _) => Hover(true);
        card.MouseLeave += (_, _) => Hover(false);
        PreviewMouseLeftButtonDown += PressStart;
        PreviewMouseMove += PressMove;
        PreviewMouseLeftButtonUp += PressEnd;
        PreviewMouseWheel += Wheel;
        zoomScale.ScaleX = zoomScale.ScaleY = zoom;
    }

    POINT stillAt;
    static bool tipsOff;

    /// The first real move (or a press) lets the pointer in.
    IntPtr PointerHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (frame.IsHitTestVisible || msg is not (0x200 or 0x201 or 0x204)) return IntPtr.Zero;   // WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_RBUTTONDOWN
        GetCursorPos(out var p);
        if (msg == 0x200 && p.X == stillAt.X && p.Y == stillAt.Y) return IntPtr.Zero;   // Windows' own move as the window shows
        frame.IsHitTestVisible = true;
        Mouse.Synchronize();
        return IntPtr.Zero;
    }

    static Border Shadow(double blur, double y, double alpha) => new()
    {
        CornerRadius = new CornerRadius(16), Background = Theme.Surface, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Top,
        Effect = new DropShadowEffect { BlurRadius = blur, ShadowDepth = y, Direction = 270, Opacity = alpha, Color = Colors.Black, RenderingBias = RenderingBias.Quality },
    };

    /// Opens at a fixed top-left corner (a pinned card, or one opened from inside another).
    void HangFrom(Point topLeft)
    {
        placed = true;
        below = true;
        moved = true;
        cardLeft = topLeft.X;
        edge = topLeft.Y;
    }

    /// Keeps `old` on screen until this card has faded in over it.
    void TakeOver(CardWindow old)
    {
        old.DropSwap(fade: false);
        old.Retire();
        swapping = old;
    }

    /// Lets go of the card this one replaces: closed at once, or faded out.
    void DropSwap(bool fade)
    {
        var old = swapping;
        swapping = null;
        if (old == null) return;
        if (fade) old.FadeOut(); else old.CloseNow();
    }

    void Open(Selected s)
    {
        cardID = Core.Shared.Lookup(s.Passage, s.Start, s.End, Update, ShowHint);
    }

    void ShowHint(string message)
    {
        if (closing) return;
        if (cardID != 0) { Anki.Close(cardID); Core.Shared.Close(cardID); cardID = 0; }
        DropSwap(fade: true);
        isHint = true;
        zoomScale.ScaleX = zoomScale.ScaleY = 1;
        foreach (var b in bands) b.Visibility = Visibility.Collapsed;
        view.Buttons.Children.Clear();
        hintText = message;
        view.Hint(message);
        Arrive();
        // A hint goes by itself.
        After(1.8, Dismiss);
    }

    // MARK: Updates

    void Update(JsonObject json)
    {
        if (showing == null) History.Saw(cardID, json);   // History: what the card says, for the lookup history
        if (closing) return;
        last = json;
        if (!ankiDecided) OpenAnki(json);
        if (!revealed)
        {
            // Hold a word card up to 0.4 s from the lookup for the model's pick, so it opens
            // complete (APP:756, PU:371-375).
            var reading = (string?)json["kind"] != "phrase" && (string?)json["status"] == "Reading the sentence…";
            view.Show(json, animate: false);
            firstContent ??= Stopwatch.StartNew();
            if (reading) { hold ??= After(Math.Max(0, 0.4 - opened.Elapsed.TotalSeconds), Arrive); return; }
            Arrive();
            return;
        }
        var drawing = System.Diagnostics.Stopwatch.StartNew();
        view.Show(json, animate: true);
        var shown = drawing.Elapsed.TotalMilliseconds;
        Resize(animated: true);
        if (Core.Logging) { Core.Log($"{{\"event\":\"drawn\",\"mono\":{(Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency).ToString("F1", System.Globalization.CultureInfo.InvariantCulture)},\"ms\":{drawing.Elapsed.TotalMilliseconds:0.0},{view.Timing},\"resize\":{drawing.Elapsed.TotalMilliseconds - shown:0.0}}}"); Frames(); }
    }

    /// For the UI check: how soon WPF draws a frame after a change, and how evenly over the
    /// next 0.6 s (the motion), from its own rendering clock.
    static void Frames()
    {
        var start = System.Diagnostics.Stopwatch.StartNew();
        double first = -1, last = 0, gap = 0; var count = 0;
        TimeSpan? previous = null;
        EventHandler? tick = null;
        tick = (_, e) =>
        {
            var at = ((RenderingEventArgs)e).RenderingTime;
            if (previous == at) return;   // the same frame, reported twice
            var now = start.Elapsed.TotalMilliseconds;
            if (first < 0) first = now; else gap = Math.Max(gap, now - last);
            last = now; previous = at; count++;
            if (now < 600) return;
            CompositionTarget.Rendering -= tick;
            Core.Log($"{{\"event\":\"frames\",\"first\":{first:0},\"count\":{count},\"gap\":{gap:0}}}");
        };
        CompositionTarget.Rendering += tick;
    }

    /// First content: measure, place, then reveal.
    void Arrive()
    {
        if (revealed || closing) return;
        revealed = true;
        hold?.Stop();
        // The scale of the screen the card goes on, then its side, before it is measured.
        scale = placed ? DpiFor(new Rect(cardLeft, edge, 1, 1)) : DpiFor(anchor);
        ChoosePlacement();
        Width = CardWidth + 2 * Frame;
        Height = 200;
        var waited = firstContent?.Elapsed.TotalMilliseconds ?? 0;
        var showing = Stopwatch.StartNew();
        if (!IsVisible) { Show(); Hooks.Add(this); }
        Resize(animated: false);
        Reveal();
        Announce();
        // How long it waited after its first content (0.4 s at most for a word's pick, unless the
        // app's thread was held up), and how long showing the window took.
        // And where the card went (device pixels), for the UI check to hold against the selection.
        GetWindowRect(Handle, out var r);
        var m = Frame * scale;
        var h = shownHeight * scale;
        var top = below ? r.Top + m : r.Bottom - m - h;
        Core.Log(FormattableString.Invariant($"{{\"event\":\"revealed\",\"waited\":{waited:F0},\"opened\":{opened.Elapsed.TotalMilliseconds:F0},\"show\":{showing.Elapsed.TotalMilliseconds:F1},\"left\":{r.Left + m:F0},\"top\":{top:F0},\"width\":{CardWidth * scale:F0},\"height\":{h:F0},\"below\":{(below ? "true" : "false")},\"scale\":{scale:F2},\"anchor\":[{anchor.Left:F0},{anchor.Top:F0},{anchor.Right:F0},{anchor.Bottom:F0}],\"hint\":{(isHint ? "true" : "false")}}}"));
    }

    /// Below the selection when the card fits there, else whichever side has more room.
    void ChoosePlacement()
    {
        if (placed) return;
        var area = Screen().WorkingArea;
        var s = scale;
        view.Root.InvalidateMeasure();
        view.Root.Measure(new Size(CardWidth, double.PositiveInfinity));
        var content = view.Root.DesiredSize.Height;
        var roomBelow = (area.Bottom - anchor.Bottom) / s - 16;
        var roomAbove = (anchor.Top - area.Top) / s - 16;
        below = roomBelow >= Math.Max(content, 320) || roomBelow >= roomAbove;
        cardLeft = anchor.Left;
        edge = below ? anchor.Bottom + Gap * s : anchor.Top - Gap * s;
        placed = true;
    }

    /// The display scale of the monitor showing most of `r` (device pixels).
    double DpiFor(Rect r)
    {
        var rect = new RECT { Left = (int)r.Left, Top = (int)r.Top, Right = (int)Math.Max(r.Right, r.Left + 1), Bottom = (int)Math.Max(r.Bottom, r.Top + 1) };
        var monitor = MonitorFromRect(ref rect, MONITOR_DEFAULTTONEAREST);
        try
        {
            if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out var x, out _) == 0 && x > 0) return x / 96.0;
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        return VisualTreeHelper.GetDpi(this).DpiScaleX;
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        scale = newDpi.DpiScaleX;
        if (offscreen || !revealed || closing) return;
        // Windows may have resized the window for the new scale; put the card back by its edge.
        Dispatcher.BeginInvoke(() =>
        {
            if (closing || gone || (pressing && WasDrag)) return;
            SetFrame(Math.Max(shownHeight, surface.ActualHeight));
        }, DispatcherPriority.Input);
    }

    /// The content's height as drawn (zoomed), up to the most the card may be.
    double Measure()
    {
        // Only the content's children changed, so the root has to be told to measure again,
        // or it answers with its last size.
        view.Root.InvalidateMeasure();
        view.Root.Measure(new Size(CardWidth, double.PositiveInfinity));
        return Math.Ceiling(Math.Min(view.Root.DesiredSize.Height, MaxHeight()));
    }

    /// The card never takes the focus, so Narrator wouldn't notice it: say what it shows, as
    /// the Mac does for VoiceOver (PU:450-457): the word, its pinyin, its meaning.
    void Announce()
    {
        if (isHint || last == null || !AutomationPeer.ListenerExists(AutomationEvents.Notification)) return;
        var pinyin = string.Join(" ", (last["pinyin"] as JsonArray ?? new JsonArray()).Select(p => (string?)p?["text"] ?? ""));
        var words = new[] { (string?)last["copy"], pinyin, (string?)last["meaning"] ?? (string?)last["translation"] }.Where(w => !string.IsNullOrWhiteSpace(w));
        try
        {
            UIElementAutomationPeer.CreatePeerForElement(frame)?.RaiseNotificationEvent(AutomationNotificationKind.Other,
                AutomationNotificationProcessing.ImportantMostRecent, string.Join(", ", words), "LongyanCard");
        }
        catch (Exception) { }
    }

    void Reveal()
    {
        ScriptRevealed();   // dev only: --show --script (CardWindow.Script.cs)
        card.RenderTransformOrigin = new Point(0.5, below ? 0 : 1);
        // In place only when it replaces a card at the same spot (PU:429-441): a pinned card
        // opening at its corner with no card there springs in as any card does.
        var inPlace = swapping != null;
        var springs = !Motion.Reduced && !inPlace;
        // Held at the start until the window's first frame is drawn: a newly shown layered window
        // takes tens of ms to reach the screen, and a clock started at Show() ran on unseen.
        Opacity = 0;
        if (springs) { revealScale.ScaleX = revealScale.ScaleY = 0.96; revealShift.Y = below ? -4 : 4; }
        void Go()
        {
            if (closing) return;
            // Once this card is in, the one it replaces goes, with no fade.
            // On AppKit's default curve, as the Mac's animator() fade (Motion.Fade), from this
            // frame: the window's first one has just been drawn.
            Motion.Linear(this, OpacityProperty, 0, 1, inPlace ? 0.12 : 0.14, () => DropSwap(fade: false), trace: "fade-in", ease: Motion.Fade, startNow: true);
            if (!springs) return;
            Motion.Spring(revealScale, ScaleTransform.ScaleXProperty, 1, Motion.Reveal, from: 0.96, trace: "reveal-scale");
            Motion.Spring(revealScale, ScaleTransform.ScaleYProperty, 1, Motion.Reveal, from: 0.96);
            Motion.Spring(revealShift, TranslateTransform.YProperty, 0, Motion.Reveal, from: below ? -4 : 4);
        }
        // Not before the window's first frame: started earlier (tried at 40 ms after Show), the
        // fade ran on unseen while a slow first frame was made, and on CI it then showed at 1.
        if (firstFrame) Go();
        else ContentRendered += (_, _) => { firstFrame = true; Go(); };
    }

    bool firstFrame;

    /// Sets the card's height for its content: the window grows at once and the card animates
    /// inside it; when it shrinks, the window follows 0.32 s later.
    void Resize(bool animated)
    {
        var width = CardWidth;
        card.Width = width;
        foreach (var l in layers) l.Width = width;
        var target = Measure();
        shrink?.Stop();
        if (!animated || resizing)
        {
            foreach (var l in layers) { Motion.Stop(l, HeightProperty); l.BeginAnimation(HeightProperty, null); l.Height = target; }
            shownHeight = target;
            SetFrame(target);
            return;
        }
        var from = surface.ActualHeight > 0 ? surface.ActualHeight : shownHeight;
        if (Math.Abs(target - from) < 0.5 && !Motion.Running(surface, HeightProperty)) { SetFrame(Math.Max(target, from)); return; }
        if (target > held) SetFrame(target);
        // A change while the height is still moving carries on from its speed (SwiftUI retargets).
        if (Motion.Reduced) foreach (var l in layers) Motion.Content(l, HeightProperty, from, target);
        else foreach (var l in layers) Motion.Spring(l, HeightProperty, target, Motion.Card, from, trace: l == surface ? "height" : null);
        shownHeight = target;
        // The window gives back spare room once the motion is over (resizing it costs a frame).
        if (target < from && held > target + 2 * Spare) shrink = After(0.6, () => SetFrame(target, giveBack: true));
    }

    /// The height the window holds for the card, which can be more than the card: transparent
    /// pixels let clicks through, and growing within it needs no resize of the window (WPF
    /// redraws a transparent window's whole surface when its size changes, 40 ms or more).
    double held;
    const double Spare = 160;

    /// Sizes the window for a card `height` tall and places it by the selection, in one move.
    void SetFrame(double height, bool giveBack = false)
    {
        if (height > held) held = Math.Min(height + Spare, Math.Max(height, MaxHeight()));
        else if (giveBack) held = height + Spare;
        Place(height);
        card.VerticalAlignment = below ? VerticalAlignment.Top : VerticalAlignment.Bottom;
        foreach (var l in layers) l.VerticalAlignment = card.VerticalAlignment;
    }

    /// The scroll-edge fades: the bottom 36 fades out while there's more below; scrolled, the
    /// content is hidden under the buttons and fades in over 14 below them. "More" is judged
    /// at the height the card is going to, so a growing card doesn't flash the bottom fade.
    /// One mask is kept, and its stops' colors fade over 0.2 s.
    void Fades()
    {
        var drawn = scroller.ActualHeight;
        var h = shownHeight > 0 ? shownHeight : drawn;
        if (h <= 0 || drawn <= 0) return;
        var top = scroller.VerticalOffset > 1;
        var more = scroller.ExtentHeight - scroller.VerticalOffset - h > 2;
        // Offsets follow the height as drawn, so the fades keep their size while it animates.
        var hide = view.Buttons.Margin.Top + CardView.ButtonH;
        fadeStops[0].Offset = 0;
        fadeStops[1].Offset = Math.Min(1, hide / drawn);
        fadeStops[2].Offset = Math.Min(1, (hide + 14 * Zoom) / drawn);
        fadeStops[3].Offset = Math.Max(0, (drawn - 36 * Zoom) / drawn);
        fadeStops[4].Offset = 1;
        if (scroller.OpacityMask != fadeMask) scroller.OpacityMask = fadeMask;
        if (top != fadeTop)
        {
            fadeTop = top;
            FadeStop(fadeStops[0], top);
            FadeStop(fadeStops[1], top);
        }
        if (more != fadeBottom)
        {
            fadeBottom = more;
            FadeStop(fadeStops[4], more);
        }
    }

    void FadeStop(GradientStop stop, bool hidden)
    {
        var to = hidden ? Color.FromArgb(0, 0, 0, 0) : Colors.Black;
        if (offscreen) { stop.Color = to; return; }
        stop.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(to, new Duration(TimeSpan.FromSeconds(0.2))) { EasingFunction = Motion.EaseOut });
    }

    void Hover(bool on)
    {
        hovered = on;
        view.SetHovered(on);
        if (isHint) return;
        Motion.To(grip, OpacityProperty, on || resizing ? 1 : 0, 0.15);
        Motion.To(grabber, OpacityProperty, on || resizing ? 1 : 0, 0.15);
        if (!pinned) return;
        SpringBadge(on);
    }

    // MARK: Placement

    /// The screen the card is on once placed, else the one with the selection.
    System.Windows.Forms.Screen Screen()
    {
        var r = placed
            ? new System.Drawing.Rectangle((int)cardLeft, (int)edge, 1, 1)
            : new System.Drawing.Rectangle((int)anchor.X, (int)anchor.Y, Math.Max(1, (int)anchor.Width), Math.Max(1, (int)anchor.Height));
        return System.Windows.Forms.Screen.FromRectangle(r);
    }

    /// The tallest the card may be: the room from its edge to the screen's on its side, at
    /// most 0.8 of the screen, at least 120.
    double MaxHeight()
    {
        var area = Screen().WorkingArea;
        var s = scale <= 0 ? 1 : scale;
        double room;
        if (placed) room = below ? (area.Bottom - edge) / s - Inset : (edge - area.Top) / s - Inset;
        else room = below ? (area.Bottom - anchor.Bottom) / s - Gap - Inset : (anchor.Top - area.Top) / s - Gap - Inset;
        return Math.Max(120, Math.Min(room, area.Height / s * 0.8));
    }

    void Place(double height)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        ChoosePlacement();
        var area = Screen().WorkingArea;
        var s = scale;
        var w = CardWidth * s;
        var h = height * s;
        var left = Math.Max(area.Left + Inset * s, Math.Min(cardLeft, area.Right - Inset * s - w));
        var top = below ? edge : edge - h;
        top = Math.Max(area.Top + Inset * s, Math.Min(top, area.Bottom - Inset * s - h));
        var m = Frame * s;
        // The card at the window's top when it hangs down, at its bottom when it sits above.
        var hold = Math.Max(h, held * s);
        var windowTop = below ? top - m : top + h - hold - m;
        SetWindowPos(hwnd, IntPtr.Zero, (int)Math.Round(left - m), (int)Math.Round(windowTop),
            (int)Math.Round(w + 2 * m), (int)Math.Round(hold + 2 * m), SWP_NOACTIVATE | SWP_NOZORDER);
    }

    /// The card's corners on screen, in device pixels.
    Rect CardRect()
    {
        GetWindowRect(new WindowInteropHelper(this).Handle, out var r);
        var m = Frame * scale;
        var h = surface.ActualHeight * scale;
        var top = below ? r.Top + m : r.Bottom - m - h;
        return new Rect(r.Left + m, top, CardWidth * scale, h);
    }

    Point CardTopLeft() => CardRect().TopLeft;

    // MARK: Moving

    bool pressing, flipped;
    POINT pressScreen;
    RECT pressWindow;

    void PressStart(object sender, MouseButtonEventArgs e)
    {
        WasDrag = false;
        flipped = false;
        if (isHint) return;   // hints don't move (PU:637)
        if (e.OriginalSource is DependencyObject d && (IsIn(d, badge) || bands.Exists(b => IsIn(d, b)))) return;
        pressing = true;
        GetCursorPos(out pressScreen);
        GetWindowRect(new WindowInteropHelper(this).Handle, out pressWindow);
        // A card placed above hangs from its top edge from the first click on.
        if (!below && !isHint)
        {
            below = true;
            flipped = true;
            edge = CardTopLeft().Y;
            SetFrame(shownHeight);
            GetWindowRect(new WindowInteropHelper(this).Handle, out pressWindow);
        }
    }

    static bool IsIn(DependencyObject d, DependencyObject parent)
    {
        for (var x = d; x != null; x = x is Visual || x is System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(x) : LogicalTreeHelper.GetParent(x))
            if (x == parent) return true;
        return false;
    }

    void PressMove(object sender, MouseEventArgs e)
    {
        if (!pressing || e.LeftButton != MouseButtonState.Pressed) return;
        GetCursorPos(out var now);
        double dx = now.X - pressScreen.X, dy = now.Y - pressScreen.Y;
        if (!WasDrag && Math.Sqrt(dx * dx + dy * dy) < 4 * scale) return;
        if (!WasDrag) { WasDrag = true; CaptureMouse(); }
        // The card stays 8 inside the screen under the pointer.
        var area = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(now.X, now.Y)).WorkingArea;
        var s = scale;
        double m = Frame * s, pad = Inset * s, w = CardWidth * s, h = surface.ActualHeight * s;
        var offY = below ? m : pressWindow.Bottom - pressWindow.Top - m - h;
        var x = pressWindow.Left + dx + m;
        var y = pressWindow.Top + dy + offY;
        x = Math.Max(area.Left + pad, Math.Min(x, area.Right - pad - w));
        y = Math.Max(area.Top + pad, Math.Min(y, area.Bottom - pad - h));
        SetWindowPos(new WindowInteropHelper(this).Handle, IntPtr.Zero, (int)Math.Round(x - m), (int)Math.Round(y - offY), 0, 0, SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE);
        e.Handled = true;
    }

    void PressEnd(object sender, MouseButtonEventArgs e)
    {
        var wasPressing = pressing;
        pressing = false;
        if (!WasDrag)
        {
            // A press that flipped an above card: its room now runs down from its top.
            if (wasPressing && flipped && !closing) Resize(animated: true);
            flipped = false;
            return;
        }
        ReleaseMouseCapture();
        moved = true;
        dragged = true;
        flipped = false;
        var tl = CardTopLeft();
        cardLeft = tl.X;
        edge = tl.Y;
        if (pinned) { pinnedAt = tl; SaveCard(); }
        e.Handled = true;
        Dispatcher.BeginInvoke(() => WasDrag = false, DispatcherPriority.Input);
        Resize(animated: true);
    }

    /// Ctrl and the wheel change the text size, as a pinch does on the Mac.
    void Wheel(object sender, MouseWheelEventArgs e)
    {
        if (isHint) return;
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            Settle();
            SetZoom(zoom * (e.Delta > 0 ? 1.1 : 1 / 1.1));
            e.Handled = true;
            return;
        }
        // Bounces only when there's something to scroll (.scrollBounceBehavior(.basedOnSize), CC:428).
        if (scroller.ScrollableHeight <= 0) return;
        e.Handled = true;
        var by = -e.Delta / 120.0 * Notch * zoom;
        // A touchpad (and a free-spinning wheel) sends deltas that aren't whole notches, at the
        // rate the fingers move, and Windows sends the momentum after a flick the same way: the
        // card follows them 1:1, as the Mac's does, and stretches at the ends.
        var now = Motion.Now;
        if (e.Delta % 120 != 0) lastPrecise = now;
        if (now - lastPrecise < 0.3) { glideTo = null; Pan(by); return; }
        // A mouse notch: 40 eased over about 0.2 s, as Windows apps glide a notch. (A Mac mouse
        // wheel jumps a line with no glide, and never bounces.)
        Settle();
        Glide(by);
    }

    const double Notch = 40;
    double lastPrecise = double.NegativeInfinity;

    // MARK: Rubber band

    /// How far the content is pulled past an end (DIPs, + at the top, - at the bottom).
    double stretch;
    readonly TranslateTransform stretchShift = new();
    double lastPan, releaseFrom, releaseAt;
    bool releasing;

    /// Scrolls by `by` (DIPs, + down) 1:1, pulling past the ends against AppKit's rubber band:
    /// the stretch is a 20th of the push (NSScrollView, measured: 300 pushed gave 13 to 15, and
    /// WebKit's copy of AppKit's constants says 20), and pushing back takes it in 1:1.
    void Pan(double by)
    {
        lastPan = Motion.Now;
        if (releasing) { releasing = false; }
        if (stretch != 0 && Math.Sign(by) == Math.Sign(stretch))
        {
            // Back toward the content: the stretch gives way 1:1 first.
            var take = Math.Min(Math.Abs(by), Math.Abs(stretch)) * Math.Sign(by);
            stretch -= take;
            by -= take;
        }
        if (by != 0)
        {
            var max = scroller.ScrollableHeight;
            var to = scroller.VerticalOffset + by;
            if (stretch != 0 || to < 0 || to > max)
            {
                var past = stretch != 0 ? by : to < 0 ? to : to - max;
                stretch -= past / 20;
                scroller.ScrollToVerticalOffset(Math.Clamp(to, 0, max));
            }
            else scroller.ScrollToVerticalOffset(to);
        }
        ShowStretch();
        if (stretch != 0) Watch();
    }

    void ShowStretch()
    {
        if (view.Root.RenderTransform != stretchShift) view.Root.RenderTransform = stretchShift;
        // The content is zoomed by its layout transform; the shift is in the card's own DIPs.
        stretchShift.Y = stretch;
    }

    bool banding;

    /// Once the touchpad has been still for a moment (the fingers are up; Windows says no more
    /// than that), a stretch springs back as AppKit's does: e^(-12.5 t) (stiffness 20 over a
    /// period of 1.6, WebKit's copy of AppKit's; the Mac's filmed back 235 to 57 in 0.11 s).
    void Watch()
    {
        if (banding) return;
        banding = true;
        CompositionTarget.Rendering += BandStep;
    }

    void BandStep(object? sender, EventArgs e)
    {
        var now = Motion.Now;
        if (!releasing)
        {
            if (stretch == 0) { Unwatch(); return; }
            if (now - lastPan < 0.1) return;
            releasing = true;
            releaseFrom = stretch;
            releaseAt = now;
            if (Core.Logging) Core.Log(FormattableString.Invariant($"{{\"event\":\"band\",\"stretch\":{stretch:0.00},\"offset\":{scroller.VerticalOffset:0.0}}}"));
        }
        stretch = releaseFrom * Math.Exp(-12.5 * (now - releaseAt));
        if (Math.Abs(stretch) < 0.2)
        {
            stretch = 0;
            releasing = false;
            Unwatch();
            if (Core.Logging) Core.Log(FormattableString.Invariant($"{{\"event\":\"band-back\",\"ms\":{(now - releaseAt) * 1000:0}}}"));
        }
        ShowStretch();
    }

    void Unwatch()
    {
        banding = false;
        CompositionTarget.Rendering -= BandStep;
    }

    /// Drops any stretch at once (a mouse notch, a new card size).
    void Settle()
    {
        if (stretch == 0) return;
        stretch = 0;
        releasing = false;
        ShowStretch();
        Unwatch();
    }

    double? glideTo;
    long glideLast;

    void Glide(double by)
    {
        var to = Math.Clamp((glideTo ?? scroller.VerticalOffset) + by, 0, scroller.ScrollableHeight);
        if (Motion.Reduced) { glideTo = null; scroller.ScrollToVerticalOffset(to); return; }
        if (glideTo == null) { glideLast = System.Diagnostics.Stopwatch.GetTimestamp(); CompositionTarget.Rendering += GlideStep; }
        glideTo = to;
    }

    void GlideStep(object? sender, EventArgs e)
    {
        if (glideTo is not double to) { CompositionTarget.Rendering -= GlideStep; return; }
        var now = System.Diagnostics.Stopwatch.GetTimestamp();
        var dt = (now - glideLast) / (double)System.Diagnostics.Stopwatch.Frequency;
        glideLast = now;
        to = Math.Min(to, scroller.ScrollableHeight);
        var at = scroller.VerticalOffset;
        var next = at + (to - at) * (1 - Math.Exp(-Math.Min(dt, 0.05) / 0.06));   // about 0.2 s to settle
        if (Math.Abs(to - next) < 0.5) { next = to; glideTo = null; CompositionTarget.Rendering -= GlideStep; }
        scroller.ScrollToVerticalOffset(next);
    }

    /// A new text size: saved widths scale with it, so cards keep their shape.
    void SetZoom(double z)
    {
        z = Math.Clamp(z, 0.8, 2.2);
        var ratio = z / zoom;
        if (wordWidth != null) wordWidth *= ratio;
        if (phraseWidth != null) phraseWidth *= ratio;
        zoom = z;
        Relayout();
        SaveCard();
    }

    /// Draws the content again at the current zoom and width, with no animation.
    void Relayout()
    {
        view.Zoom = zoom;
        zoomScale.ScaleX = zoomScale.ScaleY = zoom;
        if (last != null) view.Show(last, animate: false);
        Resize(animated: false);
    }

    // MARK: Resizing

    enum Grab { Left, Right, TopLeft, TopRight, BottomLeft, BottomRight }

    /// Bands straddling the card's edges, half in the shadow margin: the sides change the width,
    /// the corners the text size and width together.
    void Bands()
    {
        Band(Grab.Left, 8, double.NaN, new Thickness(-4, 10, 0, 10), HorizontalAlignment.Left, VerticalAlignment.Stretch, Cursors.SizeWE);
        Band(Grab.Right, 12, double.NaN, new Thickness(0, 10, -4, 10), HorizontalAlignment.Right, VerticalAlignment.Stretch, Cursors.SizeWE);
        Band(Grab.TopLeft, 14, 14, new Thickness(-4, -4, 0, 0), HorizontalAlignment.Left, VerticalAlignment.Top, Cursors.SizeNWSE);
        Band(Grab.TopRight, 14, 14, new Thickness(0, -4, -4, 0), HorizontalAlignment.Right, VerticalAlignment.Top, Cursors.SizeNESW);
        Band(Grab.BottomLeft, 14, 14, new Thickness(-4, 0, 0, -4), HorizontalAlignment.Left, VerticalAlignment.Bottom, Cursors.SizeNESW);
        Band(Grab.BottomRight, 26, 26, new Thickness(0, 0, -4, -4), HorizontalAlignment.Right, VerticalAlignment.Bottom, Cursors.SizeNWSE);
    }

    void Band(Grab grab, double width, double height, Thickness margin, HorizontalAlignment h, VerticalAlignment v, Cursor cursor)
    {
        // Nearly clear, not clear: a fully clear pixel of a layered window lets clicks through.
        var band = new Border { Width = width, Height = height, Margin = margin, HorizontalAlignment = h, VerticalAlignment = v, Cursor = cursor, Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) };
        // Check on Windows: tooltips may not open on a window that is never activated.
        if (grab is not (Grab.Left or Grab.Right)) band.ToolTip = "Drag to resize · double-click for actual size";
        Rect start = default;
        POINT from = default;
        double startZoom = 1, startWidth = 0;
        band.MouseLeftButtonDown += (_, e) =>
        {
            e.Handled = true;
            if (e.ClickCount == 2)
            {
                // An edge: the default width. A corner: actual size.
                if (grab is Grab.Left or Grab.Right) { if (IsPhrase) phraseWidth = null; else wordWidth = null; Relayout(); SaveCard(); }
                else
                {
                    // The other kind of card keeps its shape at the new text size.
                    var ratio = 1 / zoom;
                    if (IsPhrase) { phraseWidth = null; if (wordWidth != null) wordWidth *= ratio; }
                    else { wordWidth = null; if (phraseWidth != null) phraseWidth *= ratio; }
                    zoom = 1;
                    Relayout();
                    SaveCard();
                }
                return;
            }
            resizing = true;
            moved = true;
            dragged = true;
            band.CaptureMouse();
            GetCursorPos(out from);
            start = CardRect();
            startZoom = zoom;
            startWidth = CardWidth;
            foreach (Line l in grip.Children) l.Stroke = Theme.Fill(0.45);
            grabber.Background = Theme.Fill(0.40);
        };
        band.MouseMove += (_, e) =>
        {
            if (!resizing || !band.IsMouseCaptured) return;
            GetCursorPos(out var now);
            double dx = (now.X - from.X) / scale, dy = (now.Y - from.Y) / scale;
            var area = Screen().WorkingArea;
            var widest = Math.Max(Narrowest, Math.Min(Widest, area.Width / scale - 2 * Inset));
            double width;
            var right = grab is Grab.Right or Grab.TopRight or Grab.BottomRight;
            var bottom = grab is Grab.BottomLeft or Grab.BottomRight or Grab.Left or Grab.Right;
            // An edge stops at the screen, given the opposite edge stays put.
            if (grab is Grab.Right) width = Math.Clamp(startWidth + dx, Narrowest, Math.Max(Narrowest, Math.Min(Widest, (area.Right - Inset * scale - start.Left) / scale)));
            else if (grab is Grab.Left) width = Math.Clamp(startWidth - dx, Narrowest, Math.Max(Narrowest, Math.Min(Widest, (start.Right - area.Left - Inset * scale) / scale)));
            else
            {
                double w = start.Width / scale, hgt = start.Height / scale;
                var outX = right ? dx : -dx;
                var outY = bottom ? dy : -dy;
                var f = 1 + (outX * w + outY * hgt) / (w * w + hgt * hgt);
                var z = Math.Clamp(startZoom * f, 0.8, 2.2);
                width = Math.Clamp(startWidth * z / startZoom, Narrowest, widest);
                var ratio = z / zoom;
                if (IsPhrase) { if (wordWidth != null) wordWidth *= ratio; } else if (phraseWidth != null) phraseWidth *= ratio;
                zoom = z;
            }
            if (IsPhrase) phraseWidth = width; else wordWidth = width;
            // The opposite edge or corner stays put.
            cardLeft = right ? start.Left : start.Right - width * scale;
            below = bottom;
            edge = bottom ? start.Top : start.Bottom;
            Relayout();
        };
        band.MouseLeftButtonUp += (_, _) =>
        {
            if (!resizing) return;
            resizing = false;
            band.ReleaseMouseCapture();
            foreach (Line l in grip.Children) l.Stroke = Theme.Fill(0.22);
            grabber.Background = Theme.Fill(0.20);
            // From here the card hangs from its top, so later growth goes down.
            var tl = CardTopLeft();
            below = true;
            edge = tl.Y;
            Resize(animated: false);
            if (pinned) pinnedAt = tl;
            SaveCard();
            if (!hovered) Hover(false);
        };
        bands.Add(band);
        card.Children.Add(band);
    }

    bool IsPhrase => (string?)last?["kind"] == "phrase";

    // MARK: Closing

    /// The pinned card's close badge, over its top-left corner, shown while the pointer is on it.
    void Badge()
    {
        var circle = badgeCircle;
        circle.Effect = new DropShadowEffect { BlurRadius = 4, ShadowDepth = 1, Direction = 270, Opacity = 0.12, Color = Colors.Black };
        var x = badgeX;
        // The press dims the circle and the x together.
        var face = new Grid { Width = 20, Height = 20 };
        face.Children.Add(circle);
        face.Children.Add(x);
        badge.Children.Add(face);
        badge.RenderTransform = badgeScale;
        badge.RenderTransformOrigin = new Point(0.5, 0.5);
        badge.MouseEnter += (_, _) => x.Stroke = Theme.Primary;
        badge.MouseLeave += (_, _) => { x.Stroke = Theme.Secondary; Motion.To(face, OpacityProperty, 1, 0.08); };
        badge.MouseLeftButtonDown += (_, e) => { Motion.To(face, OpacityProperty, 0.55, 0.08); e.Handled = true; };
        badge.MouseLeftButtonUp += (_, e) => { e.Handled = true; Motion.To(face, OpacityProperty, 1, 0.08); Dismiss(); };
    }

    /// Springs the close badge away, then hides it (on unpinning).
    void HideBadge() => SpringBadge(false, () => { if (!pinned) badge.Visibility = Visibility.Collapsed; });

    /// The badge's opacity and scale (0.7 hidden) on its spring, carrying on from any spring
    /// still under way, as a quick in and out on the Mac does.
    void SpringBadge(bool on, Action? done = null)
    {
        Motion.Spring(badge, OpacityProperty, on ? 1 : 0, Motion.Badge, done: done);
        Motion.Spring(badgeScale, ScaleTransform.ScaleXProperty, on ? 1 : 0.7, Motion.Badge);
        Motion.Spring(badgeScale, ScaleTransform.ScaleYProperty, on ? 1 : 0.7, Motion.Badge);
    }

    public void Dismiss()
    {
        if (closing) return;
        Retire();
        DropSwap(fade: true);
        FadeOut();
    }

    /// Stops the card taking part (updates, hooks, speech) while it is still on screen.
    void Retire()
    {
        closing = true;
        hold?.Stop();
        Hooks.Remove(this);
        Speech.Stop();
    }

    void FadeOut()
    {
        if (gone) return;
        if (!IsVisible) { CloseNow(); return; }
        // The whole 0.12 s on AppKit's default curve (Motion.Fade), from where it is and from
        // now, so it never waits on a frame; the window goes only after 0 is drawn.
        var from = Opacity;
        Motion.Linear(this, OpacityProperty, from, 0, 0.12, CloseNow, trace: "fade-out", ease: Motion.Fade, startNow: true);
    }

    void CloseNow()
    {
        if (!gone) Close();
    }

    /// From the hooks: a click or scroll somewhere else, or Esc.
    /// `window` is the top-level window the click or scroll is over when it's one of this app's
    /// own (the eye, History, Settings), else zero: like the Mac's global monitors, which see
    /// only other apps' events, those leave the card open. So does Esc in those windows.
    public void Outside(Hooks.Kind kind, POINT at, IntPtr window)
    {
        if (closing || pinned && !isHint) return;
        if (kind == Hooks.Kind.Escape) { if (window == IntPtr.Zero) Dismiss(); return; }
        if (window != IntPtr.Zero && !open.Exists(w => w.Handle == window)) return;
        if (Contains(at)) return;
        if (kind == Hooks.Kind.Scroll && dragged) return;
        Dismiss();
    }

    /// On the card or its resize bands (the shadow margin around them is click-through).
    bool Contains(POINT p)
    {
        var r = CardRect();
        r.Inflate(4 * scale, 4 * scale);
        return r.Contains(new Point(p.X, p.Y));
    }

    DispatcherTimer After(double seconds, Action act)
    {
        // Normal, not the default Background: a Background timer waits while anything of higher
        // priority is queued (each frame's rendering, input), and on a slow machine the hold
        // ran 1.4 s instead of 0.4 (the CI's eye card), or longer.
        var t = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); act(); };
        t.Start();
        return t;
    }

    // MARK: ICardActions

    // Each answered at once (Core.DrainNow), not when the core's queue next signals.
    public void Pick(int token, int sense)
    {
        Act("pick");
        var t = Stopwatch.StartNew();
        Bridge.ly_pick(cardID, token, sense);
        var core = t.Elapsed.TotalMilliseconds;
        Core.Shared.DrainNow();
        if (Core.Logging) Core.Log(FormattableString.Invariant($"{{\"event\":\"pick-timing\",\"mono\":{Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency:F1},\"core\":{core:0.0},\"drained\":{t.Elapsed.TotalMilliseconds:0.0}}}"));
    }
    public void UseSuggested(int token) { Act("back"); Bridge.ly_use_suggested(cardID, token); Core.Shared.DrainNow(); }
    public void ToggleAll(int token) { Act("all"); Bridge.ly_toggle_all(cardID, token); Core.Shared.DrainNow(); }
    public void ToggleRow(int token) { Act("row"); Bridge.ly_toggle_row(cardID, token); Core.Shared.DrainNow(); }

    static void Act(string what) { if (Core.Logging) Core.Log($"{{\"event\":\"action\",\"what\":\"{what}\"}}"); }

    /// Part of: a new card replaces this one, hanging from the same corner.
    public void OpenPartOf()
    {
        if (closing) return;
        var next = new CardWindow(null, false);
        next.HangFrom(CardTopLeft());
        // This card stays up until the new one has faded in over it.
        next.TakeOver(this);
        current = next;
        next.cardID = Core.Shared.OpenPartOf(cardID, next.Update, next.ShowHint);
    }

    // After the frame that starts the button's release (Clipboard.SetText can hold the thread for
    // tens of ms, and the button's motion with it).
    public void Copy(string text) => Dispatcher.BeginInvoke(DispatcherPriority.Background, () => { try { Clipboard.SetText(text); } catch { } });

    // MARK: Anki

    /// As the card opens: the Anki button if AnkiConnect answered the last check and the card
    /// has something to add, so the row of buttons doesn't change while the card is up. Then a
    /// check for the next card, in case Anki was opened or quit since.
    void OpenAnki(JsonObject json)
    {
        ankiDecided = true;
        if (Anki.Available && Anki.HasNote(json))
        {
            view.AnkiState = "ready";
            Anki.Open(cardID, AnkiChanged);
        }
        Anki.Check();
    }

    void AnkiChanged(string state, string message)
    {
        if (closing || gone) return;
        if (state == "none")
        {
            // The core found nothing to add after all: no button.
            if (view.AnkiState == null) return;
            view.AnkiState = null;
            if (last != null) { view.Show(last, animate: revealed); if (revealed) Resize(animated: true); }
            return;
        }
        view.SetAnki(state, message);
    }

    public void AddToAnki() { Act("anki"); Anki.Click(cardID); }
    /// Says the text, or stops if it's being said (the Mac's Listen turns into Stop).
    public void Listen(string text) { if (Speech.Speaking == text) Speech.Stop(); else Speech.Say(text); }

    public void TogglePin()
    {
        pinned = !pinned;
        if (!pinned) HideBadge();
        else
        {
            badge.Visibility = Visibility.Visible;
            // Pinning keeps the card where it is and hangs it from its top-left corner.
            var tl = CardTopLeft();
            pinnedAt = tl;
            below = true; moved = true; edge = tl.Y; cardLeft = tl.X;
            SetFrame(shownHeight);
            Hover(hovered);
        }
        // Only the pin button changes: the rest stays as it is, mid-motion (a rebuild here held
        // the thread and snapped the buttons' release and the rows' hover).
        if (last != null && !view.PinChanged()) view.Show(last, animate: true);
        SaveCard();
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
    const uint MONITOR_DEFAULTTONEAREST = 2;
    const int MDT_EFFECTIVE_DPI = 0;
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
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
        // The window it's for, when it's one of ours: the one under the pointer for a click or
        // scroll, the one in front for a key.
        var w = kind == Kind.Escape ? GetForegroundWindow() : GetAncestor(WindowFromPoint(at), GA_ROOT);
        GetWindowThreadProcessId(w, out var pid);
        var ours = w != IntPtr.Zero && pid == (uint)Environment.ProcessId ? w : IntPtr.Zero;
        // Later, on the app's thread: a hook must return quickly.
        Application.Current?.Dispatcher.BeginInvoke(() => { foreach (var c in cards.ToArray()) c.Outside(kind, at, ours); });
    }

    static IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var m = (int)wParam;
            if (m is WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_MOUSEWHEEL or WM_MOUSEHWHEEL)
                Tell(m is WM_MOUSEWHEEL or WM_MOUSEHWHEEL ? Kind.Scroll : Kind.Click, Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam).pt);
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    static IntPtr KeyHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (int)wParam == WM_KEYDOWN && Marshal.ReadInt32(lParam) == 0x1B) Tell(Kind.Escape, default);
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14, WM_KEYDOWN = 0x100, WM_LBUTTONDOWN = 0x201, WM_RBUTTONDOWN = 0x204, WM_MOUSEWHEEL = 0x20A, WM_MOUSEHWHEEL = 0x20E;
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public CardWindow.POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string? name);
    const uint GA_ROOT = 2;
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(CardWindow.POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}

/// Listen: Windows' own Chinese voice, when one is installed.
static class Speech
{
    static System.Speech.Synthesis.SpeechSynthesizer? synth;
    static bool looked, found;

    public static bool Available { get { Find(); return found; } }

    /// For the UI check, whose desktop has no Chinese voice: "says" each text for 2.5 s, silently.
    static readonly bool fake = Environment.GetEnvironmentVariable("LONGYAN_FAKE_SPEECH") == "1";
    static DispatcherTimer? fakeDone;

    static void Find()
    {
        if (looked) return;
        looked = true;
        if (fake) { found = true; return; }
        try
        {
            synth = new System.Speech.Synthesis.SpeechSynthesizer();
            synth.SpeakCompleted += Done;
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

    /// What's being said now, if anything; Changed fires on the UI thread when that changes.
    public static string? Speaking { get; private set; }
    public static event Action? Changed;
    static System.Speech.Synthesis.Prompt? prompt;

    public static void Say(string text)
    {
        Find();
        if (fake)
        {
            fakeDone?.Stop();
            fakeDone = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromSeconds(2.5) };
            fakeDone.Tick += (_, _) => { fakeDone?.Stop(); Set(null); };
            fakeDone.Start();
            Set(text);
            return;
        }
        if (!found || synth == null) return;
        synth.SpeakAsyncCancelAll();
        prompt = synth.SpeakAsync(text);
        Set(text);
    }

    public static void Stop()
    {
        try { synth?.SpeakAsyncCancelAll(); } catch { }
        fakeDone?.Stop();
        prompt = null;
        Set(null);
    }

    static void Set(string? text)
    {
        Speaking = text;
        Changed?.Invoke();
    }

    static void Done(object? sender, System.Speech.Synthesis.SpeakCompletedEventArgs e)
    {
        var p = e.Prompt;
        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => { if (p == prompt) { prompt = null; Set(null); } });
    }
}
