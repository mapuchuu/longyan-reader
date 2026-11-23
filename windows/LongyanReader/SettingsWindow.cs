using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;

namespace Longyan;

/// What the reading model's card shows: as it is now, or fixed for --render-windows.
sealed record ModelView(string Status, bool Downloaded, bool Running, bool Checking, double Progress, string? TimeLeft, string? Error, long OnDisk,
    bool Waiting = false, string? Space = null)
{
    public static ModelView Now() => new(Program.ModelStatus, ModelDownload.IsDownloaded, ModelDownload.Running, ModelDownload.Checking,
        ModelDownload.Progress, ModelDownload.TimeLeft, ModelDownload.LastError, ModelDownload.OnDisk,
        ModelDownload.WaitingForNetwork, ModelDownload.SpaceShort);
}

/// The reading model's card, in Settings and the welcome window: what state it's in, and
/// Download, Stop, Resume or Try again, worded as the Mac's welcome window words them.
/// Updated in place, so the button stays put while the download runs.
sealed class ModelCard
{
    public const string TooSlow = "This PC is too slow for the reading model. Cards use dictionary order.";
    const string What = "It picks the meaning each word has in its sentence and translates phrases.";

    public readonly Border Root;
    readonly Fluent f;
    readonly bool welcome;
    readonly StackPanel words = new();
    readonly Button button;
    readonly ProgressBar bar = new() { Minimum = 0, Maximum = 1, Margin = new Thickness(0, 10, 0, 4) };
    Action? act;

    public ModelCard(Fluent look, bool welcome, bool preview)
    {
        f = look;
        this.welcome = welcome;
        button = f.PushButton("", () => { if (!preview) act?.Invoke(); }, automationId: "ModelButton");
        System.Windows.Automation.AutomationProperties.SetAutomationId(words, "ModelStatus");
        var stack = new StackPanel();
        stack.Children.Add(f.Row(welcome ? null : "\uE8C1", "Reading model", words, button, minHeight: 48));
        bar.Margin = new Thickness(welcome ? 0 : 36, 10, 0, 4);
        System.Windows.Automation.AutomationProperties.SetName(bar, "Download progress");
        stack.Children.Add(bar);
        Root = f.CardFrame(stack);
    }

    public void Show(ModelView m)
    {
        var size = ModelDownload.Gigabytes(ModelDownload.Size);
        var lines = new List<string>();
        string? label = null;
        var enabled = true;
        act = null;
        // "1.2 of 2.7 GB", as the Mac shows it.
        string Of(double part) => $"{part * ModelDownload.Size / 1e9:0.0} of {ModelDownload.Size / 1e9:0.0} GB";
        if (m.Running && !m.Checking)
        {
            lines.Add(m.Waiting ? $"Waiting for the internet connection. {Of(m.Progress)} so far."
                : $"Downloading: {Of(m.Progress)}" + (m.TimeLeft != null ? " · " + m.TimeLeft : ""));
            label = "Stop"; act = ModelDownload.Stop;
        }
        else if (m.Checking) lines.Add("Checking the download…");
        else if (m.Status == "ready")
            lines.Add(welcome ? "Ready. " + What : $"Ready. {What} Uses {size} on this PC.");
        else if (m.Status == "too-slow") lines.Add(TooSlow);
        else if (m.Status == "needs-arm64") lines.Add("The reading model needs the ARM version of Longyan Reader. Cards use dictionary order.");
        else if (m.Status == "no-memory") lines.Add("There isn't enough free memory for the reading model now, so cards use dictionary order. It tries again in a minute.");
        else if (!m.Downloaded)
        {
            lines.Add($"Recommended. {What} It's a {size} download and runs on this PC.");
            if (m.Space is string space) lines.Add($"Not enough disk space. The download {space}.");
            else if (m.Error is string e && e != "stopped") lines.Add($"Download failed: {e.TrimEnd('.')}.");
            else if (m.OnDisk > 0) lines.Add($"{ModelDownload.Gigabytes(m.OnDisk)} is downloaded so far.");
            label = m.Space != null || (m.Error != null && m.Error != "stopped") ? "Try again" : m.OnDisk > 0 ? "Resume" : "Download";
            act = Program.GetModel;
            // Until the core has said whether this PC can run the model, so a PC too slow for
            // it isn't sent 2.7 GB.
            enabled = m.Status.Length > 0;
        }
        // Downloaded, and the core hasn't looked again yet (it says "unloadable" when it has).
        else if (m.Status != "unloadable" && m.Error == null) lines.Add("Loading…");
        else
        {
            lines.Add("It couldn't load, so cards list meanings in dictionary order.");
            if (!welcome) lines.Add($"Uses {ModelDownload.Gigabytes(m.OnDisk)} on this PC.");
            if (m.Error is string e && e != "stopped") lines.Add($"Download failed: {e.TrimEnd('.')}.");
            label = "Download again"; act = Program.GetModel;
        }
        words.Children.Clear();
        foreach (var l in lines) words.Children.Add(f.Caption(l));
        button.Visibility = label == null ? Visibility.Collapsed : Visibility.Visible;
        button.Content = label ?? "";
        button.IsEnabled = enabled;
        System.Windows.Automation.AutomationProperties.SetName(button, label ?? "");
        bar.Visibility = m.Running ? Visibility.Visible : Visibility.Collapsed;
        bar.Value = m.Checking ? 1 : m.Progress;
    }
}

