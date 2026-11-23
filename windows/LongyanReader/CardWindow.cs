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
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Longyan;

/// The card's window: a transparent frame 28 larger than the card on every side, to hold its
/// shadow, over the other app and never taking the focus from it (notes/card-spec.md, 1 and 6).
sealed class CardWindow : Window, ICardActions
{
    static CardWindow? current;
    static bool pinned;
    static double zoom = 1;
    static double? wordWidth, phraseWidth;
    static Point? pinnedAt;                  // a pinned card's top-left corner, device pixels   // widths set by dragging an edge, DIPs as drawn
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

    // Placement, in device pixels: the selection, and whether the card hangs below it.
    Rect anchor;
    bool below = true, placed, moved, revealed, closing, isHint, hovered, resizing;
    double scale = 1;
    double shownHeight;                       // the card's target height, DIPs
    double cardLeft, edge;                    // device pixels: the card's left, and its top (below) or bottom (above)
    DispatcherTimer? shrink, hold;
    JsonObject? last;

    public bool Pinned => pinned;
    public bool CanListen => offscreen || Speech.Available;
    double Zoom => isHint ? 1 : zoom;
    double CardWidth => view.Width * Zoom;

    // MARK: Opening

    public static void Present(Selected selected)
    {
        var old = current;
        current = new CardWindow(selected.Bounds, false);
        // A pinned card opens at its corner for every lookup.
        if (pinned && old != null && !old.isHint && old.IsVisible) current.HangFrom(old.CardTopLeft(), old.scale);
        else if (pinned && pinnedAt is Point at) current.HangFrom(at, 1);
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
        w.card.Children.Remove(w.layers[0]);
        w.card.Children.Remove(w.layers[1]);
        foreach (var b in w.bands) b.Visibility = Visibility.Collapsed;
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
        view.Root.LayoutTransform = zoomScale;
        for (var i = 0; i < 3; i++)
        {
            var inset = i * 3.5 + 2;
            grip.Children.Add(new Line { X1 = 11, Y1 = inset, X2 = inset, Y2 = 11, StrokeThickness = 1, Stroke = Theme.Ink(0.22) });
        }
        grabber.Background = Theme.Ink(0.20);
        overlay.Children.Add(scroller);
        overlay.Children.Add(view.Buttons);
        overlay.Children.Add(grip);
        overlay.Children.Add(grabber);
        overlay.Children.Add(new Border { BorderBrush = Theme.Hairline, BorderThickness = new Thickness(0.5), CornerRadius = new CornerRadius(16), IsHitTestVisible = false });
        surface = new Border { Background = Theme.Surface, CornerRadius = new CornerRadius(16), Child = overlay, VerticalAlignment = VerticalAlignment.Top };
        overlay.SizeChanged += (_, _) =>
        {
            overlay.Clip = new RectangleGeometry(new Rect(overlay.RenderSize), 16, 16);
            grabber.Height = Math.Min(22, overlay.ActualHeight * 0.3);
            grabber.Visibility = overlay.ActualHeight > 60 ? Visibility.Visible : Visibility.Hidden;
            Fades();
        };

        // The shadow: two layers cast by copies of the card's outline behind it.
        layers = new FrameworkElement[] { Shadow(32, 8, 0.16), Shadow(3, 0.5, 0.08), surface };
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
        card.MouseEnter += (_, _) => Hover(true);
        card.MouseLeave += (_, _) => Hover(false);
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
        zoomScale.ScaleX = zoomScale.ScaleY = 1;
        foreach (var b in bands) b.Visibility = Visibility.Collapsed;
        view.Buttons.Children.Clear();
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
        Width = CardWidth + 2 * Frame;
        Height = 200;
        if (!IsVisible) { Show(); Hooks.Add(this); }
        scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        Resize(animated: false);
        Reveal();
    }

    /// The content's height as drawn (zoomed), up to the most the card may be.
    double Measure()
    {
        view.Root.Measure(new Size(CardWidth, double.PositiveInfinity));
        return Math.Ceiling(Math.Min(view.Root.DesiredSize.Height, MaxHeight()));
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
        var width = CardWidth;
        card.Width = width;
        foreach (var l in layers) l.Width = width;
        var target = Measure();
        shrink?.Stop();
        if (!animated || resizing)
        {
            foreach (var l in layers) { l.BeginAnimation(HeightProperty, null); l.Height = target; }
            shownHeight = target;
            SetFrame(target);
            return;
        }
        var from = surface.ActualHeight > 0 ? surface.ActualHeight : shownHeight;
        if (Math.Abs(target - from) < 0.5) { SetFrame(Math.Max(target, from)); return; }
        if (target > from) SetFrame(target);
        foreach (var l in layers)
        {
            var a = new DoubleAnimation(from, target, Motion.Reduced ? new Duration(TimeSpan.FromSeconds(0.15)) : Motion.CardDuration)
            {
                EasingFunction = Motion.Reduced ? new QuadraticEase { EasingMode = EasingMode.EaseInOut } : Motion.Card,
            };
            l.BeginAnimation(HeightProperty, a);
        }
        shownHeight = target;
        if (target < from) shrink = After(0.32, () => SetFrame(target));
    }

