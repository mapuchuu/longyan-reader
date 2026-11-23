using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;

namespace Longyan;

/// The first run's window, as the Mac's (Onboarding.swift) where it applies: what the app
/// does, the ways to look up (the eye, the shortcut as it is on this PC, pointing), where the
/// icon is, a line to try it on, the reading model's download, and Open at login (on unless
/// turned off here). Windows has no permission to ask for, so there's no Accessibility step.
/// Opens as soon as the app starts, before the dictionary has loaded; shown once. Mica behind
/// it on Windows 11, and it follows light and dark as they change.
sealed class WelcomeWindow : Window
{
    static WelcomeWindow? open;
    public const string Sample = "他得了感冒，吃不了饭。";

    Fluent look = Fluent.Now();
    WelcomePage page = null!;
    bool? openAtLogin;
    bool mica;

    public static bool IsOpen => open != null;

    /// The window closed (Done, the close button or Esc): the tray says where the app went.
    public static event Action? Finished;

    public static void Open()
    {
        Settings.WelcomeShown = true;
        open ??= new WelcomeWindow();
        open.Show();
        if (open.WindowState == WindowState.Minimized) open.WindowState = WindowState.Normal;
        open.Activate();
    }

    WelcomeWindow()
    {
        Title = "Welcome to Longyan Reader";
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Build();
        SourceInitialized += (_, _) =>
        {
            mica = Mica.Apply(this, look.Dark);
            Diagnostics.Write("welcome window: " + (mica ? "Mica" : "solid background"));
        };
        void Changed() => Dispatcher.BeginInvoke(page.RefreshModel);
        void ShortcutChanged() => Dispatcher.BeginInvoke(page.RefreshShortcut);
        ModelDownload.Changed += Changed;
        Shortcut.Changed += ShortcutChanged;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += ThemeMaybeChanged;
        // Esc closes the window, as Windows dialogs do, but not while a card is up: trying the
        // sample, Esc is for the card. The card leaves Esc in the app's own windows alone, so
        // it's closed from here.
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != System.Windows.Input.Key.Escape) return;
            e.Handled = true;
            var cards = Application.Current.Windows.OfType<CardWindow>().Where(w => w.IsVisible).ToList();
            if (cards.Count == 0) Close();
            else foreach (var c in cards) c.Dismiss();
        };
        Closed += (_, _) =>
        {
            ModelDownload.Changed -= Changed;
            Shortcut.Changed -= ShortcutChanged;
            Microsoft.Win32.SystemEvents.UserPreferenceChanged -= ThemeMaybeChanged;
            // The switch is a suggestion until the reader moves on, as on the Mac.
            if (LoginItem.Available && page.OpenAtLogin != LoginItem.IsEnabled) LoginItem.Set(page.OpenAtLogin);
            open = null;
            Finished?.Invoke();
        };
    }

    void Build()
    {
        look.Dress(this);
        if (page != null) openAtLogin = page.OpenAtLogin;
        page = new WelcomePage(look, preview: false, done: Close, openAtLogin: openAtLogin);
        Content = page.Root;
        if (mica) Mica.Apply(this, look.Dark);
    }

    /// Light or dark (or the accent) changed in Windows: draw the window again in it.
    void ThemeMaybeChanged(object? sender, Microsoft.Win32.UserPreferenceChangedEventArgs e)
    {
        Dispatcher.BeginInvoke(() =>
        {
            var now = Fluent.Now();
            if (now.Dark == look.Dark && now.Accent == look.Accent) return;
            look = now;
            Build();
        });
    }

    /// For the tray: the model changed (the core's model event).
    public static void Refresh() => open?.page.RefreshModel();

    /// --render-windows: the window in each state it can be in on a first run, light and dark.
    public static void RenderToFiles(string output)
    {
        var size = ModelDownload.Size;
        long At(double p) => (long)(p * size);
        var states = new (string Name, ModelView Model, string? Shortcut)[]
        {
            ("welcome", new ModelView("download the reading model to pick the meaning here", false, false, false, 0, null, null, 0), null),
            ("welcome-loading", new ModelView("", false, false, false, 0, null, null, 0), null),
            ("welcome-downloading", new ModelView("x", false, true, false, 0.43, "About 6 minutes left", null, At(0.43)), null),
            ("welcome-offline", new ModelView("x", false, true, false, 0.43, null, null, At(0.43), Waiting: true), null),
            ("welcome-checking", new ModelView("x", false, true, true, 1, null, null, size), null),
            ("welcome-stopped", new ModelView("x", false, false, false, 0.43, null, "stopped", At(0.43)), null),
            ("welcome-failed", new ModelView("x", false, false, false, 0.43, null, "couldn't reach huggingface.co", At(0.43)), null),
            ("welcome-no-space", new ModelView("x", false, false, false, 0, null, "there isn't enough disk space", 0, Space: "needs 3.7 GB free and the disk has 1.2 GB"), null),
            ("welcome-ready", new ModelView("ready", true, false, false, 0, null, null, size), null),
            ("welcome-too-slow", new ModelView("too-slow", false, false, false, 0, null, null, 0), null),
            ("welcome-altgr", new ModelView("ready", true, false, false, 0, null, null, size), "altgr"),
            ("welcome-taken", new ModelView("ready", true, false, false, 0, null, null, size), "taken"),
        };
        foreach (var dark in new[] { false, true })
        {
            var f = new Fluent(dark);
            var suffix = dark ? "-dark" : "";
            foreach (var (name, model, shortcut) in states)
            {
                var p = new WelcomePage(f, preview: true, done: () => { }, model: model, shortcutCase: shortcut);
                Fluent.RenderToFile(p.Root, f, 560, System.IO.Path.Combine(output, name + suffix + ".png"));
            }
        }
    }
}

