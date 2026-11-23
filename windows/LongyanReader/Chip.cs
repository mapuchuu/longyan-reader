using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Windows.Automation;

namespace Longyan;

/// The eye: a small Longyan button by a fresh selection (Sources/LongyanReader/Chip.swift).
/// Clicking it opens the card; the next click, key press or scroll hides it. It never takes
/// the focus, so the app with the selection keeps it, and copying still works on a click.
static class Chip
{
    /// Called with the selection when it could be read, or null when the app doesn't say
    /// (then the click falls back to copying).
    public static Func<Selected?, Task>? Clicked;

    static ChipWindow? shown;
    static int generation;    // any press, key or scroll makes a read still under way stale

    public static void Start()
    {
        InputWatch.Down += (button, p, ours) =>
        {
            // The Mac watches the left and right buttons only.
            if (button == InputWatch.Button.Middle) return;
            generation++;
            if (shown == null) return;
            // Its own menu: a click elsewhere closes it (the menu can't see that click, as the
            // app is never in front), and the eye with it.
            if (shown.MenuOpen) { if (!ours) shown.CloseMenu(); return; }
            if (ours && shown.Contains(p)) return;
            Hide();
        };
        InputWatch.Wheel += () => { generation++; if (shown?.MenuOpen != true) Hide(); };
        InputWatch.Key += () =>
        {
            generation++;
            if (shown?.MenuOpen == true) shown.CloseMenu(); else Hide();
        };
        InputWatch.Up += MouseUp;
        Enable();
    }

    /// Watches the mouse only while the eye is on.
    public static void Enable()
    {
        InputWatch.Enable(Settings.ShowEye);
        if (!Settings.ShowEye) Hide();
    }

    static async void MouseUp(InputWatch.POINT up, int clicks, bool dragged, bool ours)
    {
        try { await Consider(up, clicks, dragged, ours); }
        catch (Exception e) { Core.Log($"{{\"event\":\"eye-error\",\"type\":\"{e.GetType().Name}\"}}"); }
    }

    static async Task Consider(InputWatch.POINT up, int clicks, bool dragged, bool ours)
    {
        // A plain click never selects text; nor does anything inside our own windows.
        if (ours || !Settings.ShowEye || !(dragged || clicks >= 2)) return;
        // Why no eye came, for UiCheck (only with the event log on).
        static void Skip(string why) => Core.Log($"{{\"event\":\"eye-skip\",\"why\":\"{why}\"}}");
        // Not over a full-screen game, video or presentation.
        if (SHQueryUserNotificationState(out var state) == 0 && state is QUNS_BUSY or QUNS_RUNNING_D3D_FULL_SCREEN or QUNS_PRESENTATION_MODE) { Skip("full screen"); return; }
        if (ForegroundApp.Get() is not ForegroundApp app || Settings.EyeHiddenIn(app.Process)) { Skip("app"); return; }
        var mine = ++generation;
        // Give the app a moment to update its selection.
        await Task.Delay(120);
        if (mine != generation) return;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var probed = await SelectionReader.ProbeAsync();
        if (mine != generation) return;
        if (Core.Logging) Core.Log($"{{\"event\":\"eye-probe\",\"found\":\"{probed.Found}\",\"ms\":{clock.ElapsedMilliseconds},\"dragged\":{(dragged ? "true" : "false")},\"clicks\":{clicks}}}");
        switch (probed.Found)
        {
            case SelectionReader.Found.Selection when probed.Selection is Selected selection:
                if (!SelectionReader.HasChinese(selection) || SelectionReader.Length(selection) > 400) { Skip("not Chinese or too long"); return; }
                // A position far from where the mouse let go isn't where the selection is.
                // Nor is an empty one (the Mac's SelectionReader.checked).
                var near = selection.Bounds is Rect b && b.Width >= 1 && b.Height >= 1 && Inflate(b, 160 * ScaleAt(up)).Contains(new Point(up.X, up.Y));
                Show(up, near ? selection : selection with { Bounds = null }, app);
                break;
            case SelectionReader.Found.Unreadable:
                // The app won't say what's selected: offer the eye and copy on a click. Only for a
                // double-click there (a drag in such apps often moves windows or files), only in a
                // focused element that may hold text and that the mouse is over (not the title
                // bar), and never where Ctrl+C isn't copy (terminals) or can't reach (apps run as
                // administrator), as the Mac skips lists, rows, buttons and windows.
                if (clicks < 2 || !app.MayBeText || !MayBeText(probed.Role)) return;
                if (probed.Area is Rect area && !area.Contains(new Point(up.X, up.Y))) return;
                Show(up, null, app);
                break;
        }
    }