/// Settings, from the tray (Settings…, or a double-click on the icon) and when the app is
/// opened again: Windows 11's settings page, with every change applied at once.
sealed class SettingsWindow : Window
{
    public enum Place { Top, Shortcut }
    static SettingsWindow? open;

    Fluent look = Fluent.Now();
    readonly ScrollViewer scroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    SettingsPage page = null!;

    public static void Open(Place at = Place.Top)
    {
        open ??= new SettingsWindow();
        open.Show();
        if (open.WindowState == WindowState.Minimized) open.WindowState = WindowState.Normal;
        open.Activate();
        if (at == Place.Shortcut) open.Dispatcher.BeginInvoke(() => open?.page.FocusShortcut(), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// The eye's settings or the model changed elsewhere (the eye's menu, the tray).
    public static void Refresh() => open?.page.Refresh();

    SettingsWindow()
    {
        Title = "Longyan Reader settings";
        Width = 720;
        Height = Math.Min(780, SystemParameters.WorkArea.Height - 60);
        MinWidth = 480;
        MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Content = scroller;
        Build();
        void ModelChanged() => page.RefreshModel();
        ModelDownload.Changed += ModelChanged;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += ThemeMaybeChanged;
        Closed += (_, _) =>
        {
            ModelDownload.Changed -= ModelChanged;
            Microsoft.Win32.SystemEvents.UserPreferenceChanged -= ThemeMaybeChanged;
            open = null;
        };
    }

    void Build()
    {
        look.Dress(this);
        var offset = scroller.VerticalOffset;
        page = new SettingsPage(look, preview: false);
        scroller.Content = page.Root;
        scroller.ScrollToVerticalOffset(offset);
    }

    /// Light or dark (or the accent) changed in Windows: draw the page again in it.
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

    /// Draws the page in light and dark for --render-windows.
    public static void RenderToFiles(string output)
    {
        foreach (var dark in new[] { false, true })
        {
            var f = new Fluent(dark);
            var suffix = dark ? "-dark" : "";
            var ready = new ModelView("ready", true, false, false, 0, null, null, ModelDownload.Size);
            Fluent.RenderToFile(new SettingsPage(f, preview: true, model: ready).Root, f, 720, System.IO.Path.Combine(output, "settings" + suffix + ".png"));
            var slow = new ModelView("too-slow", true, false, false, 0, null, null, ModelDownload.Size);
            Fluent.RenderToFile(new SettingsPage(f, preview: true, model: slow).Root, f, 720, System.IO.Path.Combine(output, "settings-too-slow" + suffix + ".png"));
            var downloading = new ModelView("", false, true, false, 0.43, "About 6 minutes left", null, 0);
            Fluent.RenderToFile(new SettingsPage(f, preview: true, model: downloading).Root, f, 720, System.IO.Path.Combine(output, "settings-downloading" + suffix + ".png"));
        }
    }
}

/// The settings page itself, apart from the window, so it can be drawn to a file.
sealed class SettingsPage
{
    public readonly StackPanel Root = new() { Margin = new Thickness(36, 24, 36, 36), MaxWidth = 1000 };
    readonly Fluent f;
    readonly bool preview;
    readonly ModelView? fixedModel;
    readonly ContentControl hiddenSlot = new() { Focusable = false };
    readonly ModelCard model;
    readonly ToggleButton eye;
    ToggleButton? updates;
    ShortcutPicker? picker;
    string shownEye = "";

    public SettingsPage(Fluent look, bool preview, ModelView? model = null)
    {
        f = look;
        this.preview = preview;
        fixedModel = model;
        this.model = new ModelCard(f, welcome: false, preview);
        eye = f.Switch("Show the eye", "ShowEye", preview || Settings.ShowEye);
        if (!preview)
        {
            eye.Checked += (_, _) => { if (!Settings.ShowEye) { Settings.ShowEye = true; Program.MenuChanged(); } };
            eye.Unchecked += (_, _) => { if (Settings.ShowEye) { Settings.ShowEye = false; Program.MenuChanged(); } };
        }

        Root.Children.Add(new TextBlock
        {
            Text = "Settings", FontFamily = Fluent.DisplayFont, FontSize = 28, FontWeight = FontWeights.SemiBold,
            Foreground = f.B(f.Text), Margin = new Thickness(0, 0, 0, 20),
        });

        Root.Children.Add(f.Heading("Looking up", first: true));
        picker = new ShortcutPicker(f, preview);
        var shortcut = f.Row("\uE765", "Keyboard shortcut", "Looks up the Chinese text you've selected. Click the box and press the keys you want.", picker, minHeight: 48);
        Root.Children.Add(f.CardFrame(shortcut));
        var eyeStack = new StackPanel();
        eyeStack.Children.Add(Padded(f.Row("\uE890", "Show the eye", "A button beside the Chinese text you select. Click it to look the text up.", eye)));
        eyeStack.Children.Add(hiddenSlot);
        Root.Children.Add(f.CardFrame(eyeStack, new Thickness(0)));

        Root.Children.Add(f.Heading("Reading model"));
        Root.Children.Add(this.model.Root);

        // History and Anki rows go here (win/history, win/anki).
        var cards = CardRows().ToList();
        if (cards.Count > 0)
        {
            Root.Children.Add(f.Heading("Cards"));
            foreach (var c in cards) Root.Children.Add(c);
        }

        Root.Children.Add(f.Heading("General"));
        var available = preview || LoginItem.Available;
        var login = f.Switch("Open at login", "OpenAtLogin", preview || LoginItem.IsEnabled);
        login.IsEnabled = available;
        if (!preview)
        {
            login.Checked += (_, _) => { if (!LoginItem.IsEnabled) LoginItem.Set(true); };
            login.Unchecked += (_, _) => { if (LoginItem.IsEnabled) LoginItem.Set(false); };
        }
        Root.Children.Add(f.CardFrame(f.Row("\uE7E8", "Open at login",
            available ? "Starts Longyan Reader when you sign in to Windows." : "Extract the zip to a folder first, then open Longyan Reader from there.", login)));
        if (preview || Updates.Available) Root.Children.Add(UpdatesCard());

        Root.Children.Add(f.Heading("About"));
        Root.Children.Add(About());
        Root.Children.Add(f.CardFrame(f.Row("\uED15", "Report a problem",
            "Opens a new issue on GitHub with details about this PC and the app's log. The log never holds the text you look up.",
            f.PushButton("Report", preview ? () => { } : Program.Report, automationId: "Report"))));

        Refresh();
    }

    /// Rows for the card's own settings, from other branches.
    IEnumerable<FrameworkElement> CardRows()
    {
        yield return HistorySettings.Card(f, preview);   // History
        yield return new AnkiCard(f, preview).Root;   // Add to Anki (AnkiSettings.cs)
    }

    public void FocusShortcut()
    {
        picker?.BringIntoView();
        picker?.FocusField();
    }

    public void Refresh()
    {
        RefreshEye();
        RefreshModel();
        // WinSparkle's own question (on the second launch) also turns checking on or off.
        if (updates != null && !preview && updates.IsChecked != Updates.Automatic) updates.IsChecked = Updates.Automatic;
    }

    /// Updates: automatic checks (once a day, as on the Mac) and Check now.
    Border UpdatesCard()
    {
        updates = f.Switch("Check for updates automatically", "AutoUpdates", preview || Updates.Automatic);
        if (!preview)
        {
            updates.Checked += (_, _) => { if (!Updates.Automatic) Updates.Automatic = true; };
            updates.Unchecked += (_, _) => { if (Updates.Automatic) Updates.Automatic = false; };
        }
        var stack = new StackPanel();
        stack.Children.Add(Padded(f.Row("\uE895", "Check for updates automatically", "Looks for a new version once a day.", updates)));
        stack.Children.Add(f.Line());
        var now = f.PushButton("Check now", preview ? () => { } : Updates.CheckNow, automationId: "CheckForUpdates");
        stack.Children.Add(Padded(f.Row(null, "Check for updates", null, now, minHeight: 32), indent: true, tight: true));
        return f.CardFrame(stack, new Thickness(0));
    }

    public void RefreshModel() => model.Show(fixedModel ?? ModelView.Now());

    /// The eye's switch, and under it the apps it's hidden in (as in a Windows 11 expander).
    /// Only what changed is drawn again, so the switch keeps the keyboard focus.
    void RefreshEye()
    {
        var showEye = preview || Settings.ShowEye;
        IReadOnlyList<(string Process, string Name)> hidden = preview
            ? new[] { ("wechat", "WeChat"), ("code", "Visual Studio Code") }
            : Settings.EyeHiddenApps;
        if (eye.IsChecked != showEye) eye.IsChecked = showEye;
        var state = showEye + "|" + string.Join("|", hidden.Select(a => a.Process));
        if (state == shownEye) return;
        shownEye = state;
        var stack = new StackPanel();
        if (showEye)
        {
            stack.Children.Add(f.Line());
            if (hidden.Count == 0)
                stack.Children.Add(Padded(f.Row(null, "Hidden in no apps", "To hide the eye in an app, right-click the eye there.", null), indent: true));
            else
            {
                stack.Children.Add(Padded(f.Row(null, "Hidden in", "Apps you hid the eye in, from its right-click menu.", null), indent: true));
                foreach (var (process, name) in hidden)
                {
                    stack.Children.Add(f.Line());
                    var remove = f.PushButton("Remove", preview ? () => { } : () => { Settings.ShowEyeIn(process); Program.MenuChanged(); });
                    System.Windows.Automation.AutomationProperties.SetName(remove, "Show the eye in " + name);
                    stack.Children.Add(Padded(f.Row(null, name, null, remove, minHeight: 32), indent: true, tight: true));
                }
            }
        }
        hiddenSlot.Content = stack;
    }

    static Border Padded(UIElement row, bool indent = false, bool tight = false) => new()
    {
        Padding = new Thickness(indent ? 52 : 16, tight ? 8 : 12, 16, tight ? 8 : 12), Child = row,
    };

    Border About()
    {
        var stack = new StackPanel();
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var mark = f.Mark(20);
        mark.Margin = new Thickness(0, 0, 16, 0);
        mark.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(mark);
        var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(f.Body("Longyan Reader"));
        name.Children.Add(f.Caption("Version " + Diagnostics.Version.Split('+')[0]));
        Grid.SetColumn(name, 1);
        head.Children.Add(name);
        stack.Children.Add(Padded(head));
        stack.Children.Add(f.Line());

        var links = new TextBlock { FontSize = 14, TextWrapping = TextWrapping.Wrap };
        links.Inlines.Add(new Run("Free and open source, under the MIT License.") { Foreground = f.B(f.Text) });
        links.Inlines.Add(new LineBreak());
        AddLink(links, "longyan.app", "https://longyan.app");
        links.Inlines.Add(new Run("   "));
        AddLink(links, "Source code on GitHub", "https://github.com/mapuchuu/longyan-reader");
        links.Inlines.Add(new Run("   "));
        AddLink(links, "Privacy", "https://longyan.app/privacy.html");
        stack.Children.Add(Padded(links, indent: true));
        stack.Children.Add(f.Line());

        var credits = new StackPanel();
        credits.Children.Add(f.Caption("Dictionary: CC-CEDICT, © MDBG and contributors, under CC BY-SA 4.0, with senses reordered, words added and notes attached."));
        credits.Children.Add(f.Caption("Reading model: Qwen 3.5 (Apache 2.0), run with llama.cpp (MIT). Its meanings and translations can be wrong."));
        credits.Children.Add(f.Caption("The notes were written by Claude and checked against the dictionary meanings they belong to. They can contain mistakes."));
        foreach (TextBlock t in credits.Children) t.Margin = new Thickness(0, 0, 0, 4);
        stack.Children.Add(Padded(credits, indent: true));
        return f.CardFrame(stack, new Thickness(0));
    }

    void AddLink(TextBlock into, string text, string url)
    {
        var link = new Hyperlink(new Run(text)) { NavigateUri = new Uri(url) };
        link.RequestNavigate += (_, e) =>
        {
            if (preview) return;
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); }
            catch (Exception x) { Diagnostics.Write("couldn't open the browser: " + x.Message); }
        };
        into.Inlines.Add(link);
    }
}
