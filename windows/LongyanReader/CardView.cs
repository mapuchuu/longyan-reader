using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Longyan;

/// What the reader can do on a card; the window wires these to the core.
interface ICardActions
{
    void Pick(int token, int sense);
    void UseSuggested(int token);
    void ToggleAll(int token);
    void ToggleRow(int token);
    void OpenPartOf();
    void Copy(string text);
    void Listen(string text);
    void TogglePin();
    bool Pinned { get; }
    bool CanListen { get; }
}

/// The card's content, drawn from the core's JSON as the Mac card lays it out
/// (notes/card-spec.md). Rebuilt on every change; each part has a key, so a part that's new
/// fades in, changed text crossfades, and chevrons and checkmarks move from where they were.
sealed class CardView
{
    public readonly Grid Root = new();
    readonly StackPanel content = new();
    readonly StackPanel buttons = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
    readonly ICardActions actions;
    Dictionary<string, string> before = new(), now = new();
    bool animate;
    bool hovered;
    public double Width = 360;

    // The card's padding (16 at the sides and top, 12 below) and the actions' size.
    public const double Pad = 16, PadBottom = 12, ButtonW = 26, ButtonH = 22, ButtonGap = 2;

    public CardView(ICardActions actions)
    {
        this.actions = actions;
        content.Margin = new Thickness(Pad, Pad, Pad, PadBottom);
        Root.Children.Add(content);
        Root.Children.Add(buttons);
        Root.MouseEnter += (_, _) => { hovered = true; Recolor(); };
        Root.MouseLeave += (_, _) => { hovered = false; Recolor(); };
    }

    public void Show(JsonObject card, bool animate)
    {
        this.animate = animate && !Motion.Reduced;
        before = now; now = new();
        content.Children.Clear();
        buttons.Children.Clear();
        if ((string?)card["kind"] == "phrase") { Width = 390; Phrase(card); }
        else { Width = 360; Word(card); }
    }

    public void Hint(string message)
    {
        Width = 260;
        content.Children.Clear();
        buttons.Children.Clear();
        content.Children.Add(Label(message, 12, Theme.Secondary));
    }

    // MARK: Word card

    void Word(JsonObject c)
    {
        var syllables = c["pinyin"]?.AsArray() ?? new JsonArray();
        var word = (string?)c["word"] ?? "";
        var slot = Buttons((string?)c["copy"] ?? word, (string?)c["speech"] ?? word);

        // The top group, 4 apart: header, meaning, Part of, Back to, status.
        var top = new StackPanel();
        var header = Header(word, syllables, slot);
        top.Children.Add(header);
        PlaceButtons(header, 34, Theme.Chinese, FontWeights.Medium, 12);

        if ((string?)c["meaning"] is string meaning)
        {
            var block = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
            block.Children.Add(Keyed("meaning", Label(meaning, 19, Theme.Primary, FontWeights.SemiBold), meaning, crossfade: true));
            if ((bool?)c["contextual"] == true)
                block.Children.Add(Keyed("contextual", Label("Meaning in this sentence", 11, Theme.Secondary, top: 2)));
            top.Children.Add(Keyed("meaningBlock", block));
        }
        if (c["partOf"] is JsonObject part) top.Children.Add(PartOf(part));
        if ((string?)c["back"] is string back) top.Children.Add(Keyed("back", Back(back, -1)));
        if ((string?)c["status"] is string status)
            top.Children.Add(Keyed("status:" + status, status == "Reading the sentence…" ? Busy(status) : Label(status, 11, Theme.Secondary, top: 4)));
        content.Children.Add(top);

        if (c["note"] is JsonObject note)
            content.Children.Add(Keyed("note", Note(note, 12), (string?)note["text"] ?? "", slide: -4, crossfade: true));

        // Meanings, 8 apart: divider, label, rows, alternatives.
        var senses = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        senses.Children.Add(Divider());
        senses.Children.Add(Section("Meanings"));
        var rows = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        var all = c["senses"]?.AsArray() ?? new JsonArray();
        var total = Total(all, (string?)c["more"]);
        foreach (var node in all)
            if (node is JsonObject r) rows.Children.Add(SenseRow(r, 13, 5, total, "w", noteMarks: true, rows.Children.Count == 0, () => actions.Pick(-1, (int)r["index"]!)));
        if ((string?)c["more"] is string more) rows.Children.Add(More(more, 5, () => actions.ToggleAll(-1), "w"));
        senses.Children.Add(rows);
        var alternatives = c["alternatives"]?.AsArray().Select(x => (string?)x).Where(x => x != null).ToArray() ?? Array.Empty<string?>();
        if (alternatives.Length > 0) senses.Children.Add(Label("Other words here: " + string.Join(" · ", alternatives), 11, Theme.Tertiary, top: 8));
        content.Children.Add(senses);
    }