    /// Sizes the window for a card `height` tall and places it by the selection.
    void SetFrame(double height)
    {
        Width = CardWidth + 2 * Frame;
        Height = height + 2 * Frame;
        Place(height);
        card.VerticalAlignment = below ? VerticalAlignment.Top : VerticalAlignment.Bottom;
        foreach (var l in layers) l.VerticalAlignment = card.VerticalAlignment;
    }

    /// The scroll-edge fades: the bottom 36 fades out while there's more below; scrolled, the
    /// content is hidden under the buttons and fades in over 14 below them.
    void Fades()
    {
        var h = scroller.ActualHeight;
        if (h <= 0) return;
        var top = scroller.VerticalOffset > 1;
        var more = scroller.ExtentHeight - scroller.VerticalOffset - h > 2;
        if (!top && !more) { scroller.OpacityMask = null; return; }
        var mask = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        if (top)
        {
            var hide = view.Buttons.Margin.Top + CardView.ButtonH;
            mask.GradientStops.Add(new GradientStop(Colors.Transparent, 0));
            mask.GradientStops.Add(new GradientStop(Colors.Transparent, hide / h));
            mask.GradientStops.Add(new GradientStop(Colors.Black, Math.Min(1, (hide + 14 * Zoom) / h)));
        }
        else mask.GradientStops.Add(new GradientStop(Colors.Black, 0));
        if (more)
        {
            mask.GradientStops.Add(new GradientStop(Colors.Black, Math.Max(0, (h - 36 * Zoom) / h)));
            mask.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
        }
        else mask.GradientStops.Add(new GradientStop(Colors.Black, 1));
        scroller.OpacityMask = mask;
    }

    void Hover(bool on)
    {
        hovered = on;
        view.SetHovered(on);
        if (isHint) return;
        Motion.To(grip, OpacityProperty, on || resizing ? 1 : 0, 0.15);
        Motion.To(grabber, OpacityProperty, on || resizing ? 1 : 0, 0.15);
        if (!pinned) return;
        Motion.Animate(badge, OpacityProperty, badge.Opacity, on ? 1 : 0, Motion.BadgeDuration, Motion.Badge);
        Motion.Animate(badgeScale, ScaleTransform.ScaleXProperty, badgeScale.ScaleX, on ? 1 : 0.7, Motion.BadgeDuration, Motion.Badge);
        Motion.Animate(badgeScale, ScaleTransform.ScaleYProperty, badgeScale.ScaleY, on ? 1 : 0.7, Motion.BadgeDuration, Motion.Badge);
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
        if (placed && moved) room = below ? (area.Bottom - edge) / s - Inset : (edge - area.Top) / s - Inset;
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
            view.Root.Measure(new Size(CardWidth, double.PositiveInfinity));
            var content = view.Root.DesiredSize.Height;
            var roomBelow = (area.Bottom - anchor.Bottom) / s - 16;
            var roomAbove = (anchor.Top - area.Top) / s - 16;
            below = roomBelow >= Math.Max(content, 320) || roomBelow >= roomAbove;
            cardLeft = anchor.Left;
            edge = below ? anchor.Bottom + Gap * s : anchor.Top - Gap * s;
        }
        var w = CardWidth * s;
        var h = height * s;
        var left = Math.Max(area.Left + Inset * s, Math.Min(cardLeft, area.Right - Inset * s - w));
        var top = below ? edge : edge - h;
        top = Math.Max(area.Top + Inset * s, Math.Min(top, area.Bottom - Inset * s - h));
        var m = Frame * s;
        SetWindowPos(hwnd, IntPtr.Zero, (int)Math.Round(left - m), (int)Math.Round(top - m),
            (int)Math.Round(w + 2 * m), (int)Math.Round(h + 2 * m), SWP_NOACTIVATE | SWP_NOZORDER);
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

    bool pressing;
    POINT pressScreen;
    RECT pressWindow;