sealed class WelcomePage
{
    public readonly DockPanel Root = new();
    readonly Fluent f;
    readonly bool preview;
    readonly ModelView? fixedModel;
    readonly string? shortcutCase;
    readonly ModelCard model;
    readonly TextBlock shortcutLine, shortcutNote, pointLine, tryHow;
    readonly Button choose;
    readonly FrameworkElement pointRow;
    readonly ToggleButton login;
    readonly Button doneButton;

    public bool OpenAtLogin => login.IsChecked == true;

    public WelcomePage(Fluent look, bool preview, Action done, ModelView? model = null, string? shortcutCase = null, bool? openAtLogin = null)
    {
        f = look;
        this.preview = preview;
        fixedModel = model;
        this.shortcutCase = shortcutCase;
        this.model = new ModelCard(f, welcome: true, preview);

        // Footer: Windows dialogs keep their buttons on a band along the bottom.
        var footer = new Grid();
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var loginLabel = f.Body("Open at login");
        loginLabel.VerticalAlignment = VerticalAlignment.Center;
        loginLabel.Margin = new Thickness(0, 0, 16, 0);
        footer.Children.Add(loginLabel);
        login = f.Switch("Open at login", "OpenAtLogin", openAtLogin ?? (preview || LoginItem.IsEnabled || LoginItem.Available));
        login.VerticalAlignment = VerticalAlignment.Center;
        login.Tag = "bare";
        Grid.SetColumn(login, 1);
        footer.Children.Add(login);
        if (!preview && !LoginItem.Available) { loginLabel.Visibility = Visibility.Collapsed; login.Visibility = Visibility.Collapsed; }
        // Esc is the window's own (WelcomeWindow), so it can leave a card to close. Which button
        // is the default follows the model (RefreshModel).
        doneButton = f.PushButton("Done", done, automationId: "Done");
        doneButton.MinWidth = 120;
        Grid.SetColumn(doneButton, 3);
        footer.Children.Add(doneButton);
        var band = new Border
        {
            Background = f.B(f.Footer), BorderBrush = f.B(f.Divider), BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(24, 20, 24, 20), Child = footer,
        };
        DockPanel.SetDock(band, Dock.Bottom);
        Root.Children.Add(band);

        var body = new StackPanel { Margin = new Thickness(24, 28, 24, 24) };
        var mark = f.Mark(40);
        mark.HorizontalAlignment = HorizontalAlignment.Left;
        mark.Margin = new Thickness(0, 0, 0, 16);
        body.Children.Add(mark);
        body.Children.Add(new TextBlock
        {
            Text = "Welcome to Longyan Reader", FontFamily = Fluent.DisplayFont, FontSize = 28, FontWeight = FontWeights.SemiBold,
            Foreground = f.B(f.Text), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8),
        });
        body.Children.Add(f.Body("Meanings, pinyin and translations for Chinese text in any app. It all runs on this PC."));

