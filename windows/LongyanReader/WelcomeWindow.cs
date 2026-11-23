using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Markup;

namespace Longyan;

/// The first run's window: what the app does, how to use it with the shortcut as it is now,
/// a line to try it on, the reading model's download, and Open at login (on unless turned
/// off here, as the Mac offers it). Shown once.
sealed class WelcomeWindow : Window
{
    static WelcomeWindow? open;
    public const string Sample = "他得了感冒，吃不了饭。";

    readonly Fluent look = Fluent.Now();
    readonly WelcomePage page;

    public static bool IsOpen => open != null;

    public static void Open()
    {
        Settings.WelcomeShown = true;
        open ??= new WelcomeWindow();
        open.Show();
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
        look.Dress(this);
        page = new WelcomePage(look, preview: false, done: Close);
        Content = page.Root;
        void Changed() => Dispatcher.BeginInvoke(page.RefreshModel);
        void ShortcutChanged() => Dispatcher.BeginInvoke(page.RefreshShortcut);
        ModelDownload.Changed += Changed;
        Shortcut.Changed += ShortcutChanged;
        Closed += (_, _) =>
        {
            ModelDownload.Changed -= Changed;
            Shortcut.Changed -= ShortcutChanged;
            // The switch is a suggestion until the reader moves on.
            if (LoginItem.Available && page.OpenAtLogin != LoginItem.IsEnabled) LoginItem.Set(page.OpenAtLogin);
            open = null;
        };
    }

    /// For the tray: the model changed (the core's model event).
    public static void Refresh() => open?.page.RefreshModel();

    public static void RenderToFiles(string output)
    {
        foreach (var dark in new[] { false, true })
        {
            var f = new Fluent(dark);
            var suffix = dark ? "-dark" : "";
            var none = new ModelView("", false, false, false, 0, null, null, 0);
            Fluent.RenderToFile(new WelcomePage(f, preview: true, done: () => { }, model: none).Root, f, 560, System.IO.Path.Combine(output, "welcome" + suffix + ".png"));
            var downloading = new ModelView("", false, true, false, 0.43, "About 6 minutes left", null, 0);
            Fluent.RenderToFile(new WelcomePage(f, preview: true, done: () => { }, model: downloading).Root, f, 560, System.IO.Path.Combine(output, "welcome-downloading" + suffix + ".png"));
        }
    }
}

sealed class WelcomePage
{
    public readonly DockPanel Root = new();
    readonly Fluent f;
    readonly bool preview;
    readonly ModelView? fixedModel;
    readonly ModelCard model;
    readonly TextBlock how, tryHow;
    readonly ToggleButton login;

    public bool OpenAtLogin => login.IsChecked == true;

    public WelcomePage(Fluent look, bool preview, Action done, ModelView? model = null)
    {
        f = look;
        this.preview = preview;
        fixedModel = model;
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
        login = f.Switch("Open at login", "OpenAtLogin", preview || LoginItem.IsEnabled || LoginItem.Available);
        login.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(login, 1);
        footer.Children.Add(login);
        if (!preview && !LoginItem.Available) { loginLabel.Visibility = Visibility.Collapsed; login.Visibility = Visibility.Collapsed; }
        var doneButton = f.PushButton("Done", done, accent: true, automationId: "Done");
        doneButton.IsDefault = true;
        doneButton.IsCancel = true;
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
        how = f.Body("");
        how.Margin = new Thickness(0, 12, 0, 20);
        body.Children.Add(how);

        // A line to try it on. The eye stays out of the app's own windows, so here it's the shortcut.
        var sample = new TextBox
        {
            Text = WelcomeWindow.Sample, IsReadOnly = true, IsReadOnlyCaretVisible = false,
            FontFamily = Fluent.ChineseFont, FontSize = 24, Background = System.Windows.Media.Brushes.Transparent,
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
        var tryGrid = new Grid();
        tryGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tryGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        tryGrid.Children.Add(new TextBlock
        {
            Text = "\uE8D2", FontFamily = Theme.Icons, FontSize = 16, Foreground = f.B(f.Text), Width = 20,
            Margin = new Thickness(0, 2, 16, 0), VerticalAlignment = VerticalAlignment.Top,
        });
        Grid.SetColumn(tryStack, 1);
        tryGrid.Children.Add(tryStack);
        body.Children.Add(f.CardFrame(tryGrid, new Thickness(16, 14, 16, 14)));
        body.Children.Add(this.model.Root);
        Root.Children.Add(body);
        RefreshShortcut();
        RefreshModel();
    }

    public void RefreshShortcut()
    {
        var works = preview || Shortcut.Registered;
        how.Text = works
            ? $"Select Chinese text in any app, then click the eye that appears beside it, or press {Shortcut.Name}."
            : "Select Chinese text in any app, then click the eye that appears beside it.";
        tryHow.Text = works
            ? $"Select a word below, then press {Shortcut.Name}."
            : "Choose a keyboard shortcut in Settings to try it here.";
    }

    public void RefreshModel() => model.Show(fixedModel ?? ModelView.Now());
}