    static void Show(InputWatch.POINT up, Selected? selection, ForegroundApp app)
    {
        Hide();
        Bridge.ly_warm_up();
        var w = new ChipWindow(selection, app.Process, app.Path);
        // One line: where its highlight ends and its text's ink is, as drawn (see Drawn).
        var drawn = selection is { Bounds: Rect sb, OneLine: true } ? SelectionReader.Drawn(sb, ScaleAt(up)) : (null, null);
        var (left, top, size) = w.Place(up, selection?.Bounds, selection?.OneLine ?? false, drawn.Right, drawn.InkMid);
        shown = w;
        // Positions only, in device pixels (UiCheck checks them): never the text.
        var bounds = selection?.Bounds is Rect b ? $"[{b.X:0.#},{b.Y:0.#},{b.Width:0.#},{b.Height:0.#}]" : "null";
        Core.Log($"{{\"event\":\"eye\",\"readable\":{(selection != null ? "true" : "false")},\"up\":[{up.X},{up.Y}],\"bounds\":{bounds},\"window\":[{left},{top},{size}],\"scale\":{ScaleAt(up):0.##},\"oneLine\":{((selection?.OneLine ?? false) ? "true" : "false")},\"drawn\":[{drawn.Right?.ToString("0.#") ?? "null"},{drawn.InkMid?.ToString("0.#") ?? "null"}]}}");
        // The card's work starts once the eye has stayed a moment (or on hover): most selections
        // are made to copy, and the model's work costs battery.
        DispatcherTimer? soon = null;
        soon = new DispatcherTimer(TimeSpan.FromSeconds(0.3), DispatcherPriority.Normal, (_, _) => { soon!.Stop(); Prepare(w); }, Dispatcher.CurrentDispatcher);
    }

    /// Starts the card's work for the eye's selection, once.
    internal static void Prepare(ChipWindow w)
    {
        if (shown != w || w.Prepared || w.Selection is not Selected s) return;
        w.Prepared = true;
        Core.Shared.Prepare(s.Passage, s.Start, s.End);
    }

    /// Gone without a click: the work started for it stops too.
    public static void Hide()
    {
        var w = shown;
        shown = null;
        if (w == null) return;
        if (w.Prepared) Core.Shared.CancelPrepare();
        w.Leave();
    }

    internal static void Click(ChipWindow w)
    {
        if (shown != w) return;
        shown = null;
        w.Leave();
        Core.Log("{\"event\":\"eye-click\"}");
        Open(w.Selection);
    }

    static async void Open(Selected? selection)
    {
        try { if (Clicked != null) await Clicked(selection); }
        catch (Exception e) { Core.Log($"{{\"event\":\"eye-click-error\",\"type\":\"{e.GetType().Name}\"}}"); }
    }

    internal static void Forget(ChipWindow w) { if (shown == w) shown = null; }

    static Rect Inflate(Rect r, double by) { r.Inflate(by, by); return r; }

    /// Kinds of element that hold things other than text (files, rows, controls): the Mac's
    /// notTextRoles. Unknown counts as text.
    static bool MayBeText(ControlType? role) => role == null || !(
        role == ControlType.List || role == ControlType.ListItem || role == ControlType.Tree || role == ControlType.TreeItem
        || role == ControlType.DataGrid || role == ControlType.DataItem || role == ControlType.Table || role == ControlType.Header
        || role == ControlType.HeaderItem || role == ControlType.Image || role == ControlType.Button || role == ControlType.SplitButton
        || role == ControlType.CheckBox || role == ControlType.RadioButton || role == ControlType.Slider || role == ControlType.ScrollBar
        || role == ControlType.Thumb || role == ControlType.ToolBar || role == ControlType.Menu || role == ControlType.MenuBar
        || role == ControlType.MenuItem || role == ControlType.ComboBox || role == ControlType.Tab || role == ControlType.TabItem
        || role == ControlType.Window || role == ControlType.TitleBar);

    internal static double ScaleAt(InputWatch.POINT p)
    {
        var monitor = MonitorFromPoint(p, 2);
        return monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out var x, out _) == 0 && x > 0 ? x / 96.0 : 1;
    }