    /// Headword and pinyin on one baseline, 8 apart, with room for the buttons; on two lines
    /// when that doesn't fit.
    FrameworkElement Header(string word, JsonArray syllables, double slot)
    {
        var line = Lines(new TextBlock { TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(0, 0, slot + 8, 0) }, 34);
        AddHanzi(line.Inlines, word, syllables, 34, FontWeights.Medium, pending: false);
        line.Inlines.Add(new Run(" ") { FontFamily = Theme.Text, FontSize = 29 });   // 8 wide
        var pinyin = new Span();
        AddPinyin(pinyin.Inlines, syllables, 15, " ");
        line.Inlines.Add(pinyin);
        line.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        if (line.DesiredSize.Width <= Width - 2 * Pad) return line;

        var two = new StackPanel();
        var head = Lines(new TextBlock { TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(0, 0, slot + 8, 0) }, 34);
        AddHanzi(head.Inlines, word, syllables, 34, FontWeights.Medium, pending: false);
        two.Children.Add(new Viewbox { Child = head, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = Width - 2 * Pad });
        var py = Lines(new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) }, 15);
        AddPinyin(py.Inlines, syllables, 15, " ");
        two.Children.Add(py);
        return two;
    }

    FrameworkElement PartOf(JsonObject part)
    {
        var line = Lines(new TextBlock { FontSize = 12, FontFamily = Theme.Text, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis }, 13);
        line.Inlines.Add(new Run("Part of ") { Foreground = Theme.Secondary });
        line.Inlines.Add(new Run((string?)part["word"]) { FontWeight = FontWeights.Medium, FontSize = 13, Foreground = Theme.Primary, FontFamily = Theme.Chinese });
        line.Inlines.Add(new Run(" " + (string?)part["pinyin"]) { Foreground = Theme.Secondary });
        if ((string?)part["meaning"] is string m) line.Inlines.Add(new Run(" " + m) { Foreground = Theme.Primary });
        line.Inlines.Add(new Run(" "));
        line.Inlines.Add(new Run("") { FontFamily = Theme.Icons, FontSize = 8, Foreground = Theme.Tertiary, BaselineAlignment = BaselineAlignment.Center });
        var row = RowButton(line, bleed: 4, vertical: 2, () => actions.OpenPartOf(), hug: true);
        row.ToolTip = $"Look up {part["word"]}";
        row.Margin = new Thickness(0, 4, 0, 0);
        return row;
    }

    // MARK: Phrase card

    void Phrase(JsonObject c)
    {
        var text = (string?)c["text"] ?? "";
        var slot = Buttons((string?)c["copy"] ?? text, text);
        var top = new StackPanel();
        var source = Lines(new TextBlock
        {
            Text = text, FontSize = 14 * Theme.ChineseScale, FontFamily = Theme.Chinese, Foreground = Theme.Secondary, TextWrapping = TextWrapping.Wrap,
            MaxHeight = Math.Ceiling(14 * Theme.LineFactor) * 4, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, slot + 8, 0),
        }, 14);
        top.Children.Add(source);
        PlaceButtons(source, 14, Theme.Chinese, FontWeights.Normal, 5);
        if ((string?)c["translation"] is string t)
        {
            var tb = Label(t, 16, Theme.Primary, top: 4);
            Lines(tb, 16, 2);
            top.Children.Add(Keyed("translation", tb));
        }
        else if ((string?)c["translationError"] is string e) top.Children.Add(Keyed("translationError", Label(e, 11, Theme.Secondary, top: 4)));
        else top.Children.Add(Keyed("translating", Busy("Translating…", top: 4)));
        content.Children.Add(top);

        var rows = c["rows"]?.AsArray() ?? new JsonArray();
        if (rows.Count == 0) return;
        var words = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        words.Children.Add(Divider());
        words.Children.Add(Section("Words"));
        var list = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        // Every gloss starts at the same x: the widest word block's.
        var column = rows.OfType<JsonObject>().Select(r => WordBlock(r).Measure()).DefaultIfEmpty(0).Max();
        foreach (var node in rows)
        {
            if (node is not JsonObject r) continue;
            list.Children.Add(PhraseRow(r, column));
            if ((bool?)r["open"] == true) list.Children.Add(Keyed("detail:" + r["token"], Detail(r), slide: -6));
        }
        if ((string?)c["hidden"] is string hidden) list.Children.Add(Label(hidden, 11, Theme.Tertiary, top: 4, bottom: 4));
        words.Children.Add(list);
        content.Children.Add(words);
    }

    sealed class Block
    {
        public readonly StackPanel Panel = new();
        public double Measure() { Panel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); return Math.Ceiling(Panel.DesiredSize.Width); }
    }

    Block WordBlock(JsonObject r)
    {
        var pending = (bool?)r["pending"] == true;
        var syllables = r["pinyin"]?.AsArray() ?? new JsonArray();
        var b = new Block();
        var hanzi = Lines(new TextBlock(), 17);
        AddHanzi(hanzi.Inlines, (string?)r["text"] ?? "", syllables, 17, FontWeights.Medium, pending);
        b.Panel.Children.Add(hanzi);
        var py = Lines(new TextBlock { Margin = new Thickness(0, 1, 0, 0) }, 10.5);
        AddPinyin(py.Inlines, syllables, 10.5, " ");
        b.Panel.Children.Add(pending ? Redacted(py) : py);
        return b;
    }

    FrameworkElement PhraseRow(JsonObject r, double column)
    {
        var token = (int)r["token"]!;
        var pending = (bool?)r["pending"] == true;
        var open = (bool?)r["open"] == true;
        var opens = (bool?)r["opens"] == true;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(column) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var block = WordBlock(r).Panel;
        grid.Children.Add(block);

        var dim = (bool?)r["dim"] == true || (bool?)r["guess"] == true || pending;   // particles and guesses
        var glossText = (string?)r["gloss"] ?? "";
        var gloss = Label(glossText, 13, dim ? Theme.Secondary : Theme.Primary);
        gloss.Margin = new Thickness(0, Baseline(Theme.Chinese, 17, FontWeights.Medium) - Baseline(Theme.Text, 13, FontWeights.Normal), 0, 0);
        if (!open) { gloss.MaxHeight = gloss.LineHeight * 2 + 1; gloss.TextTrimming = TextTrimming.CharacterEllipsis; }
        FrameworkElement glossView = pending ? Redacted(gloss, 0.6) : Keyed("gloss:" + token, gloss, glossText, crossfade: true);
        Grid.SetColumn(glossView, 2);
        grid.Children.Add(glossView);

        if ((bool?)r["hasNote"] == true)
        {
            var mark = NoteMark();
            mark.VerticalAlignment = VerticalAlignment.Top;
            mark.Margin = new Thickness(12, gloss.Margin.Top + gloss.LineHeight / 2 - mark.Height / 2, 0, 0);
            Grid.SetColumn(mark, 3);
            grid.Children.Add(mark);
        }
        var chevron = Shape(ChevronRight, 10, 10, Theme.Tertiary, 1.4);
        chevron.VerticalAlignment = VerticalAlignment.Top;
        chevron.Margin = new Thickness(12, gloss.Margin.Top + gloss.LineHeight / 2 - 5, 0, 0);
        chevron.Opacity = opens || open ? 1 : 0;
        Rotate(chevron, "chevron:" + token, open ? 90 : 0);
        Grid.SetColumn(chevron, 4);
        grid.Children.Add(chevron);

        var row = RowButton(grid, bleed: 8, vertical: 5, opens || open ? () => actions.ToggleRow(token) : null);
        return row;
    }

    FrameworkElement Detail(JsonObject r)
    {
        var token = (int)r["token"]!;
        var d = new StackPanel { Margin = new Thickness(0, 2, 0, 8) };
        void Add(FrameworkElement e) { if (d.Children.Count > 0) e.Margin = new Thickness(e.Margin.Left, e.Margin.Top + 8, e.Margin.Right, e.Margin.Bottom); d.Children.Add(e); }
        if ((string?)r["status"] is string status)
            Add(Keyed($"dstatus:{token}:{status}", status == "Reading the sentence…" ? Busy(status) : Label(status, status == "Not in the dictionary" ? 12 : 11, Theme.Secondary)));
        if ((string?)r["here"] is string here)
        {
            var line = Lines(new TextBlock { FontSize = 12, FontFamily = Theme.Text, TextWrapping = TextWrapping.Wrap, Foreground = Theme.Primary }, 12);
            line.Inlines.Add(new Run("In this sentence: ") { Foreground = Theme.Secondary });
            line.Inlines.Add(new Run(here) { FontWeight = FontWeights.Medium });
            Add(Keyed("here:" + token, line));
        }
        if ((string?)r["back"] is string back) Add(Keyed("back:" + token, Back(back, token)));
        if (r["note"] is JsonObject note) Add(Keyed("dnote:" + token, Note(note, 0)));
        var senses = r["senses"]?.AsArray() ?? new JsonArray();
        if (senses.Count > 0)
        {
            var list = new StackPanel();
            var total = Total(senses, (string?)r["more"]);
            foreach (var node in senses)
                if (node is JsonObject s) list.Children.Add(SenseRow(s, 12, 3, total, "p" + token, noteMarks: false, list.Children.Count == 0, () => actions.Pick(token, (int)s["index"]!)));
            if ((string?)r["more"] is string more) list.Children.Add(More(more, 3, () => actions.ToggleAll(token), "p" + token));
            Add(list);
        }
        return d;
    }

    // MARK: Shared pieces

    /// How many meanings there are in all: "Show All 15" says, when some are hidden. The
    /// number column is as wide as the largest number's digits.
    static int Total(JsonArray rows, string? more)
    {
        var shown = rows.Count == 0 ? 1 : rows.Max(r => (int?)r?["number"] ?? 1);
        var digits = new string((more ?? "").Where(char.IsDigit).ToArray());
        return int.TryParse(digits, out var all) ? Math.Max(all, shown) : shown;
    }

    FrameworkElement SenseRow(JsonObject r, double size, double vertical, int total, string scope, bool noteMarks, bool first, Action pick)
    {
        var panel = new StackPanel();
        if ((string?)r["reading"] is string reading)
            panel.Children.Add(Label(reading, 11, Theme.Secondary, FontWeights.SemiBold, top: first ? 0 : 8, bottom: 1));
        var chosen = (bool?)r["chosen"] == true;
        var dim = (bool?)r["dimmed"] == true;
        var grid = new Grid();
        var digits = total.ToString(CultureInfo.InvariantCulture).Length;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(digits == 1 ? 9 : 8 * digits + 1) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var number = Label($"{r["number"]}", size - 1, Theme.Tertiary, FontWeights.Medium);
        number.TextAlignment = TextAlignment.Right;
        number.TextWrapping = TextWrapping.NoWrap;
        number.Margin = new Thickness(0, Baseline(Theme.Text, size, FontWeights.Normal) - Baseline(Theme.Text, size - 1, FontWeights.Medium), 0, 0);
        Typography.SetNumeralAlignment(number, FontNumeralAlignment.Tabular);
        grid.Children.Add(number);
        var line = Lines(new TextBlock { FontSize = size, FontFamily = Theme.Text, TextWrapping = TextWrapping.Wrap, Foreground = dim ? Theme.Secondary : Theme.Primary, ToolTip = (string?)r["tip"] }, size);
        if ((string?)r["pos"] is string pos) line.Inlines.Add(new Run(pos + " ") { FontStyle = FontStyles.Italic, Foreground = Theme.Secondary });
        line.Inlines.Add(new Run((string?)r["gloss"]) { FontWeight = chosen ? FontWeights.SemiBold : FontWeights.Normal });
        Grid.SetColumn(line, 2);
        grid.Children.Add(line);
        if (noteMarks && (bool?)r["hasNote"] == true)
        {
            var mark = NoteMark();
            mark.Margin = new Thickness(8, 0, 0, 0);
            mark.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(mark, 3);
            grid.Children.Add(mark);
        }
        var check = Shape(Checkmark, 14, 13, Theme.Accent, 1.7);
        var box = new Border { Width = 14, Margin = new Thickness(8, 0, 0, 0), Child = check, VerticalAlignment = VerticalAlignment.Center };
        Choice(check, $"check:{scope}:{r["index"]}", chosen);
        Grid.SetColumn(box, 4);
        grid.Children.Add(box);
        var row = RowButton(grid, bleed: 8, vertical: vertical, pick);
        row.ToolTip = noteMarks && (bool?)r["hasNote"] == true ? "Use this meaning · has a note" : "Use this meaning";
        panel.Children.Add(row);
        return panel;
    }

    FrameworkElement More(string text, double vertical, Action toggle, string scope)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(Label(text, 12, Theme.Accent, FontWeights.Medium));
        var chevron = Shape(ChevronDown, 10, 10, Theme.Accent, 1.4);
        chevron.Margin = new Thickness(4, 1, 0, 0);
        chevron.VerticalAlignment = VerticalAlignment.Center;
        Rotate(chevron, "more:" + scope, text == "Show Fewer" ? 180 : 0);
        line.Children.Add(chevron);
        return RowButton(line, bleed: 8, vertical: vertical, toggle);
    }

    FrameworkElement Back(string meaning, int token)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0), Background = Brushes.Transparent };
        var icon = Icon("", 11, Theme.Accent);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 1, 5, 0);
        line.Children.Add(icon);
        var label = Label($"Back to “{meaning}”", 12, Theme.Accent);
        label.TextWrapping = TextWrapping.NoWrap;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        line.Children.Add(label);
        line.MouseLeftButtonUp += (_, _) => actions.UseSuggested(token);
        return line;
    }

    FrameworkElement Note(JsonObject note, double top)
    {
        var lost = (string?)note["title"] == "Lost in translation";
        var box = new Border { Background = Theme.NoteFill, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, top, 0, 0) };
        var stack = new StackPanel();
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Icon(lost ? "" : "", 11, lost ? Theme.NoteLost : Theme.NoteCulture);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 1, 4, 0);
        title.Children.Add(icon);
        title.Children.Add(Label((string?)note["title"] ?? "", 11, Theme.Secondary, FontWeights.SemiBold));
        stack.Children.Add(title);
        var body = Label((string?)note["text"] ?? "", 13, Theme.Primary, top: 4);
        Lines(body, 13, 2);
        stack.Children.Add(body);
        box.Child = stack;
        return box;
    }

    FrameworkElement Busy(string text, double top = 4)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, top, 0, 0) };
        var spinner = Spinner();
        spinner.VerticalAlignment = VerticalAlignment.Center;
        spinner.Margin = new Thickness(0, 1, 8, 0);
        line.Children.Add(spinner);
        line.Children.Add(Label(text, 12, Theme.Secondary));
        return line;
    }

    /// The Mac's mini spinner: a 10 px ring with a gap, turning.
    static FrameworkElement Spinner()
    {
        var arc = new Path
        {
            Data = Geometry.Parse("M 5,0.75 A 4.25,4.25 0 1 1 0.75,5"),
            Stroke = Theme.Secondary, StrokeThickness = 1.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            Width = 10, Height = 10, RenderTransformOrigin = new Point(0.5, 0.5),
        };
        var spin = new RotateTransform();
        arc.RenderTransform = spin;
        spin.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(0.9))) { RepeatBehavior = RepeatBehavior.Forever });
        return arc;
    }

    static FrameworkElement Divider() => new Border { Height = 1, Background = Theme.Divider };
    static FrameworkElement Section(string title) => Label(title, 11, Theme.Secondary, FontWeights.SemiBold, top: 8);

    static FrameworkElement NoteMark() => Shape(Bubble, 13, 12, Theme.Tertiary, 1.1);

    // SF Symbols drawn as paths, so they sit exactly where they're put (icon fonts carry
    // their own spacing above and below).
    const string ChevronRight = "M 3.5,1.5 L 7,5 L 3.5,8.5";
    const string ChevronDown = "M 1.5,3.5 L 5,7 L 8.5,3.5";
    const string Checkmark = "M 1.5,7.2 L 5.2,10.8 L 12.5,2";
    const string Bubble = "M 2.5,1 H 10.5 A 1.8,1.8 0 0 1 12.3,2.8 V 7.4 A 1.8,1.8 0 0 1 10.5,9.2 H 6 L 3.4,11.2 V 9.2 H 2.5 A 1.8,1.8 0 0 1 0.7,7.4 V 2.8 A 1.8,1.8 0 0 1 2.5,1 Z M 3.6,4 H 9.4 M 3.6,6.2 H 7.6";

    static FrameworkElement Shape(string data, double width, double height, Brush color, double thickness) => new Path
    {
        Data = Geometry.Parse(data), Stroke = color, StrokeThickness = thickness, Width = width, Height = height,
        StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        RenderTransformOrigin = new Point(0.5, 0.5), SnapsToDevicePixels = false,
    };

    /// A full-width row that highlights like a macOS list row: 0.05 under the pointer, 0.09
    /// pressed, radius 6, reaching `bleed` past the text on both sides.
    FrameworkElement RowButton(FrameworkElement child, double bleed, double vertical, Action? click, bool hug = false)
    {
        var fill = new SolidColorBrush(((SolidColorBrush)Theme.Ink(1)).Color) { Opacity = 0 };
        var row = new Border
        {
            Child = child, Background = Brushes.Transparent, CornerRadius = new CornerRadius(6),
            Padding = new Thickness(bleed, vertical, bleed, vertical), Margin = new Thickness(-bleed, 0, -bleed, 0),
            HorizontalAlignment = hug ? HorizontalAlignment.Left : HorizontalAlignment.Stretch,
        };
        var highlight = new Border { CornerRadius = new CornerRadius(6), Background = fill, IsHitTestVisible = false };
        var host = new Grid();
        host.Children.Add(highlight);
        host.Children.Add(row);
        host.HorizontalAlignment = row.HorizontalAlignment;
        if (click == null) return host;
        var pressed = false;
        host.MouseEnter += (_, _) => Motion.To(fill, Brush.OpacityProperty, pressed ? 0.09 : 0.05, 0.08);
        host.MouseLeave += (_, _) => { pressed = false; Motion.To(fill, Brush.OpacityProperty, 0, 0.2); };
        host.MouseLeftButtonDown += (_, e) => { pressed = true; Motion.To(fill, Brush.OpacityProperty, 0.09, 0.08); e.Handled = true; };
        host.MouseLeftButtonUp += (_, e) =>
        {
            if (!pressed) return;
            pressed = false;
            Motion.To(fill, Brush.OpacityProperty, 0.05, 0.08);
            if (!CardWindow.WasDrag) click();
            e.Handled = true;
        };
        return host;
    }

    // MARK: Buttons

    readonly List<TextBlock> glyphs = new();

    /// The Listen, Copy and Pin buttons; returns the width their slot takes on the first line.
    double Buttons(string copy, string speech)
    {
        glyphs.Clear();
        var n = 0;
        if (actions.CanListen) { buttons.Children.Add(ActionButton("", $"Listen to “{speech}”", () => actions.Listen(speech))); n++; }
        buttons.Children.Add(CopyButton(copy)); n++;
        var pin = ActionButton(actions.Pinned ? "\uE842" : "\uE840", actions.Pinned ? "Unpin: close when you click elsewhere" : "Pin: keep the card here for every lookup",
            () => actions.TogglePin(), tint: actions.Pinned);
        pin.Child.RenderTransform = new RotateTransform(-45);   // Segoe's pin leans; the Mac's stands
        buttons.Children.Add(pin); n++;
        buttons.Margin = new Thickness(0, 0, Pad - 6, 0);
        return n * ButtonW + (n - 1) * ButtonGap - 6;
    }

    /// The buttons' centre sits `above` over the first line's baseline.
    void PlaceButtons(FrameworkElement firstLine, double size, FontFamily family, FontWeight weight, double above)
    {
        var top = Pad + Baseline(family, size, weight) - above - ButtonH / 2;
        buttons.Margin = new Thickness(0, Math.Max(0, top), buttons.Margin.Right, 0);
    }

    FrameworkElement CopyButton(string text)
    {
        Border? button = null;
        button = ActionButton("", $"Copy “{(text.Length > 14 ? text[..13] + "…" : text)}”", () =>
        {
            actions.Copy(text);
            var glyph = (TextBlock)button!.Child;
            glyph.Text = "";
            glyph.Foreground = Theme.Accent;
            button.ToolTip = "Copied";
            var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
            t.Tick += (_, _) => { t.Stop(); glyph.Text = ""; glyph.Foreground = hovered ? Theme.Secondary : Theme.Tertiary; button.ToolTip = $"Copy “{text}”"; };
            t.Start();
        });
        return button;
    }

    Border ActionButton(string glyph, string help, Action act, bool tint = false)
    {
        var symbol = Icon(glyph, 12, tint ? Theme.Accent : hovered ? Theme.Secondary : Theme.Tertiary);
        symbol.HorizontalAlignment = HorizontalAlignment.Center;
        symbol.VerticalAlignment = VerticalAlignment.Center;
        symbol.Tag = tint;
        if (!tint) glyphs.Add(symbol);
        var fill = new SolidColorBrush(((SolidColorBrush)Theme.Ink(1)).Color) { Opacity = 0 };
        var b = new Border { Width = ButtonW, Height = ButtonH, CornerRadius = new CornerRadius(6), Background = fill, Child = symbol, ToolTip = help, Margin = new Thickness(ButtonGap / 2, 0, ButtonGap / 2, 0) };
        b.MouseEnter += (_, _) => { Motion.To(fill, Brush.OpacityProperty, 0.07, 0.15); if (!tint) symbol.Foreground = Theme.Primary; };
        b.MouseLeave += (_, _) => { Motion.To(fill, Brush.OpacityProperty, 0, 0.15); b.Opacity = 1; if (!tint) symbol.Foreground = hovered ? Theme.Secondary : Theme.Tertiary; };
        b.MouseLeftButtonDown += (_, e) => { Motion.To(b, UIElement.OpacityProperty, 0.55, 0.08); e.Handled = true; };
        b.MouseLeftButtonUp += (_, e) => { Motion.To(b, UIElement.OpacityProperty, 1, 0.08); act(); e.Handled = true; };
        return b;
    }

    /// The buttons brighten while the pointer is anywhere on the card.
    void Recolor()
    {
        foreach (var g in glyphs) if (!g.IsMouseOver && g.Text != "") g.Foreground = hovered ? Theme.Secondary : Theme.Tertiary;
    }

    // MARK: Text

    static TextBlock Label(string text, double size, Brush color, FontWeight? weight = null, double top = 0, double bottom = 0) => Lines(new TextBlock
    {
        Text = text, FontSize = size, Foreground = color, FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, top, 0, bottom), FontFamily = Theme.Text,
    }, size);

    /// San Francisco's line height (about 1.2 of the size; Segoe's is 1.33), plus `extra`.
    static TextBlock Lines(TextBlock t, double size, double extra = 0)
    {
        t.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        t.LineHeight = Math.Ceiling(size * Theme.LineFactor) + extra;
        return t;
    }

    static TextBlock Icon(string glyph, double size, Brush color) => new()
    {
        Text = glyph, FontFamily = Theme.Icons, FontSize = size, Foreground = color, RenderTransformOrigin = new Point(0.5, 0.5),
    };

    static void AddHanzi(InlineCollection inlines, string word, JsonArray syllables, double size, FontWeight weight, bool pending)
    {
        var e = StringInfo.GetTextElementEnumerator(word);
        var i = 0;
        while (e.MoveNext())
        {
            var tone = i < syllables.Count ? (int?)syllables[i]?["tone"] ?? 5 : 5;
            inlines.Add(new Run((string)e.Current) { FontFamily = Theme.Chinese, FontSize = size * Theme.ChineseScale, FontWeight = Theme.ChineseWeight(weight), Foreground = pending ? Theme.Secondary : Theme.Hanzi(tone) });
            i++;
        }
    }

    static void AddPinyin(InlineCollection inlines, JsonArray syllables, double size, string gap)
    {
        for (var i = 0; i < syllables.Count; i++)
        {
            var s = syllables[i] as JsonObject;
            inlines.Add(new Run((i > 0 ? gap : "") + (string?)s?["text"]) { FontFamily = Theme.Text, FontSize = size, Foreground = Theme.PinyinColor((int?)s?["tone"] ?? 5) });
        }
    }

    /// Text drawn as a grey bar of its size, as SwiftUI's placeholder redaction does.
    static FrameworkElement Redacted(TextBlock text, double opacity = 1)
    {
        foreach (var run in text.Inlines.OfType<Run>()) run.Foreground = Brushes.Transparent;
        text.Foreground = Brushes.Transparent;
        return new Border { Background = Theme.Placeholder, CornerRadius = new CornerRadius(3), Child = text, HorizontalAlignment = HorizontalAlignment.Left, Opacity = opacity, Margin = text.Margin };
    }

    static readonly Dictionary<(string, double, int), double> baselines = new();

    /// How far below the top of a line its baseline sits, for lining up text of two sizes. Lines
    /// are `Lines` tall, and WPF keeps the font's own baseline-to-height ratio in them.
    public static double Baseline(FontFamily family, double size, FontWeight weight)
    {
        var key = (family.Source, size, weight.ToOpenTypeWeight());
        if (baselines.TryGetValue(key, out var b)) return b;
        var ft = new FormattedText(family == Theme.Chinese ? "国" : "Ag", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal), 100, Brushes.Black, 1.0);
        var ratio = ft.Baseline / ft.Height;
        return baselines[key] = Math.Ceiling(size * Theme.LineFactor) * ratio;
    }

    // MARK: Transitions

    /// Registers a part by key: new parts fade in (sliding from `slide` above), and with
    /// `crossfade`, a part whose value changed fades in again.
    T Keyed<T>(string key, T e, string value = "", double slide = 0, bool crossfade = false) where T : UIElement
    {
        now[key] = value;
        if (!animate) return e;
        if (!before.TryGetValue(key, out var old)) Motion.FadeIn(e, slide);
        else if (crossfade && old != value) Motion.FadeIn(e);
        return e;
    }

    /// A chevron at `angle`, turning from its last angle with cardMotion.
    void Rotate(UIElement e, string key, double angle)
    {
        var r = new RotateTransform(angle);
        e.RenderTransform = r;
        var was = before.TryGetValue(key, out var v) ? double.Parse(v, CultureInfo.InvariantCulture) : angle;
        now[key] = angle.ToString(CultureInfo.InvariantCulture);
        if (animate && was != angle) Motion.Animate(r, RotateTransform.AngleProperty, was, angle);
    }

    /// The checkmark: shown at full size when chosen, else hidden at 0.6 scale; animated.
    void Choice(UIElement e, string key, bool chosen)
    {
        var s = new ScaleTransform(chosen ? 1 : 0.6, chosen ? 1 : 0.6);
        e.RenderTransform = s;
        e.Opacity = chosen ? 1 : 0;
        var was = before.TryGetValue(key, out var v) ? v == "1" : chosen;
        now[key] = chosen ? "1" : "0";
        if (!animate || was == chosen) return;
        double a = chosen ? 0 : 1, b = chosen ? 1 : 0, sa = chosen ? 0.6 : 1, sb = chosen ? 1 : 0.6;
        Motion.Animate(e, UIElement.OpacityProperty, a, b);
        Motion.Animate(s, ScaleTransform.ScaleXProperty, sa, sb);
        Motion.Animate(s, ScaleTransform.ScaleYProperty, sa, sb);
    }
}
