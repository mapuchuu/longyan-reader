using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Longyan;

/// The card: a window over the other app that never takes the focus from it, drawn from the
/// core's JSON for one lookup. Closes on Escape, a click elsewhere or the close button.
sealed class CardWindow : Window
{
    static CardWindow? current;
    long cardID;
    readonly StackPanel content = new();
    readonly DispatcherTimer watch;
    bool placed;
    Rect? anchor;

    public static void Present(Selected selected)
    {
        current?.Close();
        current = new CardWindow(selected.Bounds);
        current.Open(selected);
    }

    public static void Hint(string message)
    {
        current?.Close();
        current = new CardWindow(null);
        current.ShowHint(message);
    }

    CardWindow(Rect? anchor)
    {
        this.anchor = anchor;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        SizeToContent = SizeToContent.Height;
        Width = 380;
        var border = new Border
        {
            Background = Theme.Card, BorderBrush = Theme.Edge, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 14, 16, 14),
            Child = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 560 },
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.25 },
            Margin = new Thickness(12),
        };
        Content = border;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };
        SizeChanged += (_, _) => Place();
        // The card never has the keyboard, so Escape and clicks elsewhere are watched for.
        watch = new DispatcherTimer(TimeSpan.FromMilliseconds(40), DispatcherPriority.Input, (_, _) => Watch(), Dispatcher);
        Closed += (_, _) =>
        {
            watch.Stop();
            if (cardID != 0) Core.Shared.Close(cardID);
            if (current == this) current = null;
        };
    }

    void Open(Selected s)
    {
        cardID = Core.Shared.Lookup(s.Passage, s.Start, s.End, Render, ShowHint);
    }

    void OpenPartOf()
    {
        var old = cardID;
        cardID = Core.Shared.OpenPartOf(old, Render, ShowHint);
        Core.Shared.Close(old);
    }

    void ShowHint(string message)
    {
        if (cardID != 0) { Core.Shared.Close(cardID); cardID = 0; }
        Width = 280;
        content.Children.Clear();
        content.Children.Add(Text(message, 12, Theme.Secondary));
        Reveal();
        // A hint goes by itself.
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        t.Tick += (_, _) => { t.Stop(); Close(); };
        t.Start();
    }

    void Reveal()
    {
        if (!IsVisible) { Show(); watch.Start(); }
    }

    // MARK: Drawing

    void Render(JsonObject card)
    {
        content.Children.Clear();
        if ((string?)card["kind"] == "phrase") { Width = 410; RenderPhrase(card); }
        else { Width = 380; RenderWord(card); }
        Reveal();
    }

    void RenderWord(JsonObject c)
    {
        var syllables = c["pinyin"]?.AsArray() ?? new JsonArray();
        var header = new DockPanel { LastChildFill = true };
        var tools = Tools((string?)c["copy"] ?? "");
        DockPanel.SetDock(tools, Dock.Right);
        header.Children.Add(tools);
        var heads = new StackPanel();
        heads.Children.Add(Hanzi((string?)c["word"] ?? "", syllables, 34));
        heads.Children.Add(Pinyin(syllables, 15));
        header.Children.Add(heads);
        content.Children.Add(header);

        if ((string?)c["meaning"] is string meaning)
        {
            content.Children.Add(Text(meaning, 19, Theme.Primary, FontWeights.SemiBold, top: 6));
            if ((bool?)c["contextual"] == true) content.Children.Add(Text("Meaning in this sentence", 11, Theme.Secondary));
        }
        if (c["partOf"] is JsonObject part)
        {
            var line = new TextBlock { FontSize = 12, Margin = new Thickness(0, 4, 0, 0), Cursor = Cursors.Hand, ToolTip = $"Look up {part["word"]}" };
            line.Inlines.Add(new Run("Part of ") { Foreground = Theme.Secondary });
            line.Inlines.Add(new Run((string?)part["word"]) { FontWeight = FontWeights.Medium, FontFamily = Theme.Chinese, FontSize = 13 });
            line.Inlines.Add(new Run(" " + (string?)part["pinyin"]) { Foreground = Theme.Secondary });
            if ((string?)part["meaning"] is string m) line.Inlines.Add(new Run("  " + m));
            line.Inlines.Add(new Run("  ›") { Foreground = Theme.Tertiary });
            line.MouseLeftButtonUp += (_, _) => OpenPartOf();
            content.Children.Add(line);
        }
        if ((string?)c["back"] is string back) content.Children.Add(Link($"↩ Back to “{back}”", () => Bridge.ly_use_suggested(cardID, -1)));
        if ((string?)c["status"] is string status) content.Children.Add(Text(status, 11, Theme.Secondary, top: 4));
        if (c["note"] is JsonObject note) content.Children.Add(Note(note));

        content.Children.Add(Divider());
        content.Children.Add(Section("Meanings"));
        foreach (var row in c["senses"]?.AsArray() ?? new JsonArray())
            if (row is JsonObject r) content.Children.Add(SenseRow(r, 13, () => Bridge.ly_pick(cardID, -1, (int)r["index"]!)));
        if ((string?)c["more"] is string more) content.Children.Add(Link(more + " ▾", () => Bridge.ly_toggle_all(cardID, -1)));
        var alternatives = c["alternatives"]?.AsArray().Select(x => (string?)x).ToArray() ?? Array.Empty<string?>();
        if (alternatives.Length > 0) content.Children.Add(Text("Other words here: " + string.Join(" · ", alternatives), 11, Theme.Secondary, top: 8));
    }

    void RenderPhrase(JsonObject c)
    {
        var header = new DockPanel();
        var tools = Tools((string?)c["copy"] ?? "");
        DockPanel.SetDock(tools, Dock.Right);
        header.Children.Add(tools);
        var source = Text((string?)c["text"] ?? "", 14, Theme.Secondary);
        source.FontFamily = Theme.Chinese;
        header.Children.Add(source);
        content.Children.Add(header);
        if ((string?)c["translation"] is string t) content.Children.Add(Text(t, 16, Theme.Primary, top: 4));
        else if ((string?)c["translationError"] is string e) content.Children.Add(Text(e, 11, Theme.Secondary, top: 4));
        else content.Children.Add(Text("Translating…", 12, Theme.Secondary, top: 4));

        var rows = c["rows"]?.AsArray() ?? new JsonArray();
        if (rows.Count == 0) return;
        content.Children.Add(Divider());
        content.Children.Add(Section("Words"));
        foreach (var node in rows)
        {
            if (node is not JsonObject r) continue;
            var token = (int)r["token"]!;
            var pending = (bool?)r["pending"] == true;
            var syllables = r["pinyin"]?.AsArray() ?? new JsonArray();
            var grid = new Grid { Margin = new Thickness(0, 4, 0, 4), Cursor = (bool?)r["opens"] == true ? Cursors.Hand : null };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var word = new StackPanel();
            word.Children.Add(Hanzi((string?)r["text"] ?? "", pending ? new JsonArray() : syllables, 17));
            if (!pending) word.Children.Add(Pinyin(syllables, 10.5));
            grid.Children.Add(word);
            var gloss = Text((string?)r["gloss"] ?? "", 13, pending || (bool?)r["guess"] == true ? Theme.Secondary : Theme.Primary);
            gloss.Opacity = pending ? 0.6 : 1;
            Grid.SetColumn(gloss, 1);
            grid.Children.Add(gloss);
            var open = (bool?)r["open"] == true;
            var mark = Text((bool?)r["opens"] == true ? (open ? "⌄" : "›") : "", 12, Theme.Tertiary);
            Grid.SetColumn(mark, 2);
            grid.Children.Add(mark);
            if ((bool?)r["opens"] == true || open) grid.MouseLeftButtonUp += (_, _) => Bridge.ly_toggle_row(cardID, token);
            content.Children.Add(grid);
            if (!open) continue;

            var detail = new StackPanel { Margin = new Thickness(110, 0, 0, 8) };
            if ((string?)r["status"] is string status) detail.Children.Add(Text(status, 11, Theme.Secondary));
            if ((string?)r["here"] is string here)
            {
                var line = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Theme.Primary };
                line.Inlines.Add(new Run("In this sentence: ") { Foreground = Theme.Secondary });
                line.Inlines.Add(new Run(here) { FontWeight = FontWeights.Medium });
                detail.Children.Add(line);
            }
            if ((string?)r["back"] is string back) detail.Children.Add(Link($"↩ Back to “{back}”", () => Bridge.ly_use_suggested(cardID, token)));
            if (r["note"] is JsonObject note) detail.Children.Add(Note(note));
            foreach (var s in r["senses"]?.AsArray() ?? new JsonArray())
                if (s is JsonObject sr) detail.Children.Add(SenseRow(sr, 12, () => Bridge.ly_pick(cardID, token, (int)sr["index"]!)));
            if ((string?)r["more"] is string more) detail.Children.Add(Link(more + " ▾", () => Bridge.ly_toggle_all(cardID, token)));
            content.Children.Add(detail);
        }
        if ((string?)c["hidden"] is string hidden) content.Children.Add(Text(hidden, 11, Theme.Tertiary, top: 4));
    }

    // MARK: Pieces

    static TextBlock Text(string text, double size, Brush color, FontWeight? weight = null, double top = 0) => new()
    {
        Text = text, FontSize = size, Foreground = color, FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, top, 0, 0), FontFamily = Theme.Latin,
    };

    static TextBlock Hanzi(string word, JsonArray syllables, double size)
    {
        var block = new TextBlock { FontSize = size, FontFamily = Theme.Chinese, FontWeight = FontWeights.Medium };
        var chars = System.Globalization.StringInfo.GetTextElementEnumerator(word);
        var i = 0;
        while (chars.MoveNext())
        {
            var tone = i < syllables.Count ? (int?)syllables[i]?["tone"] ?? 5 : 5;
            block.Inlines.Add(new Run((string)chars.Current) { Foreground = Theme.Hanzi(tone) });
            i++;
        }
        return block;
    }

    static TextBlock Pinyin(JsonArray syllables, double size)
    {
        var block = new TextBlock { FontSize = size, FontFamily = Theme.Latin };
        for (var i = 0; i < syllables.Count; i++)
        {
            var s = syllables[i] as JsonObject;
            block.Inlines.Add(new Run((i > 0 ? " " : "") + (string?)s?["text"]) { Foreground = Theme.PinyinColor((int?)s?["tone"] ?? 5) });
        }
        return block;
    }

    FrameworkElement SenseRow(JsonObject r, double size, Action pick)
    {
        var panel = new StackPanel();
        if ((string?)r["reading"] is string reading) panel.Children.Add(Text(reading, 11, Theme.Secondary, FontWeights.SemiBold, top: 6));
        var grid = new Grid { Cursor = Cursors.Hand, Margin = new Thickness(0, 3, 0, 3), ToolTip = (string?)r["tip"], Background = Brushes.Transparent };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var chosen = (bool?)r["chosen"] == true;
        var dim = (bool?)r["dimmed"] == true;
        grid.Children.Add(Text($"{r["number"]}", size - 1, Theme.Tertiary));
        var line = new TextBlock { FontSize = size, TextWrapping = TextWrapping.Wrap, FontFamily = Theme.Latin, Foreground = dim ? Theme.Secondary : Theme.Primary };
        if ((string?)r["pos"] is string pos) line.Inlines.Add(new Run(pos + " ") { FontStyle = FontStyles.Italic, Foreground = Theme.Secondary });
        line.Inlines.Add(new Run((string?)r["gloss"]) { FontWeight = chosen ? FontWeights.SemiBold : FontWeights.Normal });
        Grid.SetColumn(line, 1);
        grid.Children.Add(line);
        var mark = Text((chosen ? "✓" : "") + ((bool?)r["hasNote"] == true ? " •" : ""), size, Theme.Accent);
        Grid.SetColumn(mark, 2);
        grid.Children.Add(mark);
        grid.MouseLeftButtonUp += (_, _) => pick();
        panel.Children.Add(grid);
        return panel;
    }

    static FrameworkElement Note(JsonObject note)
    {
        var box = new Border { Background = Theme.NoteFill, CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 8, 0, 0) };
        var stack = new StackPanel();
        stack.Children.Add(Text((string?)note["title"] ?? "", 11, Theme.Secondary, FontWeights.SemiBold));
        stack.Children.Add(Text((string?)note["text"] ?? "", 12, Theme.Primary, top: 2));
        box.Child = stack;
        return box;
    }

    static FrameworkElement Divider() => new Border { Height = 1, Background = Theme.Edge, Margin = new Thickness(0, 12, 0, 8) };
    static FrameworkElement Section(string title) => Text(title.ToUpperInvariant(), 10, Theme.Tertiary, FontWeights.SemiBold);

    static TextBlock Link(string text, Action act)
    {
        var t = Text(text, 12, Theme.Accent, FontWeights.Medium, top: 4);
        t.Cursor = Cursors.Hand;
        t.MouseLeftButtonUp += (_, _) => act();
        return t;
    }

    FrameworkElement Tools(string copy)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        panel.Children.Add(Tool("⧉", "Copy", () => { try { Clipboard.SetText(copy); } catch { } }));
        panel.Children.Add(Tool("✕", "Close", Close));
        return panel;
    }

    static FrameworkElement Tool(string glyph, string tip, Action act)
    {
        var t = new TextBlock { Text = glyph, FontSize = 13, Foreground = Theme.Secondary, Margin = new Thickness(8, 0, 0, 0), Cursor = Cursors.Hand, ToolTip = tip };
        t.MouseLeftButtonUp += (_, _) => act();
        return t;
    }

    // MARK: Placement and closing

    /// Under the selection (or the pointer), kept on its screen; above when there's no room below.
    void Place()
    {
        var source = PresentationSource.FromVisual(this);
        if (source?.CompositionTarget == null) return;
        var toDip = source.CompositionTarget.TransformFromDevice;
        GetCursorPos(out var cursor);
        var a = anchor ?? new Rect(cursor.X - 10, cursor.Y - 10, 20, 20);
        var topLeft = toDip.Transform(new Point(a.Left, a.Bottom + 4));
        var above = toDip.Transform(new Point(a.Left, a.Top - 4));
        var area = SystemParameters.WorkArea;
        var left = Math.Max(area.Left, Math.Min(topLeft.X - 12, area.Right - ActualWidth));
        var top = topLeft.Y - 12;
        if (top + ActualHeight > area.Bottom) top = Math.Max(area.Top, above.Y - ActualHeight + 12);
        if (!placed || Math.Abs(Left - left) > 1) Left = left;
        if (!placed || top < Top || top + ActualHeight > area.Bottom) Top = top;
        placed = true;
    }

    void Watch()
    {
        if ((GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0) { Close(); return; }
        var click = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0 || (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
        if (click && !IsMouseOver) Close();
    }

    const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
    const int VK_ESCAPE = 0x1B, VK_LBUTTON = 0x01, VK_RBUTTON = 0x02;
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
}