    const int QUNS_BUSY = 2, QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4;
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(InputWatch.POINT p, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
}

/// The eye's window: 44 across so the hover growth and shadow fit, around a 30 hit area and a
/// 24 circle in the card's style (surface, 0.5 hairline, soft shadow) with the Longyan mark.
sealed class ChipWindow : Window
{
    const double Box = 44, Target = 30, Diameter = 24;
    /// The mark's frame is 13 on the Mac, its eye 12 wide on screen; 12.6 here drew it 11.5.
    const double Mark = 13;

    public readonly Selected? Selection;
    readonly string process, path;
    /// Whether the card's work was started for this eye (see Chip.Prepare).
    public bool Prepared;
    readonly ScaleTransform scale = new(0.6, 0.6, Target / 2, Target / 2);
    readonly Rectangle mark;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(6) };
    bool hovering, pressed, leaving, menuOpen;
    public bool MenuOpen => menuOpen;
    IntPtr hwnd;
    double s = 1;
    int left, top;

    static readonly ImageBrush markBrush = MakeMark();

    public ChipWindow(Selected? selection, string process, string path)
    {
        Selection = selection;
        this.process = process;
        this.path = path;
        Title = "Longyan eye";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Width = Height = Box;
        Opacity = 0;
        UseLayoutRounding = true;

        var (button, hit, markShape) = Build(snapshot: false);
        mark = markShape;
        button.RenderTransform = scale;
        button.Invoked = () => Chip.Click(this);
        Content = new Grid { Children = { button } };

        hit.MouseEnter += (_, _) => { Hover(true); Chip.Prepare(this); };
        hit.MouseLeave += (_, _) => Hover(false);
        hit.MouseLeftButtonDown += (_, e) => { pressed = true; hit.CaptureMouse(); Bounce(); e.Handled = true; };
        hit.MouseLeftButtonUp += (_, e) =>
        {
            if (!pressed) return;
            pressed = false;
            hit.ReleaseMouseCapture();
            Bounce();
            e.Handled = true;
            Chip.Click(this);
        };
        hit.MouseRightButtonUp += (_, e) => { e.Handled = true; Options(); };

        // Gone after 6 s, as on the Mac (its menu stops the clock).
        timer.Tick += (_, _) => { timer.Stop(); Chip.Hide(); };
        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };
    }

    /// The button: the hit area, and in it the circle (surface, hairline, shadow) and the mark.
    /// A snapshot (the gallery) leaves out the shadow, as the Mac's --render-chip does.
    static (EyeButton Button, Ellipse Hit, Rectangle Mark) Build(bool snapshot)
    {
        var surface = new Ellipse { Width = Diameter, Height = Diameter, Fill = Theme.Surface };
        // SwiftUI's .shadow(opacity 0.18, radius 5, y 2) has a longer tail than WPF's blur of the
        // same numbers: these match its pixels (RMS 0.6 of 255 at 2x, over white).
        if (!snapshot) surface.Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 2, Direction = 270, Opacity = 0.24, Color = Colors.Black, RenderingBias = RenderingBias.Quality };
        // A 0.5 border drawn inside the circle, as strokeBorder does.
        var hairline = new Ellipse { Width = Diameter, Height = Diameter, Stroke = Theme.Hairline, StrokeThickness = 0.5 };
        // SwiftUI puts the image on whole points: half a point right and down of centre.
        var mark = new Rectangle { Width = Mark, Height = Mark, Fill = Theme.Ink(1), OpacityMask = markBrush, Opacity = InkAlpha(false), RenderTransform = new TranslateTransform(0.5, 0.5) };
        RenderOptions.SetBitmapScalingMode(mark, BitmapScalingMode.HighQuality);
        // Not quite transparent: a layered window lets clicks through where it has no alpha.
        var hit = new Ellipse { Width = Target, Height = Target, Fill = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) };
        var button = new EyeButton
        {
            Width = Target, Height = Target,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Cursor = Cursors.Arrow,
        };
        button.Children.Add(surface);
        button.Children.Add(hairline);
        button.Children.Add(mark);
        button.Children.Add(hit);
        button.ToolTip = Shortcut.Registered ? $"Look up ({Shortcut.Name}). Right-click to hide the eye." : "Look up. Right-click to hide the eye.";
        ToolTipService.SetInitialShowDelay(button, 700);
        return (button, hit, mark);
    }

    /// Draws the eye at twice the size on the Mac renders' grey with 12 around it, as the Mac's
    /// --render-chip does (windows/gallery/mac/eye.png).
    public static void RenderToFile(string path)
    {
        var (button, _, _) = Build(snapshot: true);
        var backdrop = new Border { Background = Theme.Backdrop, Padding = new Thickness(12), Child = button };
        backdrop.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        backdrop.Arrange(new Rect(backdrop.DesiredSize));
        backdrop.UpdateLayout();
        var bmp = new RenderTargetBitmap((int)Math.Ceiling(backdrop.ActualWidth * 2), (int)Math.Ceiling(backdrop.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32);
        bmp.Render(backdrop);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bmp));
        using var f = System.IO.File.Create(path);
        png.Save(f);
    }

    /// Just after the end of a selection on one line (any height: a 32 px heading's line is over
    /// 40 points in Microsoft YaHei, under it in PingFang on the Mac) or under 40 points tall;
    /// for longer selections, or with no position, just above and right of where the mouse let
    /// go. Kept on that screen's working area.
    /// `right` and `inkMid`, when known, are the highlight's drawn right edge and the middle of
    /// the text's ink: the mark (half a point right and down of the circle's centre) goes 19.5
    /// after the highlight and level with the ink, as on the Mac.
    public (int Left, int Top, int Size) Place(InputWatch.POINT up, Rect? selection, bool oneLine = false, double? right = null, double? inkMid = null)
    {
        s = Chip.ScaleAt(up);
        double x = up.X + 6 * s, y = up.Y - 6 * s - Target * s;
        if (selection is Rect b && b.Height > 0 && (oneLine || b.Height < 40 * s))
        {
            x = (right ?? b.Right) + 4 * s;
            y = inkMid is double m ? m - 0.5 * s - Target * s / 2 : b.Top + b.Height / 2 - Target * s / 2;
        }
        var inset = (Box - Target) / 2 * s;
        x -= inset; y -= inset;
        var area = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(up.X, up.Y)).WorkingArea;
        var size = Box * s;
        left = (int)Math.Round(Math.Clamp(x, area.Left, area.Right - size));
        top = (int)Math.Round(Math.Clamp(y, area.Top, area.Bottom - size));

        hwnd = new WindowInteropHelper(this).EnsureHandle();
        SetWindowPos(hwnd, HWND_TOPMOST, left, top, (int)Math.Round(size), (int)Math.Round(size), SWP_NOACTIVATE);
        Show();
        SetWindowPos(hwnd, HWND_TOPMOST, left, top, (int)Math.Round(size), (int)Math.Round(size), SWP_NOACTIVATE);

        // A small spring in (response 0.3, damping 0.68) and a 0.12 s fade, as on the Mac.
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.12)));
        if (Motion.Reduced) scale.ScaleX = scale.ScaleY = 1;
        else ScaleTo(1, Motion.EyeAppear, Motion.EyeAppearSeconds);
        timer.Start();
        return (left, top, (int)Math.Round(size));
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        // Windows moves a window that changes screens; this one stays where it was put.
        if (hwnd != IntPtr.Zero) SetWindowPos(hwnd, HWND_TOPMOST, left, top, (int)Math.Round(Box * newDpi.DpiScaleX), (int)Math.Round(Box * newDpi.DpiScaleY), SWP_NOACTIVATE);
    }

    /// True when `p` (device pixels) is on the eye's window.
    public bool Contains(InputWatch.POINT p) => !leaving && p.X >= left && p.Y >= top && p.X < left + Box * s && p.Y < top + Box * s;

    /// Fades out over 0.1 s, clicked or not (Chip.swift hide()).
    public void Leave()
    {
        if (leaving) return;
        leaving = true;
        timer.Stop();
        Chip.Forget(this);
        var fade = new DoubleAnimation(0, TimeSpan.FromSeconds(0.1));
        fade.Completed += (_, _) => Close();
        BeginAnimation(OpacityProperty, fade);
    }

    void Hover(bool on)
    {
        hovering = on;
        Bounce();
        // The mark's colour changes in the same spring as the growth: SwiftUI's .animation(value:
        // hovering) covers both.
        if (Motion.Reduced) { mark.BeginAnimation(OpacityProperty, null); mark.Opacity = InkAlpha(on); return; }
        mark.BeginAnimation(OpacityProperty, new DoubleAnimation(InkAlpha(on), TimeSpan.FromSeconds(Motion.EyeHoverSeconds)) { EasingFunction = Motion.EyeHover });
    }

    /// 1.08 on hover, 0.92 pressed, springing between (Chip.swift:212).
    void Bounce()
    {
        if (leaving) return;
        if (Motion.Reduced) return;
        if (pressed) ScaleTo(0.92, Motion.EyePress, Motion.EyePressSeconds);
        else ScaleTo(hovering ? 1.08 : 1, Motion.EyeHover, Motion.EyeHoverSeconds);
    }

    void ScaleTo(double to, IEasingFunction ease, double seconds)
    {
        var a = new DoubleAnimation(to, TimeSpan.FromSeconds(seconds)) { EasingFunction = ease };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
    }

    /// Secondary at rest, primary on hover. The Mac's template image comes out a little
    /// stronger than its secondary text, so these are measured from its drawing.
    static double InkAlpha(bool hover) => hover ? 0.85 : Theme.Dark ? 0.575 : 0.52;

    /// Right-click: switch the eye off here or everywhere, without a trip to the tray. The
    /// system's own menu at the pointer, as the Mac's NSMenu is, so it has Windows 11's look.
    /// It never takes the focus (the eye can't), so a click or key elsewhere closes it (Chip.Start).
    void Options()
    {
        if (menuOpen || leaving) return;
        timer.Stop();
        menuOpen = true;
        var menu = CreatePopupMenu();
        string? name = null;
        if (process.Length > 0)
        {
            name = ForegroundApp.NameOf(path);
            AppendMenu(menu, MF_STRING, HideHere, $"Hide the eye in {name.Replace("&", "&&")}");
        }
        AppendMenu(menu, MF_STRING, TurnOff, "Turn off the eye");
        if (Shortcut.Registered)
        {
            AppendMenu(menu, MF_SEPARATOR, 0, null);
            AppendMenu(menu, MF_STRING | MF_GRAYED, 0, $"{Shortcut.Name} still looks up selected text");
        }
        GetCursorPos(out var at);
        var chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, at.X, at.Y, hwnd, IntPtr.Zero);
        DestroyMenu(menu);
        menuOpen = false;
        Core.Log($"{{\"event\":\"eye-menu\",\"chosen\":{chosen}}}");
        if (chosen == HideHere && name != null) { Settings.HideEyeIn(process, name); Program.MenuChanged(); }
        else if (chosen == TurnOff) { Settings.ShowEye = false; Program.MenuChanged(); }
        Chip.Hide();
    }

    public void CloseMenu() { if (menuOpen) EndMenu(); }

    static ImageBrush MakeMark()
    {
        var image = new BitmapImage();
        using var stream = typeof(ChipWindow).Assembly.GetManifestResourceStream("longyan-mark.png");
        image.BeginInit();
        image.StreamSource = stream;
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        var brush = new ImageBrush(image) { Stretch = Stretch.Uniform };
        brush.Freeze();
        return brush;
    }

    const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
    const int HideHere = 1, TurnOff = 2;
    const uint MF_STRING = 0, MF_GRAYED = 1, MF_SEPARATOR = 0x800, TPM_RIGHTBUTTON = 2, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100;
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(IntPtr menu, uint flags, nint id, string? text);
    [DllImport("user32.dll")] static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] static extern bool EndMenu();
    [DllImport("user32.dll")] static extern bool GetCursorPos(out InputWatch.POINT p);
    const uint SWP_NOACTIVATE = 0x10;
    static readonly IntPtr HWND_TOPMOST = new(-1);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}

/// The eye's button, which screen readers see as a "Look up" button they can press.
sealed class EyeButton : Grid
{
    public Action? Invoked;
    protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    sealed class Peer : System.Windows.Automation.Peers.FrameworkElementAutomationPeer, System.Windows.Automation.Provider.IInvokeProvider
    {
        public Peer(EyeButton owner) : base(owner) { }
        protected override System.Windows.Automation.Peers.AutomationControlType GetAutomationControlTypeCore() => System.Windows.Automation.Peers.AutomationControlType.Button;
        protected override string GetClassNameCore() => "LongyanEye";
        protected override string GetNameCore() => "Look up";
        protected override bool IsControlElementCore() => true;
        public override object? GetPattern(System.Windows.Automation.Peers.PatternInterface pattern) =>
            pattern == System.Windows.Automation.Peers.PatternInterface.Invoke ? this : base.GetPattern(pattern);
        public void Invoke() => ((EyeButton)Owner).Invoked?.Invoke();
    }
}
