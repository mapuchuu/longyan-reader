using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Longyan;

/// A row of the list: the entry with what each column shows.
sealed class HistoryRow
{
    public HistoryRow(HistoryEntry e) { Entry = e; }
    public HistoryEntry Entry { get; }
    public string Text => Entry.Text;
    public string Pinyin => Entry.Pinyin;
    public string Meaning => Entry.Meaning;
    public string? MeaningTip => (Entry.Gloss.Length > 0 ? Entry.Gloss : Entry.Meaning) is { Length: > 0 } t ? t : null;
    public string Sentence => Entry.IsWord ? Entry.Sentence : "";
    public string? SentenceTip => Sentence.Length > 0 ? Sentence : null;
    public string When => HistoryView.When(Entry.Date);
    // What a screen reader says for the row.
    public override string ToString() => string.Join(", ", new[] { Entry.Text, Entry.Pinyin, Entry.Meaning }.Where(s => s.Length > 0));
}

/// The History window's contents (the Mac's HistoryView): All, Words or Phrases, a search
/// box, Export and More options; the list, newest first; a count below. Windows 11's look,
/// light or dark as Windows is set.
sealed class HistoryView : Grid
{
    public readonly ResourceDictionary Look;
    readonly RadioButton all, words, phrases;
    readonly TextBox search;
    readonly Button export, more;
    readonly ListBox list;
    readonly Grid listArea = new();
    readonly StackPanel empty = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 380 };
    readonly TextBlock noMatch, count, offNote;
    readonly Grid dialog = new() { Visibility = Visibility.Collapsed };
    List<HistoryEntry> entries = new();
    bool loading = true, isOn = true;

    public Action? TurnOn, Clear;
    public Action<string>? SetKeep;
    public Action<IList<HistoryEntry>>? Delete;
    public Func<string> Keep = () => "all";

    public HistoryView(bool dark)
    {
        Look = (ResourceDictionary)System.Windows.Markup.XamlReader.Parse(Styles);
        Paint(dark);
        Resources.MergedDictionaries.Add(Look);
        SetResourceReference(BackgroundProperty, "WindowFill");
        TextElement.SetFontFamily(this, new FontFamily("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"));
        TextElement.SetFontSize(this, 14);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition());
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // The bar: kind, search, Export, More options.
        var bar = new DockPanel { Margin = new Thickness(16, 14, 16, 12), LastChildFill = true };
        var kinds = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 12, 0) };
        all = Tab("All", true); words = Tab("Words", false); phrases = Tab("Phrases", false);
        foreach (var t in new[] { all, words, phrases }) { kinds.Children.Add(t); t.Checked += (_, _) => Refresh(); }
        DockPanel.SetDock(kinds, Dock.Left);
        bar.Children.Add(kinds);
        more = new Button { Style = (Style)Look["Plain"], Width = 32, Padding = new Thickness(0), Margin = new Thickness(8, 0, 0, 0), ToolTip = "More options" };
        more.Content = Icon("", 16);
        System.Windows.Automation.AutomationProperties.SetName(more, "More options");
        more.Click += (_, _) => ShowMenu(more, MoreMenu());
        DockPanel.SetDock(more, Dock.Right);
        bar.Children.Add(more);
        var exportLabel = new StackPanel { Orientation = Orientation.Horizontal };
        exportLabel.Children.Add(new TextBlock { Text = "Export", VerticalAlignment = VerticalAlignment.Center });
        exportLabel.Children.Add(Icon("", 10, new Thickness(8, 1, 0, 0)));
        export = new Button { Style = (Style)Look["Plain"], Content = exportLabel, Margin = new Thickness(12, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(export, "Export");
        export.Click += (_, _) => ShowMenu(export, ExportMenu());
        DockPanel.SetDock(export, Dock.Right);
        bar.Children.Add(export);
        search = new TextBox { Style = (Style)Look["Search"], Tag = "Search Chinese, pinyin or English" };
        System.Windows.Automation.AutomationProperties.SetName(search, "Search");
        search.TextChanged += (_, _) => Refresh();
        bar.Children.Add(search);
        Children.Add(bar);

        // The list on its card, with the columns' names.
        var surface = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Margin = new Thickness(16, 0, 16, 0) };
        surface.SetResourceReference(Border.BackgroundProperty, "Surface");
        surface.SetResourceReference(Border.BorderBrushProperty, "Stroke");
        SetRow(surface, 1);
        var inside = new Grid();
        inside.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        inside.RowDefinitions.Add(new RowDefinition());
        var header = Columns();
        header.Margin = new Thickness(17, 10, 25, 8);
        var names = new[] { "Chinese", "Pinyin", "Meaning", "Sentence", "When" };
        for (var i = 0; i < names.Length; i++)
        {
            var h = new TextBlock { Text = names[i], FontSize = 12, FontWeight = FontWeights.SemiBold };
            h.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
            SetColumn(h, i);
            header.Children.Add(h);
        }
        inside.Children.Add(header);
        var line = new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom };
        line.SetResourceReference(Border.BackgroundProperty, "Stroke");
        inside.Children.Add(line);
        list = new ListBox
        {
            ItemTemplate = (DataTemplate)Look["Row"], ItemContainerStyle = (Style)Look["RowItem"],
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0, 4, 0, 4),
            SelectionMode = SelectionMode.Extended, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        System.Windows.Automation.AutomationProperties.SetName(list, "Lookups");
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetScrollUnit(list, ScrollUnit.Pixel);
        list.ContextMenu = RowMenu();
        list.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Delete) { DeleteSelected(); e.Handled = true; }
            else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control) { CopySelected(); e.Handled = true; }
        };
        listArea.Children.Add(list);
        noMatch = new TextBlock { Text = "No lookups match", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        noMatch.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        listArea.Children.Add(noMatch);
        SetRow(listArea, 1);
        inside.Children.Add(listArea);
        surface.Child = inside;
        Children.Add(surface);

        // Nothing yet, or history off.
        SetRow(empty, 1);
        Children.Add(empty);

        var footer = new DockPanel { Margin = new Thickness(18, 8, 18, 10) };
        count = new TextBlock { FontSize = 12 };
        count.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        offNote = new TextBlock { FontSize = 12, Text = "History is off; new lookups aren't added.", HorizontalAlignment = HorizontalAlignment.Right };
        offNote.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        DockPanel.SetDock(offNote, Dock.Right);
        footer.Children.Add(offNote);
        footer.Children.Add(count);
        SetRow(footer, 2);
        Children.Add(footer);

        SetRowSpan(dialog, 3);
        Children.Add(dialog);
        Refresh();
    }

    // MARK: State

    public void Show(List<HistoryEntry> e, bool on)
    {
        entries = e;
        isOn = on;
        loading = false;
        Refresh();
    }

    public void Loading(bool on) { isOn = on; loading = true; Refresh(); }

    public string Search { get => search.Text; set => search.Text = value; }
    public void FocusSearch() => search.Focus();

    IEnumerable<HistoryEntry> Shown
    {
        get
        {
            var q = search.Text.Trim().ToLowerInvariant();
            var kind = words.IsChecked == true ? "word" : phrases.IsChecked == true ? "phrase" : null;
            return entries.Where(e => (kind == null || e.Kind == kind)
                && (q.Length == 0 || new[] { e.Text, e.Meaning, e.Gloss, e.Sentence, e.Pinyin }.Any(s => s.ToLowerInvariant().Contains(q))));
        }
    }

    void Refresh()
    {
        if (list == null) return;   // still being built
        var shown = Shown.ToList();
        list.ItemsSource = shown.Select(e => new HistoryRow(e)).ToList();
        var nothing = entries.Count == 0 && !loading;
        empty.Visibility = nothing ? Visibility.Visible : Visibility.Collapsed;
        foreach (var c in Children.OfType<Border>()) c.Visibility = nothing ? Visibility.Collapsed : Visibility.Visible;
        if (nothing) Empty();
        noMatch.Visibility = !nothing && !loading && shown.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        count.Text = loading ? "Loading…" : shown.Count == entries.Count ? (shown.Count == 1 ? "1 lookup" : $"{shown.Count} lookups") : $"{shown.Count} of {entries.Count} lookups";
        count.Visibility = nothing ? Visibility.Collapsed : Visibility.Visible;
        offNote.Visibility = !isOn && !nothing ? Visibility.Visible : Visibility.Collapsed;
        export.IsEnabled = shown.Count > 0;
    }

    void Empty()
    {
        empty.Children.Clear();
        var title = new TextBlock { Text = isOn ? "No lookups yet" : "Lookup history is off", FontSize = 20, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        empty.Children.Add(title);
        var body = new TextBlock
        {
            Text = isOn ? "Words and phrases you look up appear here, with the meaning they had in their sentence."
                        : "Turn it on to keep the words and phrases you look up, on this PC only, and export them as flashcards.",
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 8, 0, 0),
        };
        body.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        empty.Children.Add(body);
        if (isOn) return;
        var on = new Button { Style = (Style)Look["Accent"], Content = "Turn on history", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 20, 0, 0) };
        on.Click += (_, _) => TurnOn?.Invoke();
        empty.Children.Add(on);
    }

    // MARK: Rows

    List<HistoryEntry> Picked() => list.SelectedItems.OfType<HistoryRow>().Select(r => r.Entry).ToList();

    void CopySelected()
    {
        var rows = Picked();
        if (rows.Count == 0) return;
        var text = string.Join("\r\n", rows.Select(e => string.Join("  ", new[] { e.Text, e.Pinyin, e.Meaning }.Where(s => s.Length > 0))));
        try { Clipboard.SetText(text); } catch (Exception e) { Diagnostics.Write("history: couldn't copy: " + e.GetType().Name); }
    }

    void DeleteSelected()
    {
        var rows = Picked();
        if (rows.Count > 0) Delete?.Invoke(rows);
    }

    ContextMenu RowMenu()
    {
        var menu = Menu();
        var copy = Item("Copy", CopySelected, "Ctrl+C");
        var delete = Item("Delete", DeleteSelected, "Delete");
        menu.Items.Add(copy);
        menu.Items.Add(delete);
        menu.Opened += (_, _) => { copy.IsEnabled = delete.IsEnabled = list.SelectedItems.Count > 0; };
        return menu;
    }

    ContextMenu ExportMenu()
    {
        var menu = Menu();
        menu.Items.Add(Item("Anki flashcards…", () => Export(anki: true)));
        menu.Items.Add(Item("Spreadsheet (CSV)…", () => Export(anki: false)));
        return menu;
    }

    ContextMenu MoreMenu()
    {
        var menu = Menu();
        var heading = new MenuItem { Header = "Keep history", IsEnabled = false };
        menu.Items.Add(heading);
        var keep = Keep();
        foreach (var (value, label) in new[] { ("off", "Off"), ("days30", "Keep 30 days"), ("all", "Keep everything") })
        {
            var item = Item(label, () => SetKeep?.Invoke(value));
            item.IsChecked = keep == value;
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator { Style = (Style)Look["Line"] });
        var folder = Item("Open history folder", OpenFolder);
        folder.IsEnabled = History.HasFile;
        menu.Items.Add(folder);
        var clear = Item("Clear history…", ConfirmClear);
        clear.IsEnabled = History.HasFile;
        menu.Items.Add(clear);
        return menu;
    }

    ContextMenu Menu()
    {
        var menu = new ContextMenu { Style = (Style)Look["Menu"], HasDropShadow = false };
        menu.Resources.MergedDictionaries.Add(Look);
        return menu;
    }

    MenuItem Item(string header, Action act, string? keys = null)
    {
        var item = new MenuItem { Header = header, InputGestureText = keys ?? "" };
        item.Click += (_, _) => act();
        return item;
    }

    static void ShowMenu(Button under, ContextMenu menu)
    {
        menu.PlacementTarget = under;
        menu.Placement = PlacementMode.Bottom;
        menu.VerticalOffset = 4;
        menu.IsOpen = true;
    }

    static void OpenFolder()
    {
        try { System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + History.FilePath + "\""); }
        catch (Exception e) { Diagnostics.Write("history: couldn't open the folder: " + e.GetType().Name); }
    }

    void Export(bool anki)
    {
        var rows = Shown.ToList();
        if (rows.Count == 0) return;
        var save = new SaveFileDialog
        {
            FileName = anki ? "Longyan Reader flashcards.txt" : "Longyan Reader history.csv",
            Filter = anki ? "Text files (*.txt)|*.txt" : "CSV files (*.csv)|*.csv",
            Title = anki ? "Export Anki flashcards (in Anki, choose File > Import and pick this file)" : "Export spreadsheet (one row per word and meaning)",
        };
        if (save.ShowDialog(Window.GetWindow(this)) != true) return;
        try { File.WriteAllText(save.FileName, anki ? HistoryExport.Anki(rows) : HistoryExport.Csv(rows), new UTF8Encoding(false)); }
        catch (Exception e) { MessageBox.Show(Window.GetWindow(this)!, "The file couldn't be saved: " + e.Message, "Lookup history", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    // MARK: Clear

    /// Asks first, in the window (as a Windows 11 dialog does).
    public void ConfirmClear()
    {
        dialog.Children.Clear();
        var smoke = new Border();
        smoke.SetResourceReference(Border.BackgroundProperty, "Smoke");
        dialog.Children.Add(smoke);
        var box = new Border { Width = 420, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        box.SetResourceReference(Border.BackgroundProperty, "DialogFill");
        box.SetResourceReference(Border.BorderBrushProperty, "Stroke");
        box.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 32, ShadowDepth = 8, Direction = 270, Opacity = 0.28 };
        var panel = new StackPanel();
        var top = new StackPanel { Margin = new Thickness(24, 24, 24, 24) };
        var title = new TextBlock { Text = "Clear lookup history?", FontSize = 20, FontWeight = FontWeights.SemiBold };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        top.Children.Add(title);
        var body = new TextBlock { Text = "The history file moves to the Recycle Bin, where you can still restore it.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0) };
        body.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        top.Children.Add(body);
        panel.Children.Add(top);
        var foot = new Border { Padding = new Thickness(24), CornerRadius = new CornerRadius(0, 0, 8, 8), BorderThickness = new Thickness(0, 1, 0, 0) };
        foot.SetResourceReference(Border.BackgroundProperty, "DialogFooter");
        foot.SetResourceReference(Border.BorderBrushProperty, "Stroke");
        var buttons = new UniformGrid { Columns = 2 };
        var yes = new Button { Style = (Style)Look["Accent"], Content = "Move to Recycle Bin", Margin = new Thickness(0, 0, 4, 0), IsDefault = true };
        var no = new Button { Style = (Style)Look["Plain"], Content = "Cancel", Margin = new Thickness(4, 0, 0, 0), IsCancel = true };
        yes.Click += (_, _) => { CloseDialog(); Clear?.Invoke(); };
        no.Click += (_, _) => CloseDialog();
        buttons.Children.Add(yes);
        buttons.Children.Add(no);
        foot.Child = buttons;
        panel.Children.Add(foot);
        box.Child = panel;
        dialog.Children.Add(box);
        dialog.Visibility = Visibility.Visible;
        yes.Focus();
    }

    void CloseDialog()
    {
        dialog.Visibility = Visibility.Collapsed;
        dialog.Children.Clear();
    }

    public bool DialogOpen => dialog.Visibility == Visibility.Visible;

    // MARK: Look

    static Grid Columns()
    {
        var g = new Grid();
        foreach (var w in new[] { 1.1, 1.0, 2.0, 2.6, 1.3 }) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w, GridUnitType.Star) });
        return g;
    }

    RadioButton Tab(string label, bool on)
    {
        var t = new RadioButton { Content = label, GroupName = "kind", IsChecked = on, Style = (Style)Look["Tab"] };
        return t;
    }

    static TextBlock Icon(string glyph, double size, Thickness? margin = null) => new()
    {
        Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = size,
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = margin ?? new Thickness(0),
    };

    /// The colours, Windows 11's for light or dark.
    public void Paint(bool dark)
    {
        void C(string key, uint argb) => Look[key] = Solid(argb);
        C("WindowFill", dark ? 0xFF202020 : 0xFFF3F3F3);
        C("Surface", dark ? 0xFF2B2B2B : 0xFFFBFBFB);
        C("Stroke", dark ? 0xFF383838 : 0xFFE5E5E5);
        C("Text", dark ? 0xFFFFFFFF : 0xFF1B1B1B);
        C("TextSecondary", dark ? 0xFFC9C9C9 : 0xFF5F5F5F);
        C("TextDisabled", dark ? 0xFF717171 : 0xFFA0A0A0);
        C("ControlFill", dark ? 0xFF2D2D2D : 0xFFFBFBFB);
        C("ControlHover", dark ? 0xFF323232 : 0xFFF6F6F6);
        C("ControlPressed", dark ? 0xFF272727 : 0xFFF3F3F3);
        C("ControlStroke", dark ? 0xFF3A3A3A : 0xFFE0E0E0);
        C("FieldFocused", dark ? 0xFF1F1F1F : 0xFFFFFFFF);
        C("Accent", dark ? 0xFF60CDFF : 0xFF005FB8);
        C("AccentHover", dark ? 0xFF5AB9E6 : 0xFF196EBF);
        C("TextOnAccent", dark ? 0xFF000000 : 0xFFFFFFFF);
        C("RowHover", dark ? 0x0FFFFFFF : 0x09000000);
        C("RowSelected", dark ? 0x15FFFFFF : 0x0F000000);
        C("Scroll", dark ? 0x8BFFFFFF : 0x72000000);
        C("MenuFill", dark ? 0xFF2C2C2C : 0xFFF9F9F9);
        C("MenuStroke", dark ? 0xFF404040 : 0xFFDDDDDD);
        C("Smoke", 0x4D000000);
        C("DialogFill", dark ? 0xFF2B2B2B : 0xFFFFFFFF);
        C("DialogFooter", dark ? 0xFF202020 : 0xFFF3F3F3);
    }

    static SolidColorBrush Solid(uint argb)
    {
        var b = new SolidColorBrush(Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb));
        b.Freeze();
        return b;
    }

    public static bool SystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    /// "Today 10:30", "Yesterday 18:05", else the date and time as Windows writes them.
    public static string When(DateTime utc)
    {
        var d = utc.ToLocalTime();
        var c = CultureInfo.CurrentCulture;
        var time = d.ToString("t", c);
        if (d.Date == DateTime.Today) return "Today " + time;
        if (d.Date == DateTime.Today.AddDays(-1)) return "Yesterday " + time;
        return d.ToString("d", c) + " " + time;
    }

    const string Styles = """
        <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
          <Style x:Key="Focus">
            <Setter Property="Control.Template"><Setter.Value><ControlTemplate>
              <Border BorderBrush="{DynamicResource Text}" BorderThickness="2" CornerRadius="6" Margin="-3"/>
            </ControlTemplate></Setter.Value></Setter>
          </Style>
          <Style x:Key="Plain" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="Background" Value="{DynamicResource ControlFill}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource ControlStroke}"/>
            <Setter Property="Padding" Value="12,0,12,0"/>
            <Setter Property="MinHeight" Value="32"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource Focus}"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="Button">
                <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4">
                  <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource ControlHover}"/></Trigger>
                  <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource ControlPressed}"/><Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/></Trigger>
                  <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource Plain}">
            <Setter Property="Foreground" Value="{DynamicResource TextOnAccent}"/>
            <Setter Property="Background" Value="{DynamicResource Accent}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="Button">
                <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4">
                  <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource AccentHover}"/></Trigger>
                  <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style x:Key="Tab" TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource Focus}"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="RadioButton">
                <Border x:Name="b" Background="Transparent" CornerRadius="4" Padding="12,0,12,0" MinHeight="32">
                  <Grid>
                    <TextBlock Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}" FontWeight="SemiBold" Visibility="Hidden" VerticalAlignment="Center"/>
                    <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
                    <Border x:Name="pill" Height="3" Width="16" CornerRadius="1.5" Background="{DynamicResource Accent}" VerticalAlignment="Bottom" Margin="0,0,0,1" Visibility="Hidden"/>
                  </Grid>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource RowHover}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/></Trigger>
                  <Trigger Property="IsChecked" Value="True"><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="FontWeight" Value="SemiBold"/><Setter TargetName="pill" Property="Visibility" Value="Visible"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style x:Key="Search" TargetType="TextBox">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
            <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="TextBox">
                <Border x:Name="b" Background="{DynamicResource ControlFill}" BorderBrush="{DynamicResource ControlStroke}" BorderThickness="1" CornerRadius="4" MinHeight="32">
                  <Grid>
                    <ScrollViewer x:Name="PART_ContentHost" Margin="10,0,36,0" VerticalAlignment="Center" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
                    <TextBlock x:Name="hint" Text="{TemplateBinding Tag}" Foreground="{DynamicResource TextSecondary}" Margin="12,0,36,0" VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="&#xE721;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" IsHitTestVisible="False"/>
                    <Border x:Name="line" Height="2" VerticalAlignment="Bottom" Background="{DynamicResource Accent}" CornerRadius="0,0,4,4" Visibility="Collapsed"/>
                  </Grid>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="Text" Value=""><Setter TargetName="hint" Property="Visibility" Value="Visible"/></Trigger>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource ControlHover}"/></Trigger>
                  <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource FieldFocused}"/><Setter TargetName="line" Property="Visibility" Value="Visible"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style x:Key="RowItem" TargetType="ListBoxItem">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="ListBoxItem">
                <Grid Margin="5,1,5,1" Background="Transparent">
                  <Border x:Name="b" Background="Transparent" CornerRadius="4"/>
                  <Border x:Name="pill" Width="3" Height="16" CornerRadius="1.5" Background="{DynamicResource Accent}" HorizontalAlignment="Left" Visibility="Collapsed"/>
                  <ContentPresenter Margin="12,0,12,0" VerticalAlignment="Center"/>
                </Grid>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource RowHover}"/></Trigger>
                  <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource RowSelected}"/><Setter TargetName="pill" Property="Visibility" Value="Visible"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <DataTemplate x:Key="Row">
            <Grid Height="40">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1*"/><ColumnDefinition Width="2*"/><ColumnDefinition Width="2.6*"/><ColumnDefinition Width="1.3*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="{Binding Text}" ToolTip="{Binding Text}" FontFamily="Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI" FontSize="15" Foreground="{DynamicResource Text}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <TextBlock Grid.Column="1" Text="{Binding Pinyin}" Foreground="{DynamicResource TextSecondary}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <TextBlock Grid.Column="2" Text="{Binding Meaning}" ToolTip="{Binding MeaningTip}" Foreground="{DynamicResource Text}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <TextBlock Grid.Column="3" Text="{Binding Sentence}" ToolTip="{Binding SentenceTip}" FontFamily="Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI" FontSize="13" Foreground="{DynamicResource TextSecondary}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <TextBlock Grid.Column="4" Text="{Binding When}" Foreground="{DynamicResource TextSecondary}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
            </Grid>
          </DataTemplate>
          <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="8"/>
            <Setter Property="MinWidth" Value="8"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
                  <Track.Thumb>
                    <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                      <Border Background="{DynamicResource Scroll}" CornerRadius="2" Width="4" HorizontalAlignment="Center"/>
                    </ControlTemplate></Thumb.Template></Thumb>
                  </Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style x:Key="Menu" TargetType="ContextMenu">
            <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="ContextMenu">
                <Border Background="{DynamicResource MenuFill}" BorderBrush="{DynamicResource MenuStroke}" BorderThickness="1" CornerRadius="8" Padding="4" Margin="0,0,12,12">
                  <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="3" Direction="270" Opacity="0.2"/></Border.Effect>
                  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                </Border>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style TargetType="MenuItem">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="MenuItem">
                <Border x:Name="b" Background="Transparent" CornerRadius="4" Padding="8,0,12,0" MinHeight="32" MinWidth="200">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="check" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Visibility="Hidden"/>
                    <ContentPresenter Grid.Column="1" ContentSource="Header" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                    <TextBlock Grid.Column="2" Text="{TemplateBinding InputGestureText}" Foreground="{DynamicResource TextSecondary}" FontSize="12" VerticalAlignment="Center" Margin="24,0,0,0"/>
                  </Grid>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsChecked" Value="True"><Setter TargetName="check" Property="Visibility" Value="Visible"/></Trigger>
                  <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource RowHover}"/></Trigger>
                  <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value></Setter>
          </Style>
          <Style x:Key="Line" TargetType="Separator">
            <Setter Property="Template"><Setter.Value>
              <ControlTemplate TargetType="Separator"><Border Height="1" Margin="-4,4,-4,4" Background="{DynamicResource MenuStroke}"/></ControlTemplate>
            </Setter.Value></Setter>
          </Style>
        </ResourceDictionary>
        """;
}