    void PressStart(object sender, MouseButtonEventArgs e)
    {
        WasDrag = false;
        if (e.OriginalSource is DependencyObject d && (IsIn(d, badge) || bands.Exists(b => IsIn(d, b)))) return;
        pressing = true;
        GetCursorPos(out pressScreen);
        GetWindowRect(new WindowInteropHelper(this).Handle, out pressWindow);
        // A card placed above hangs from its top edge from the first click on.
        if (!below && !isHint)
        {
            below = true;
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
        if (pinned) pinnedAt = tl;
        e.Handled = true;
        Dispatcher.BeginInvoke(() => WasDrag = false, DispatcherPriority.Input);
    }

    /// Ctrl and the wheel change the text size, as a pinch does on the Mac.
    void Wheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0 || isHint) return;
        SetZoom(zoom * (e.Delta > 0 ? 1.1 : 1 / 1.1));
        e.Handled = true;
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
        Band(Grab.Left, 8, double.NaN, new Thickness(-4, 14, 0, 14), HorizontalAlignment.Left, VerticalAlignment.Stretch, Cursors.SizeWE);
        Band(Grab.Right, 12, double.NaN, new Thickness(0, 14, -4, 14), HorizontalAlignment.Right, VerticalAlignment.Stretch, Cursors.SizeWE);
        Band(Grab.TopLeft, 14, 14, new Thickness(-4, -4, 0, 0), HorizontalAlignment.Left, VerticalAlignment.Top, Cursors.SizeNWSE);
        Band(Grab.TopRight, 14, 14, new Thickness(0, -4, -4, 0), HorizontalAlignment.Right, VerticalAlignment.Top, Cursors.SizeNESW);
        Band(Grab.BottomLeft, 14, 14, new Thickness(-4, 0, 0, -4), HorizontalAlignment.Left, VerticalAlignment.Bottom, Cursors.SizeNESW);
        Band(Grab.BottomRight, 26, 26, new Thickness(0, 0, -4, -4), HorizontalAlignment.Right, VerticalAlignment.Bottom, Cursors.SizeNWSE);
    }

    void Band(Grab grab, double width, double height, Thickness margin, HorizontalAlignment h, VerticalAlignment v, Cursor cursor)
    {
        // Nearly clear, not clear: a fully clear pixel of a layered window lets clicks through.
        var band = new Border { Width = width, Height = height, Margin = margin, HorizontalAlignment = h, VerticalAlignment = v, Cursor = cursor, Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) };
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
                if (grab is Grab.Left or Grab.Right) { if (IsPhrase) phraseWidth = null; else wordWidth = null; Relayout(); }
                else { wordWidth = phraseWidth = null; zoom = 1; Relayout(); }
                return;
            }
            resizing = true;
            moved = true;
            band.CaptureMouse();
            GetCursorPos(out from);
            start = CardRect();
            startZoom = zoom;
            startWidth = CardWidth;
            foreach (Line l in grip.Children) l.Stroke = Theme.Ink(0.45);
            grabber.Background = Theme.Ink(0.40);
        };
        band.MouseMove += (_, e) =>
        {
            if (!resizing || !band.IsMouseCaptured) return;
            GetCursorPos(out var now);
            double dx = (now.X - from.X) / scale, dy = (now.Y - from.Y) / scale;
            var area = Screen().WorkingArea;
            var widest = Math.Min(Widest, area.Width / scale - 2 * Inset);
            double width;
            var right = grab is Grab.Right or Grab.TopRight or Grab.BottomRight;
            var bottom = grab is Grab.BottomLeft or Grab.BottomRight or Grab.Left or Grab.Right;
            if (grab is Grab.Left or Grab.Right) width = Math.Clamp(startWidth + (right ? dx : -dx), Narrowest, widest);
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
            foreach (Line l in grip.Children) l.Stroke = Theme.Ink(0.22);
            grabber.Background = Theme.Ink(0.20);
            if (pinned) pinnedAt = CardTopLeft();
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
        var circle = new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Theme.Surface,
            BorderBrush = Theme.Ink(0.12), BorderThickness = new Thickness(0.5),
            Effect = new DropShadowEffect { BlurRadius = 4, ShadowDepth = 1, Direction = 270, Opacity = 0.12, Color = Colors.Black },
        };
        var x = new Path { Data = Geometry.Parse("M 7,7 L 13,13 M 13,7 L 7,13"), Stroke = Theme.Secondary, StrokeThickness = 1.6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Width = 20, Height = 20 };
        badge.Children.Add(circle);
        badge.Children.Add(x);
        badge.RenderTransform = badgeScale;
        badge.RenderTransformOrigin = new Point(0.5, 0.5);
        badge.MouseEnter += (_, _) => x.Stroke = Theme.Primary;
        badge.MouseLeave += (_, _) => { x.Stroke = Theme.Secondary; Motion.To(circle, OpacityProperty, 1, 0.08); };
        badge.MouseLeftButtonDown += (_, e) => { Motion.To(circle, OpacityProperty, 0.55, 0.08); e.Handled = true; };
        badge.MouseLeftButtonUp += (_, e) => { e.Handled = true; Dismiss(); };
    }

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

    /// On the card or its resize bands (the shadow margin around them is click-through).
    bool Contains(POINT p)
    {
        var r = CardRect();
        r.Inflate(8 * scale, 8 * scale);
        return r.Contains(new Point(p.X, p.Y));
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
        badge.Visibility = pinned ? Visibility.Visible : Visibility.Collapsed;
        if (pinned)
        {
            // Pinning keeps the card where it is and hangs it from its top-left corner.
            var tl = CardTopLeft();
            pinnedAt = tl;
            below = true; moved = true; edge = tl.Y; cardLeft = tl.X;
            SetFrame(shownHeight);
            Hover(hovered);
        }
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