        // The ways to look up, each on its own line with its symbol.
        var ways = new StackPanel { Margin = new Thickness(0, 20, 0, 4) };
        ways.Children.Add(Way("", f.Body("Select Chinese text in any app, then click the eye that appears beside it.")));
        shortcutLine = f.Body("");
        shortcutNote = f.Caption("");
        choose = f.PushButton("Choose a shortcut", () => { if (!this.preview) ShortcutWindow.Open(); }, automationId: "ChooseShortcut");
        choose.Margin = new Thickness(0, 8, 0, 0);
        choose.HorizontalAlignment = HorizontalAlignment.Left;
        var shortcutStack = new StackPanel();
        shortcutStack.Children.Add(shortcutLine);
        shortcutStack.Children.Add(shortcutNote);
        shortcutStack.Children.Add(choose);
        ways.Children.Add(Way("", shortcutStack));
        pointLine = f.Body("");
        pointRow = Way("", pointLine);
        ways.Children.Add(pointRow);
        ways.Children.Add(Way("", f.Body("Longyan Reader runs from its icon in the notification area, by the clock. If you don't see it, click the arrow there.")));
        body.Children.Add(ways);

        // A line to try it on. The eye stays out of the app's own windows, so here it's the shortcut.
        var sample = new TextBox
        {
            Text = WelcomeWindow.Sample, IsReadOnly = true, IsReadOnlyCaretVisible = false,
            FontFamily = Fluent.ChineseFont, FontSize = 24, Background = Brushes.Transparent,
            Foreground = f.B(f.Text), BorderThickness = new Thickness(0), Padding = new Thickness(0), MinHeight = 0,
            Template = (ControlTemplate)XamlReader.Parse("""
                <ControlTemplate TargetType="TextBox" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
                  <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
                </ControlTemplate>
                """),
        };
        System.Windows.Automation.AutomationProperties.SetName(sample, "Sample sentence");
        System.Windows.Automation.AutomationProperties.SetAutomationId(sample, "Sample");
        tryHow = f.Caption("");
        var tryStack = new StackPanel();
        tryStack.Children.Add(f.Body("Try it"));
        tryStack.Children.Add(tryHow);
        sample.Margin = new Thickness(0, 12, 0, 2);
        tryStack.Children.Add(sample);
        var tryCard = f.CardFrame(tryStack, new Thickness(16, 14, 16, 14));
        tryCard.Margin = new Thickness(0, 12, 0, 4);
        body.Children.Add(tryCard);
        body.Children.Add(this.model.Root);
        Root.Children.Add(body);
        RefreshShortcut();
        RefreshModel();
    }

    FrameworkElement Way(string glyph, FrameworkElement words)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new TextBlock
        {
            Text = glyph, FontFamily = Theme.Icons, FontSize = 16, Foreground = f.B(f.AccentText), Width = 20,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 14, 0),
        });
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        return grid;
    }

    /// The shortcut as it is on this PC: the default, or Win+Ctrl+Y where Ctrl+Alt+L would type
    /// a letter (AltGr layouts, Shortcut.cs), or taken by another app.
    public void RefreshShortcut()
    {
        string name;
        bool works;
        string? why = null;
        if (preview)
        {
            name = shortcutCase == "altgr" ? "Win+Ctrl+Y" : Shortcut.Usual.Name;
            works = shortcutCase != "taken";
            if (shortcutCase == "altgr") why = "Ctrl+Alt+L types ł on the Polish (Poland) keyboard, so here it's Win+Ctrl+Y. You can change it in Settings.";
        }
        else
        {
            name = Shortcut.Name;
            works = Shortcut.Registered;
            if (Shortcut.Chosen == null && Shortcut.Current != Shortcut.Usual)
            {
                var layout = Shortcut.Layouts().FirstOrDefault(h => Shortcut.Types(Shortcut.Usual, h) != null);
                if (layout != IntPtr.Zero)
                    why = $"{Shortcut.Usual.Name} types {Shortcut.Types(Shortcut.Usual, layout)} on the {Shortcut.LayoutName(layout)} keyboard, so here it's {name}. You can change it in Settings.";
            }
        }
        shortcutLine.Text = works ? $"Or select it and press {name}." : $"{name} is used by another app, so there's no shortcut yet.";
        shortcutNote.Text = why ?? "";
        shortcutNote.Visibility = why == null ? Visibility.Collapsed : Visibility.Visible;
        choose.Visibility = works ? Visibility.Collapsed : Visibility.Visible;
        pointLine.Text = $"With nothing selected, {name} looks up the word under the pointer.";
        pointRow.Visibility = works ? Visibility.Visible : Visibility.Collapsed;
        tryHow.Text = works ? $"Select a word below, then press {name}." : "Choose a shortcut to try it here.";
    }

    /// While the model still needs downloading, Download is the default button, as on the Mac;
    /// after that, Done.
    public void RefreshModel()
    {
        model.Show(fixedModel ?? ModelView.Now());
        var download = model.WantsDownload;
        model.SetDefault(download);
        if (download) doneButton.ClearValue(FrameworkElement.StyleProperty);
        else doneButton.SetResourceReference(FrameworkElement.StyleProperty, "Accent");
        doneButton.IsDefault = !download;
    }
}