/// The History window (the Mac's "Lookup History"), from the tray. Reloads when brought forward
/// and after each change.
sealed class HistoryWindow : Window
{
    static HistoryWindow? shown;
    readonly HistoryView view;
    int loads;

    HistoryWindow()
    {
        Title = "Lookup history";
        Width = 920; Height = 520; MinWidth = 640; MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var icon = Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        if (File.Exists(icon)) try { Icon = BitmapFrame.Create(new Uri(icon)); } catch { }
        view = new HistoryView(HistoryView.SystemDark())
        {
            TurnOn = () => { History.Keep = "all"; Reload(); },
            SetKeep = keep => { History.Keep = keep; Reload(); },
            Clear = () => { History.Clear(); },
            Delete = entries => History.Delete(entries),
            Keep = () => History.Keep,
        };
        Content = view;
        SetResourceReference(BackgroundProperty, "WindowFill");
        Resources.MergedDictionaries.Add(view.Look);
        History.Changed += Reload;
        SystemEvents.UserPreferenceChanged += ThemeChanged;
        SourceInitialized += (_, _) => DarkTitleBar();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { view.FocusSearch(); e.Handled = true; }
            else if (e.Key == Key.Escape && !view.DialogOpen && view.Search.Length > 0) { view.Search = ""; e.Handled = true; }
        };
        Closed += (_, _) =>
        {
            History.Changed -= Reload;
            SystemEvents.UserPreferenceChanged -= ThemeChanged;
            shown = null;
        };
    }

    public static void Open()
    {
        try
        {
            if (shown != null)
            {
                shown.Reload();
                if (shown.WindowState == WindowState.Minimized) shown.WindowState = WindowState.Normal;
                shown.Activate();
                return;
            }
            shown = new HistoryWindow();
            shown.Reload();
            shown.Show();
            shown.Activate();
        }
        catch (Exception e) { Diagnostics.Write("history: couldn't open the window: " + Diagnostics.Describe(e)); }
    }

    /// Read off the main thread: a long history takes a while to parse.
    void Reload()
    {
        var load = ++loads;
        var on = History.IsOn;
        view.Loading(on);
        System.Threading.Tasks.Task.Run(() => { History.Trim(); return History.Entries(); }).ContinueWith(t =>
        {
            if (load != loads) return;   // a newer reload wins
            view.Show(t.IsCompletedSuccessfully ? t.Result : new List<HistoryEntry>(), on);
        }, System.Threading.Tasks.TaskScheduler.FromCurrentSynchronizationContext());
    }

    void ThemeChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category != UserPreferenceCategory.General) return;
        Dispatcher.BeginInvoke(() => { view.Paint(HistoryView.SystemDark()); DarkTitleBar(); });
    }

    void DarkTitleBar()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = HistoryView.SystemDark() ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref dark, sizeof(int));
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    // MARK: Drawings for CI

    /// --render-history OUT: the window's contents with made-up lookups, light and dark, and
    /// its empty, off, search and clear states. Never reads the real history.
    public static int Render(string output)
    {
        Directory.CreateDirectory(output);
        var sample = History.Read(SampleLines());
        foreach (var dark in new[] { false, true })
        {
            var suffix = dark ? "-dark" : "";
            Draw(Path.Combine(output, "history" + suffix + ".png"), dark, v => v.Show(sample, true));
            Draw(Path.Combine(output, "history-search" + suffix + ".png"), dark, v => { v.Show(sample, true); v.Search = "face"; });
            Draw(Path.Combine(output, "history-empty" + suffix + ".png"), dark, v => v.Show(new List<HistoryEntry>(), true));
            Draw(Path.Combine(output, "history-off" + suffix + ".png"), dark, v => v.Show(new List<HistoryEntry>(), false));
            Draw(Path.Combine(output, "history-off-kept" + suffix + ".png"), dark, v => v.Show(sample, false));
            Draw(Path.Combine(output, "history-clear" + suffix + ".png"), dark, v => { v.Show(sample, true); v.ConfirmClear(); });
        }
        Console.WriteLine($"history: {sample.Count} entries drawn");
        return 0;
    }

    static void Draw(string path, bool dark, Action<HistoryView> set)
    {
        var view = new HistoryView(dark);
        set(view);
        // In a window out of sight, so the list makes its rows as on screen.
        var w = new Window
        {
            WindowStyle = WindowStyle.None, ShowInTaskbar = false, ShowActivated = false, ResizeMode = ResizeMode.NoResize,
            Left = -30000, Top = -30000, Width = 920, Height = 520, Content = view,
        };
        w.Show();
        Settle();
        view.UpdateLayout();
        const double scale = 2;
        var bmp = new RenderTargetBitmap((int)(view.ActualWidth * scale), (int)(view.ActualHeight * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bmp.Render(view);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bmp));
        using (var f = File.Create(path)) png.Save(f);
        w.Close();
        Console.WriteLine(Path.GetFileName(path));
    }

    /// Runs the dispatcher until it's idle: bindings and layout done.
    static void Settle()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    /// Made-up lookups in the history file's format.
    static IEnumerable<string> SampleLines()
    {
        var now = DateTime.UtcNow;
        string At(double hoursAgo) => now.AddHours(-hoursAgo).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        string Word(double h, string w, string p, string m, string g, string s) =>
            new System.Text.Json.Nodes.JsonObject { ["at"] = At(h), ["event"] = "word", ["word"] = w, ["pinyin"] = p, ["meaningHere"] = m, ["gloss"] = g, ["sentence"] = s }.ToJsonString();
        string Phrase(double h, string t, string tr) =>
            new System.Text.Json.Nodes.JsonObject { ["at"] = At(h), ["event"] = "phrase", ["text"] = t, ["translation"] = tr }.ToJsonString();
        return new[]
        {
            Word(200, "铁饭碗", "tiě fàn wǎn", "secure job", "iron rice bowl; secure job", "他毕业后找了个铁饭碗。"),
            Word(120, "干杯", "gān bēi", "cheers", "to drink a toast; cheers!", "来，大家干杯！"),
            Phrase(60, "今天比较忙，明天再说吧。", "I'm fairly busy today, let's talk tomorrow."),
            Word(30, "内卷", "nèi juǎn", "rat race", "involution; rat race", "现在的学校太内卷了。"),
            Word(26, "面子", "miàn zi", "face", "face; reputation; prestige", "他很爱面子，不肯认错。"),
            Word(3, "研究", "yán jiū", "to look into", "research; to look into", "这件事我们研究研究再说。"),
            Word(1, "比较", "bǐ jiào", "fairly", "to compare; relatively; fairly", "今天比较忙。"),
            new System.Text.Json.Nodes.JsonObject { ["at"] = At(0.5), ["event"] = "pick", ["word"] = "比较", ["sentence"] = "今天比较忙。", ["meaning"] = "rather", ["pinyin"] = "bǐ jiào", ["gloss"] = "to compare; relatively; fairly" }.ToJsonString(),
            Word(0.2, "感冒", "gǎn mào", "to catch a cold", "to catch a cold; (common) cold", "他得了感冒，吃不了饭。"),
        };
    }
}