/// Windows 11's Mica behind a window: the frame extended over the whole window, the system
/// backdrop on, and WPF drawing on a clear background. Only on Windows 11 22H2 or later with
/// transparency effects on; elsewhere the window keeps its solid colour, which is Mica's own
/// fallback colour.
static class Mica
{
    public static bool Apply(Window w, bool dark)
    {
        try
        {
            if (Environment.OSVersion.Version.Build < 22621 || !TransparencyOn()) return false;
            var h = new WindowInteropHelper(w).Handle;
            if (h == IntPtr.Zero || HwndSource.FromHwnd(h) is not HwndSource source) return false;
            var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            if (DwmExtendFrameIntoClientArea(h, ref margins) != 0) return false;
            var backdrop = 2;   // DWMSBT_MAINWINDOW: Mica
            if (DwmSetWindowAttribute(h, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, 4) != 0) return false;
            var on = dark ? 1 : 0;
            DwmSetWindowAttribute(h, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, 4);
            // The caption follows the backdrop, not a colour.
            var none = unchecked((int)0xFFFFFFFF);
            DwmSetWindowAttribute(h, DWMWA_CAPTION_COLOR, ref none, 4);
            source.CompositionTarget.BackgroundColor = Colors.Transparent;
            w.Background = Brushes.Transparent;
            return true;
        }
        catch { return false; }
    }

    static bool TransparencyOn()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("EnableTransparency") is not int v || v != 0;
        }
        catch { return true; }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Margins { public int Left, Right, Top, Bottom; }

    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_CAPTION_COLOR = 35, DWMWA_SYSTEMBACKDROP_TYPE = 38;
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
