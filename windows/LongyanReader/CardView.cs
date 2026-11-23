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
    /// The content, scaled by the zoom and scrolled; and the buttons, which do neither and sit
    /// over it in the card's top-right corner.
    public readonly Grid Root = new();
    public readonly StackPanel Buttons = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
    readonly StackPanel content = new();
    StackPanel buttons => Buttons;
    /// The text size; the content is drawn at 1 and scaled by the window.
    public double Zoom = 1;
    /// A width the reader set by dragging an edge (content units), for phrase (true) or word cards.
    public Func<bool, double?>? WidthFor;
    public const double WordWidth = 360, PhraseWidth = 390, HintWidth = 260;
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
        Root.Children.Add(ghosts);
    }

    /// Copies of parts that left or changed, fading out where they were.
    readonly Canvas ghosts = new() { IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };

    /// The pointer came onto the card or left it: the buttons brighten or dim.
    public void SetHovered(bool on) { hovered = on; Recolor(); }

    public void Show(JsonObject card, bool animate)
    {
        this.animate = animate;
        var was = animate ? Positions() : null;
        var old = animate ? Snapshot() : null;
        if (!animate) ghosts.Children.Clear();
        tracked.Clear();
        before = now; now = new();
        builtAt = Environment.TickCount64;
        content.Children.Clear();
        buttons.Children.Clear();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        if ((string?)card["kind"] == "phrase") { Width = WidthFor?.Invoke(true) ?? PhraseWidth; Phrase(card); }
        else { Width = WidthFor?.Invoke(false) ?? WordWidth; Word(card); }
        var built = clock.Elapsed.TotalMilliseconds;
        if (was != null) Slide(was);
        var slid = clock.Elapsed.TotalMilliseconds;
        if (old != null) FadeOut(old);
        Timing = $"\"build\":{built:0.0},\"layout\":{slid - built:0.0},\"fade\":{clock.Elapsed.TotalMilliseconds - slid:0.0}";
    }

    /// How long the last Show took, in parts, for the UI check's log.
    public string Timing = "";

    /// When the content was last rebuilt: the part under the pointer then is already hovered,
    /// so it takes its highlight at once rather than fading in again.
    long builtAt;
    bool JustBuilt => Environment.TickCount64 - builtAt < 200;

    public void Hint(string message)
    {
        Width = HintWidth;
        content.Children.Clear();
        buttons.Children.Clear();
        ghosts.Children.Clear();
        content.Children.Add(Label(message, 12, Theme.Secondary));
    }

    // MARK: Word card

    void Word(JsonObject c)
    {
        var syllables = c["pinyin"]?.AsArray() ?? new JsonArray();
        var word = (string?)c["word"] ?? "";
        var slot = AddButtons((string?)c["copy"] ?? word, (string?)c["speech"] ?? word);

        // The top group, 4 apart: header, meaning, Part of, Back to, status.
        var top = new StackPanel();
        var header = Header(word, syllables, slot);
        top.Children.Add(Keyed("header", header, string.Join(" ", syllables.Select(x => (string?)x?["text"])), crossfade: true));
        PlaceButtons(header, 34, Theme.Chinese, FontWeights.Medium, 12);

        if ((string?)c["meaning"] is string meaning)
        {
            var block = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
            var meaningLine = Label(meaning, 19, Theme.Primary, FontWeights.SemiBold);
            meaningLine.Margin = new Thickness(0, -HeaderLift, 0, HeaderLift);   // Segoe sits low in the line too
            block.Children.Add(Keyed("meaning", meaningLine, meaning, crossfade: true));
            if ((bool?)c["contextual"] == true)
                block.Children.Add(Keyed("contextual", Label("Meaning in this sentence", 11, Theme.Secondary, top: 2)));
            top.Children.Add(Keyed("meaningBlock", block));
        }
        if (c["partOf"] is JsonObject part) top.Children.Add(Keyed("partOf", PartOf(part), (string?)part["word"] + "|" + (string?)part["meaning"], crossfade: true));
        if ((string?)c["back"] is string back) top.Children.Add(Keyed("back", Back(back, -1, top: 4)));
        if ((string?)c["status"] is string status)
            top.Children.Add(Keyed("status:" + status, status == "Reading the sentence…" ? Busy(status) : Label(status, 11, Theme.Secondary, top: 4)));
        content.Children.Add(Track("top", top));

        if (c["note"] is JsonObject note)
            content.Children.Add(Keyed("note", Note(note, 12), (string?)note["text"] ?? "", slide: -4, crossfade: true));

        // Meanings, 8 apart: divider, label, rows, alternatives.
        var senses = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        senses.Children.Add(Divider());
        senses.Children.Add(Section("Meanings"));
        var rows = new StackPanel { Margin = new Thickness(0, 9, 0, 0) };   // the spec's 8, plus 1 to line up with the Mac
        var all = c["senses"]?.AsArray() ?? new JsonArray();
        var total = Total(all, (string?)c["more"]);
        foreach (var node in all)
            if (node is JsonObject r) rows.Children.Add(Track($"row:w:{r["index"]}", SenseRow(r, 13, 5, total, "w", noteMarks: true, rows.Children.Count == 0, () => actions.Pick(-1, (int)r["index"]!))));
        if ((string?)c["more"] is string more) rows.Children.Add(Track("more:w", More(more, 5, () => actions.ToggleAll(-1), "w")));
        senses.Children.Add(rows);
        var alternatives = c["alternatives"]?.AsArray().Select(x => (string?)x).Where(x => x != null).ToArray() ?? Array.Empty<string?>();
        if (alternatives.Length > 0) senses.Children.Add(Track("alternatives", Label("Other words here: " + string.Join(" · ", alternatives), 11, Theme.Tertiary, top: 8)));
        content.Children.Add(Track("senses", senses));
    }

    /// Headword and pinyin on one baseline, 8 apart, with room for the buttons; on two lines
    /// when that doesn't fit.
    FrameworkElement Header(string word, JsonArray syllables, double slot)
    {
        // YaHei sits 1.5 lower in the line than PingFang: the header moves up by that, keeping
        // its height, so the meaning below lines up too.
        var line = Lines(new TextBlock { TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(0, -HeaderLift, slot + 8, HeaderLift) }, 34);
        AddHanzi(line.Inlines, word, syllables, 34, FontWeights.Medium, pending: false);
        line.Inlines.Add(new Run(" ") { FontFamily = Theme.Text, FontSize = 29 });   // 8 wide
        var pinyin = new Span();
        AddPinyin(pinyin.Inlines, syllables, 15, " ");
        line.Inlines.Add(pinyin);
        // Whether it fits is worked out with the Mac's widths, so it breaks where the Mac's does:
        // PingFang's characters are a full em wide (YaHei's, drawn smaller, aren't), and the Mac
        // keeps 8 between the word, the pinyin, a spacer at least 8 wide, and the buttons.
        var characters = new StringInfo(word).LengthInTextElements;
        var pinyinWidth = syllables.Select((x, i) => TextWidth((i > 0 ? " " : "") + (string?)x?["text"], Theme.Text, Theme.Latin(15))).Sum();
        if (characters * 34 + pinyinWidth + 4 * 8 + slot <= Width - 2 * Pad) return line;

        // Too long for one line: the word on a row as tall as a full-size one, shrunk to fit (to
        // half size at most, then cut short), and the pinyin under it.
        var two = new StackPanel { Margin = new Thickness(0, -HeaderLift, 0, HeaderLift) };
        var head = Lines(new TextBlock { TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom }, 34);
        AddHanzi(head.Inlines, word, syllables, 34, FontWeights.Medium, pending: false);
        // Shrunk as much as the Mac shrinks its word, which it measures at a full em a character.
        var room = Width - 2 * Pad - slot - 8;
        var scale = Math.Clamp(room / Math.Max(1, characters * 34), 0.5, 1);
        head.LayoutTransform = new ScaleTransform(scale, scale);
        head.MaxWidth = room / scale;
        var cell = new Grid { Height = Math.Round(34 * Theme.LineFactor), Margin = new Thickness(0, 0, slot + 8, 0) };
        cell.Children.Add(head);
        two.Children.Add(cell);
        var py = Lines(new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0), FontFamily = Theme.Text }, 15);
        AddPinyin(py.Inlines, syllables, 15, " ");
        two.Children.Add(py);
        return two;
    }

    const double HeaderLift = 1.5;

    FrameworkElement PartOf(JsonObject part)
    {
        var line = Lines(new TextBlock { FontSize = Theme.Latin(12), FontFamily = Theme.Text, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis }, 13);
        line.Inlines.Add(new Run("Part of ") { Foreground = Theme.Secondary });
        line.Inlines.Add(new Run((string?)part["word"]) { FontWeight = Theme.ChineseWeight(FontWeights.Medium), FontSize = 13 * Theme.ChineseScale, Foreground = Theme.Primary, FontFamily = Theme.Chinese });
        line.Inlines.Add(new Run(" " + (string?)part["pinyin"]) { Foreground = Theme.Secondary });
        if ((string?)part["meaning"] is string m) line.Inlines.Add(new Run(" " + m) { Foreground = Theme.Primary });
        // On the line's baseline, as the Mac's sits, 4 after the text.
        var chevron = OnBaseline(Icons.ChevronForward, Theme.Tertiary, ChevronBaseline);
        chevron.Margin = new Thickness(4, 0, 0, 0);
        line.Inlines.Add(new InlineUIContainer(chevron) { BaselineAlignment = BaselineAlignment.Baseline });
        var row = RowButton(line, bleed: 4, vertical: 2, () => actions.OpenPartOf(), hug: true);
        row.ToolTip = $"Look up {part["word"]}";
        row.Margin = new Thickness(0, 4, 0, 0);
        return row;
    }

    // MARK: Phrase card

    void Phrase(JsonObject c)
    {
        var text = (string?)c["text"] ?? "";
        var slot = AddButtons((string?)c["copy"] ?? text, text);
        var top = new StackPanel();
        var source = Lines(new TextBlock
        {
            Text = text, FontSize = 14 * Theme.ChineseScale, FontFamily = Theme.Chinese, Foreground = Theme.Secondary, TextWrapping = TextWrapping.Wrap,
            MaxHeight = Math.Round(14 * Theme.LineFactor) * 4, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, SourceTop, slot + 8, 0),
        }, 14);
        top.Children.Add(Track("source", source));
        PlaceButtons(source, 14, Theme.Chinese, FontWeights.Normal, 5 - SourceTop);
        if ((string?)c["translation"] is string t)
        {
            var tb = Label(t, 16, Theme.Primary, top: 4);
            Lines(tb, 16, 2);
            top.Children.Add(Keyed("translation", tb));
        }
        else if ((string?)c["translationError"] is string e) top.Children.Add(Keyed("translationError", Label(e, 11, Theme.Secondary, top: 4)));
        else
        {
            // Lower than a status line elsewhere: the Mac centres it where the translation will be.
            var busy = Busy("Translating…", top: 9);
            busy.Margin = new Thickness(0, 9, 0, -2);
            top.Children.Add(Keyed("translating", busy));
        }
        content.Children.Add(Track("phraseTop", top));

        var rows = c["rows"]?.AsArray() ?? new JsonArray();
        if (rows.Count == 0) return;
        // 2 more above the divider and 1 less under the label than the spec's 12 and 8: what
        // lines the label and rows up with the Mac's, given the fonts' different metrics.
        var words = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        words.Children.Add(Divider());
        words.Children.Add(Section("Words"));
        var list = new StackPanel { Margin = new Thickness(0, 7, 0, 0) };
        // Every gloss starts at the same x: the widest word block's.
        var column = rows.OfType<JsonObject>().Select(r => WordBlock(r).Measure()).DefaultIfEmpty(0).Max();
        foreach (var node in rows)
        {
            if (node is not JsonObject r) continue;
            list.Children.Add(Track("prow:" + r["token"], PhraseRow(r, column)));
            if ((bool?)r["open"] == true) list.Children.Add(Keyed("detail:" + r["token"], Detail(r), slide: -6));
        }
        if ((string?)c["hidden"] is string hidden) list.Children.Add(Track("hidden", Label(hidden, 11, Theme.Tertiary, top: 4, bottom: 4)));
        words.Children.Add(list);
        content.Children.Add(Track("words", words));
    }

    /// PingFang sets the source text 2 lower in its line than YaHei does.
    const double SourceTop = 2;

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
        var py = Lines(new TextBlock { Margin = new Thickness(0, 1, 0, 0), FontFamily = Theme.Text }, 10.5);
        AddPinyin(py.Inlines, syllables, 10.5, " ");
        b.Panel.Children.Add(pending ? PinyinBars(syllables, py.Margin) : py);
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
        FrameworkElement glossView = pending ? new Bars(glossText, gloss.Margin) : Keyed("gloss:" + token, gloss, glossText, crossfade: true);
        Grid.SetColumn(glossView, 2);
        grid.Children.Add(glossView);

        if ((bool?)r["hasNote"] == true)
        {
            // On the gloss's first baseline, as the Mac lines it up.
            var mark = NoteMark();
            mark.VerticalAlignment = VerticalAlignment.Top;
            mark.Margin = new Thickness(12, gloss.Margin.Top + Baseline(Theme.Text, 13, FontWeights.Normal) - BubbleBaseline, 0, 0);
            Grid.SetColumn(mark, 3);
            grid.Children.Add(mark);
        }
        var chevron = Icons.ChevronForward.Shape(Theme.Tertiary);
        chevron.VerticalAlignment = VerticalAlignment.Top;
        chevron.Margin = new Thickness(12, gloss.Margin.Top + Baseline(Theme.Text, 13, FontWeights.Normal) - ChevronBaseline, 0, 0);
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
            Add(Keyed($"dstatus:{token}:{status}", status == "Reading the sentence…" ? Busy(status, top: 0) : Label(status, status == "Not in the dictionary" ? 12 : 11, Theme.Secondary)));
        if ((string?)r["here"] is string here)
        {
            var line = Lines(new TextBlock { FontSize = Theme.Latin(12), FontFamily = Theme.Text, TextWrapping = TextWrapping.Wrap, Foreground = Theme.Primary }, 12);
            line.Inlines.Add(new Run("In this sentence: ") { Foreground = Theme.Secondary });
            line.Inlines.Add(new Run(KeepLastWords(here, 3)) { FontWeight = Theme.LatinWeight(FontWeights.Medium) });
            Add(Keyed("here:" + token, line));
        }
        if ((string?)r["back"] is string back) Add(Keyed("back:" + token, Back(back, token, top: 0)));
        if (r["note"] is JsonObject note) Add(Keyed("dnote:" + token, Note(note, 0)));
        var senses = r["senses"]?.AsArray() ?? new JsonArray();
        if (senses.Count > 0)
        {
            var list = new StackPanel();
            var total = Total(senses, (string?)r["more"]);
            foreach (var node in senses)
                if (node is JsonObject s) list.Children.Add(Track($"row:p{token}:{s["index"]}", SenseRow(s, 12, 3, total, "p" + token, noteMarks: false, list.Children.Count == 0, () => actions.Pick(token, (int)s["index"]!))));
            if ((string?)r["more"] is string more) list.Children.Add(Track($"more:p{token}", More(more, 3, () => actions.ToggleAll(token), "p" + token)));
            Add(Track("dlist:" + token, list));
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
        var line = Lines(new TextBlock { FontSize = Theme.Latin(size), FontFamily = Theme.Text, TextWrapping = TextWrapping.Wrap, Foreground = dim ? Theme.Secondary : Theme.Primary, ToolTip = (string?)r["tip"] }, size);
        var pos = (string?)r["pos"];
        if (pos != null) line.Inlines.Add(new Run(pos + " ") { FontStyle = FontStyles.Italic, Foreground = Theme.Secondary });
        line.Inlines.Add(new Run(KeepLastWords((string?)r["gloss"] ?? "", pos != null ? 1 : 0)) { FontWeight = Theme.LatinWeight(chosen ? FontWeights.SemiBold : FontWeights.Normal) });
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
        var check = Icons.Checkmark.Shape(Theme.Accent);
        check.HorizontalAlignment = HorizontalAlignment.Right;
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
        var chevron = Icons.ChevronDown.Shape(Theme.Accent);
        chevron.Margin = new Thickness(4, 0, 0, 0);
        chevron.VerticalAlignment = VerticalAlignment.Center;
        Rotate(chevron, "more:" + scope, text == "Show Fewer" ? 180 : 0);
        line.Children.Add(chevron);
        return RowButton(line, bleed: 8, vertical: vertical, toggle);
    }

    FrameworkElement Back(string meaning, int token, double top)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, top, 0, 0), Background = Brushes.Transparent, HorizontalAlignment = HorizontalAlignment.Left, Cursor = Cursors.Arrow };
        var icon = Icons.UturnBack.Shape(Theme.Accent);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 4, 0);
        line.Children.Add(icon);
        var label = Label($"Back to “{meaning}”", 12, Theme.Accent);
        label.TextWrapping = TextWrapping.NoWrap;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        line.Children.Add(label);
        Pressable(line, () => actions.UseSuggested(token));
        return line;
    }

    /// A plain button: dims to 0.55 while pressed (ease-out 0.08 s), acts on a release over it.
    static void Pressable(UIElement e, Action act)
    {
        var pressed = false;
        e.MouseLeftButtonDown += (_, a) => { pressed = true; Motion.To(e, UIElement.OpacityProperty, 0.55, 0.08); a.Handled = true; };
        e.MouseLeave += (_, _) => { pressed = false; Motion.To(e, UIElement.OpacityProperty, 1, 0.08); };
        e.MouseLeftButtonUp += (_, a) =>
        {
            a.Handled = true;
            Motion.To(e, UIElement.OpacityProperty, 1, 0.08);
            if (!pressed || CardWindow.WasDrag) return;
            pressed = false;
            act();
        };
    }

    FrameworkElement Note(JsonObject note, double top)
    {
        var lost = (string?)note["title"] == "Lost in translation";
        var box = new Border { Background = Theme.NoteFill, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 11), Margin = new Thickness(0, top, 0, 0) };
        var stack = new StackPanel();
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = (lost ? Icons.Translate : Icons.Globe).Shape(lost ? Theme.NoteLost : Theme.NoteCulture);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 4, 0);
        title.Children.Add(icon);
        title.Children.Add(Label((string?)note["title"] ?? "", 11, Theme.Secondary, FontWeights.SemiBold));
        stack.Children.Add(title);
        var body = Label((string?)note["text"] ?? "", 13, Theme.Primary, top: 2.5);   // the spec's 4, less what Segoe adds
        Lines(body, 13, 2);
        stack.Children.Add(body);
        box.Child = stack;
        return box;
    }

    /// A spinner and a line of status, `height` tall with both centred (the line's own height if 0).
    FrameworkElement Busy(string text, double top = 4, double height = 0)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, top, 0, 0) };
        if (height > 0) line.Height = height;
        var spinner = Spinner();
        spinner.VerticalAlignment = VerticalAlignment.Center;
        spinner.Margin = new Thickness(0, 0, 6, 0);
        line.Children.Add(spinner);
        var label = Label(text, 12, Theme.Secondary);
        label.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(label);
        return line;
    }

    /// The Mac's small spinner: eight spokes fading round, stepping an eighth of a turn at a time.
    static FrameworkElement Spinner()
    {
        const double size = 11, inner = 2.4, outer = 5.0;
        var canvas = new Canvas { Width = size, Height = size, RenderTransformOrigin = new Point(0.5, 0.5) };
        var c = size / 2;
        for (var k = 0; k < 8; k++)
        {
            var a = -Math.PI / 2 - k * Math.PI / 4;   // the brightest spoke on top, fading anticlockwise
            canvas.Children.Add(new Line
            {
                X1 = c + inner * Math.Cos(a), Y1 = c + inner * Math.Sin(a), X2 = c + outer * Math.Cos(a), Y2 = c + outer * Math.Sin(a),
                Stroke = Theme.Secondary, StrokeThickness = 1.3, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
                Opacity = 1 - k * 0.1,
            });
        }
        var spin = new RotateTransform();
        canvas.RenderTransform = spin;
        if (!Motion.Reduced)
        {
            var steps = new DoubleAnimationUsingKeyFrames { Duration = new Duration(TimeSpan.FromSeconds(0.8)), RepeatBehavior = RepeatBehavior.Forever };
            for (var k = 0; k < 8; k++) steps.KeyFrames.Add(new DiscreteDoubleKeyFrame(k * 45, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(k * 0.1))));
            spin.BeginAnimation(RotateTransform.AngleProperty, steps);
        }
        return canvas;
    }

    static FrameworkElement Divider() => new Border { Height = 1, Background = Theme.Divider };
    static FrameworkElement Section(string title) => Label(title, 11, Theme.Secondary, FontWeights.SemiBold, top: 8);

    static FrameworkElement NoteMark() => Icons.Bubble.Shape(Theme.Tertiary);

    /// Where a symbol's baseline sits in its box, from the top: what the Mac lines up with the
    /// text's when a row aligns by baseline.
    const double ChevronBaseline = 8.8, BubbleBaseline = 10.3;

    /// `icon` on a text line's baseline: a box as tall as the icon's baseline, which an
    /// InlineUIContainer stands on the baseline, with the icon hanging below it as far as it reaches.
    static FrameworkElement OnBaseline(Icon icon, Brush brush, double baseline)
    {
        var shape = icon.Shape(brush);
        var box = new Canvas { Width = icon.Width, Height = baseline, ClipToBounds = false };
        box.Children.Add(shape);
        return box;
    }

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
        var highlight = new Border { CornerRadius = new CornerRadius(6), Background = fill, IsHitTestVisible = false, Margin = new Thickness(-bleed, 0, -bleed, 0) };
        var host = new Grid();
        host.Children.Add(highlight);
        host.Children.Add(row);
        host.HorizontalAlignment = row.HorizontalAlignment;
        if (click == null) return host;
        var pressed = false;
        host.MouseEnter += (_, _) =>
        {
            if (JustBuilt) { fill.BeginAnimation(Brush.OpacityProperty, null); fill.Opacity = 0.05; }
            else Motion.To(fill, Brush.OpacityProperty, pressed ? 0.09 : 0.05, 0.08);
        };
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

    /// A button's symbol (Icons.cs), in a brush whose colour animates.
    sealed class Symbol
    {
        public readonly Path Path;
        public readonly SolidColorBrush Ink;
        public readonly bool Tinted;
        public Symbol(Icon icon, Color color, bool tinted, double dy = 0)
        {
            Ink = new SolidColorBrush(color);
            Tinted = tinted;
            Path = icon.Shape(Ink);
            Path.HorizontalAlignment = HorizontalAlignment.Center;
            Path.VerticalAlignment = VerticalAlignment.Center;
            // The pin's weight is in its head: the Mac lowers it a point so it sits level.
            if (dy != 0) Path.RenderTransform = new TranslateTransform(0, dy);
        }
        public void Set(Icon icon) { Path.Data = icon.Geometry; Path.Width = icon.Width; Path.Height = icon.Height; }
        public void To(Brush target, double seconds)
        {
            var c = ((SolidColorBrush)target).Color;
            Ink.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(c, new Duration(TimeSpan.FromSeconds(seconds))) { EasingFunction = Motion.EaseOut });
        }
    }

    readonly List<Symbol> symbols = new();

    /// The Listen, Copy and Pin buttons; returns the width their slot takes on the first line.
    double AddButtons(string copy, string speech)
    {
        symbols.Clear();
        var n = 0;
        // Listen is always there, as on the Mac; with no Chinese voice installed it says how to add one.
        buttons.Children.Add(ListenButton(speech)); n++;
        buttons.Children.Add(CopyButton(copy)); n++;
        var pin = actions.Pinned ? new Symbol(Icons.PinFill, ((SolidColorBrush)Theme.Accent).Color, true, dy: 1) : new Symbol(Icons.Pin, Rest, false, dy: 1);
        buttons.Children.Add(ActionButton(pin, actions.Pinned ? "Unpin: close when you click elsewhere" : "Pin: keep the card here for every lookup", _ => actions.TogglePin())); n++;
        buttons.Margin = new Thickness(0, 0, Pad * Zoom - 6 - ButtonGap / 2, 0);
        // The slot they take on the first line, in the content's own (unzoomed) units. The Mac
        // keeps room for all three even when there's no voice to listen with.
        return (3 * ButtonW + 2 * ButtonGap - 6) / Zoom;
    }

    /// A symbol's colour at rest: tertiary, secondary while the pointer is on the card.
    Color Rest => ((SolidColorBrush)(hovered ? Theme.Secondary : Theme.Tertiary)).Color;

    /// The buttons' centre sits `above` over the first line's baseline.
    void PlaceButtons(FrameworkElement firstLine, double size, FontFamily family, FontWeight weight, double above)
    {
        var top = (Pad + Baseline(family, size, weight) - above) * Zoom - ButtonH / 2;
        buttons.Margin = new Thickness(0, Math.Max(0, top), buttons.Margin.Right, 0);
    }

    /// Until when Copy shows its checkmark; kept here so a rebuild doesn't lose it.
    DateTime copiedUntil;
    string copied = "";

    /// Listen: in the accent while the words are being said, when a click stops them.
    FrameworkElement ListenButton(string speech)
    {
        var symbol = new Symbol(Icons.Speaker, Rest, false);
        if (!actions.CanListen)
        {
            // No Chinese voice: the help says how to get one, and a click shows it and opens
            // Windows' speech settings, where one is added.
            var none = ActionButton(symbol, NoVoice, b =>
            {
                if (b.ToolTip is not ToolTip tip) b.ToolTip = tip = new ToolTip { Content = NoVoice };
                tip.PlacementTarget = b;
                tip.IsOpen = true;
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:speech") { UseShellExecute = true }); } catch { }
            });
            return none;
        }
        var help = $"Listen to “{speech}”";
        var button = ActionButton(symbol, help, _ => actions.Listen(speech));
        void Update()
        {
            if (!buttons.Children.Contains(button)) { Speech.Changed -= Update; return; }   // rebuilt since
            var on = Speech.Speaking == speech;
            button.ToolTip = on ? "Stop" : help;
            if (on) { symbols.Remove(symbol); symbol.To(Theme.Accent, 0.15); }
            else if (!symbols.Contains(symbol)) { symbols.Add(symbol); symbol.To(button.IsMouseOver ? Theme.Primary : hovered ? Theme.Secondary : Theme.Tertiary, 0.15); }
        }
        Speech.Changed += Update;
        if (Speech.Speaking == speech) { symbols.Remove(symbol); symbol.Ink.Color = ((SolidColorBrush)Theme.Accent).Color; button.ToolTip = "Stop"; }
        return button;
    }

    const string NoVoice = "Add a Chinese voice in Windows Settings to listen";

    FrameworkElement CopyButton(string text)
    {
        var label = text.Length > 14 ? text[..13] + "…" : text;
        var help = $"Copy “{label}”";
        var symbol = new Symbol(Icons.Copy, Rest, false);
        void Checked(Border b, TimeSpan left)
        {
            // A checkmark in the accent, then back to the copy symbol.
            symbol.Set(Icons.Checkmark);
            symbol.Ink.BeginAnimation(SolidColorBrush.ColorProperty, null);
            symbol.Ink.Color = ((SolidColorBrush)Theme.Accent).Color;
            symbols.Remove(symbol);
            b.ToolTip = "Copied";
            var t = new System.Windows.Threading.DispatcherTimer { Interval = left };
            t.Tick += (_, _) =>
            {
                t.Stop();
                if (DateTime.UtcNow < copiedUntil - TimeSpan.FromMilliseconds(50)) return;   // copied again since
                symbol.Set(Icons.Copy);
                symbol.Ink.Color = b.IsMouseOver ? ((SolidColorBrush)Theme.Primary).Color : Rest;
                if (!symbols.Contains(symbol)) symbols.Add(symbol);
                b.ToolTip = help;
            };
            t.Start();
        }
        Border? button = null;
        button = ActionButton(symbol, help, b =>
        {
            actions.Copy(text);
            copied = text;
            copiedUntil = DateTime.UtcNow.AddSeconds(1.5);
            Checked(b, TimeSpan.FromSeconds(1.5));
        });
        if (copied == text && DateTime.UtcNow < copiedUntil) Checked(button, copiedUntil - DateTime.UtcNow);
        return button;
    }

    Border ActionButton(Symbol symbol, string help, Action<Border> act)
    {
        if (!symbol.Tinted) symbols.Add(symbol);
        var fill = new SolidColorBrush(((SolidColorBrush)Theme.Ink(1)).Color) { Opacity = 0 };
        var b = new Border { Width = ButtonW, Height = ButtonH, CornerRadius = new CornerRadius(6), Background = fill, Child = symbol.Path, ToolTip = help, Margin = new Thickness(ButtonGap / 2, 0, ButtonGap / 2, 0) };
        var pressed = false;
        b.MouseEnter += (_, _) =>
        {
            if (JustBuilt)
            {
                // Rebuilt under the pointer: hovered already.
                fill.BeginAnimation(Brush.OpacityProperty, null); fill.Opacity = 0.07;
                if (symbols.Contains(symbol)) { symbol.Ink.BeginAnimation(SolidColorBrush.ColorProperty, null); symbol.Ink.Color = ((SolidColorBrush)Theme.Primary).Color; }
                return;
            }
            Motion.To(fill, Brush.OpacityProperty, 0.07, 0.15);
            if (symbols.Contains(symbol)) symbol.To(Theme.Primary, 0.15);
        };
        b.MouseLeave += (_, _) =>
        {
            pressed = false;
            Motion.To(fill, Brush.OpacityProperty, 0, 0.15);
            Motion.To(b, UIElement.OpacityProperty, 1, 0.08);
            if (symbols.Contains(symbol)) symbol.To(hovered ? Theme.Secondary : Theme.Tertiary, 0.15);
        };
        b.MouseLeftButtonDown += (_, e) => { pressed = true; Motion.To(b, UIElement.OpacityProperty, 0.55, 0.08); e.Handled = true; };
        b.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            Motion.To(b, UIElement.OpacityProperty, 1, 0.08);
            if (!pressed || CardWindow.WasDrag) return;
            pressed = false;
            act(b);
        };
        return b;
    }

    /// The symbols brighten while the pointer is anywhere on the card (ease-out 0.2 s).
    void Recolor()
    {
        foreach (var s in symbols)
            if (!((FrameworkElement)s.Path.Parent).IsMouseOver) s.To(hovered ? Theme.Secondary : Theme.Tertiary, 0.2);
    }

    // MARK: Text

    static TextBlock Label(string text, double size, Brush color, FontWeight? weight = null, double top = 0, double bottom = 0) => Lines(new TextBlock
    {
        Text = KeepLastWords(text), FontSize = Theme.Latin(size), Foreground = color, FontWeight = Theme.LatinWeight(weight ?? FontWeights.Normal),
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, top, 0, bottom), FontFamily = Theme.Text,
    }, size);

    /// The Mac doesn't leave one word alone on a paragraph's last line (its text system's
    /// "push out" line breaking): the last two words of English text are kept together, which
    /// does the same. Text with Chinese in it breaks as it would anyway, as on the Mac.
    static string KeepLastWords(string text, int before = 0)
    {
        if (text.Any(c => c >= 0x2E80)) return text;
        var last = text.TrimEnd().LastIndexOf(' ');
        if (last <= 0 || text.Count(c => c == ' ') + before < 2) return text;
        return text[..last] + "\u00A0" + text[(last + 1)..];
    }

    /// San Francisco's line height at a size: 1.2 of it, rounded, except at 12, where the
    /// Mac's lines measure 15 rather than 14.
    static double LineHeight(double size) => size == 12 ? 15 : Math.Round(size * Theme.LineFactor);

    static TextBlock Lines(TextBlock t, double size, double extra = 0)
    {
        t.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        t.LineHeight = LineHeight(size) + extra;
        // Latin text as wide as the Mac's, so it wraps where the Mac's does.
        if (t.FontFamily == Theme.Text) t.LayoutTransform = new ScaleTransform(Theme.LatinStretch(size), 1);
        return t;
    }

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
            inlines.Add(new Run((i > 0 ? gap : "") + (string?)s?["text"]) { FontFamily = Theme.Text, FontSize = Theme.Latin(size), Foreground = Theme.PinyinColor((int?)s?["tone"] ?? 5) });
        }
    }

    /// A pending word's pinyin as SwiftUI's placeholder redaction draws it: a bar per syllable,
    /// 7 tall, 2 above the bottom of the 13 line, in the tone's colour faintly (the neutral tone in grey).
    static FrameworkElement PinyinBars(JsonArray syllables, Thickness margin)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Height = Math.Round(10.5 * Theme.LineFactor), Margin = margin, HorizontalAlignment = HorizontalAlignment.Left };
        for (var i = 0; i < syllables.Count; i++)
        {
            var s = syllables[i] as JsonObject;
            var tone = (int?)s?["tone"] ?? 5;
            var color = tone is >= 1 and <= 4 ? ((SolidColorBrush)Theme.PinyinColor(tone)).Color : ((SolidColorBrush)Theme.Ink(1)).Color;
            var bar = new Border
            {
                Width = Math.Ceiling(TextWidth((string?)s?["text"] ?? "", Theme.Text, Theme.Latin(10.5))), Height = 7, CornerRadius = new CornerRadius(2),
                Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round((tone is >= 1 and <= 4 ? 0.19 : 0.08) * 255), color.R, color.G, color.B)),
                VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(i > 0 ? 2 : 0, 0, 0, 2),
            };
            line.Children.Add(bar);
        }
        return line;
    }

    /// A line's width as drawn: Latin text at `size` (already scaled by LatinScale) is
    /// stretched as `Lines` stretches it.
    static double TextWidth(string text, FontFamily family, double size) =>
        new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(family, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), size, Brushes.Black, 1.0).WidthIncludingTrailingWhitespace
        * (family == Theme.Text ? Theme.LatinStretch(size / Theme.LatinScale) : 1);

    /// A pending gloss as redaction draws it: a bar per line the text would wrap to (two at
    /// most), as wide as that line, 9 tall and 2 above the bottom of the 16 line.
    sealed class Bars : FrameworkElement
    {
        const double Size = 13, Bar = 9;
        readonly string[] words;
        List<double> widths = new();
        static double LineH => Math.Round(Size * Theme.LineFactor);
        public Bars(string text, Thickness margin)
        {
            words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            Margin = margin;
            HorizontalAlignment = HorizontalAlignment.Left;
            VerticalAlignment = VerticalAlignment.Top;
        }
        protected override Size MeasureOverride(Size available)
        {
            widths = new List<double>();
            var space = TextWidth(" ", Theme.Text, Theme.Latin(Size));
            double line = 0;
            foreach (var w in words)
            {
                var ww = TextWidth(w, Theme.Text, Theme.Latin(Size));
                if (line > 0 && line + space + ww > available.Width)
                {
                    widths.Add(line);
                    if (widths.Count == 2) break;
                    line = ww;
                }
                else line = line > 0 ? line + space + ww : ww;
            }
            if (widths.Count < 2 && line > 0) widths.Add(Math.Min(line, available.Width));
            if (widths.Count == 0) widths.Add(40);
            return new Size(Math.Ceiling(widths.Max()), LineH * widths.Count);
        }
        protected override void OnRender(DrawingContext dc)
        {
            var fill = Theme.Ink(0.082);
            for (var i = 0; i < widths.Count; i++)
                dc.DrawRoundedRectangle(fill, null, new Rect(0, i * LineH + LineH - 2 - Bar, Math.Ceiling(widths[i]), Bar), 2, 2);
        }
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
        return baselines[key] = LineHeight(size) * ratio;
    }

    // MARK: Transitions

    readonly Dictionary<string, FrameworkElement> tracked = new();

    /// Registers a part that keeps its place across changes, so it can slide to a new one.
    T Track<T>(string key, T e) where T : FrameworkElement
    {
        tracked[key] = e;
        return e;
    }

    /// Where each tracked part is, within its own panel (so a part inside a moving part moves
    /// only by its own change), counting any slide still under way.
    Dictionary<string, Point> Positions()
    {
        var d = new Dictionary<string, Point>();
        foreach (var (key, e) in tracked)
        {
            if (!e.IsVisible || VisualTreeHelper.GetParent(e) is not Visual parent) continue;
            try { d[key] = e.TransformToAncestor(parent).Transform(new Point(0, 0)); } catch (InvalidOperationException) { }
        }
        return d;
    }

    /// Parts that were on the card before slide from their old place to their new one with
    /// cardMotion, as SwiftUI moves views around inserted and removed ones.
    void Slide(Dictionary<string, Point> was)
    {
        Root.UpdateLayout();
        foreach (var (key, e) in tracked)
        {
            if (!was.TryGetValue(key, out var old) || VisualTreeHelper.GetParent(e) is not Visual parent) continue;
            Point now;
            try { now = e.TransformToAncestor(parent).Transform(new Point(0, 0)); } catch (InvalidOperationException) { continue; }
            var dy = old.Y - now.Y;
            if (Math.Abs(dy) < 0.5) continue;
            var t = e.RenderTransform as TranslateTransform ?? new TranslateTransform();
            e.RenderTransform = t;
            Motion.Animate(t, TranslateTransform.YProperty, dy, 0, Motion.ContentDuration, Motion.ContentEase);
        }

        // Parts that are new and not keyed (rows after Show All, Show Fewer, Other words) fade
        // in, unless they're inside a part that's new itself and fades in whole.
        var fresh = tracked.Where(p => !was.ContainsKey(p.Key)).Select(p => p.Value).ToList();
        foreach (var (key, e) in tracked)
        {
            if (was.ContainsKey(key) || now.ContainsKey(key)) continue;
            if (fresh.Any(f => f != e && f.IsAncestorOf(e))) continue;
            Motion.FadeIn(e);
        }
    }

    /// The keyed parts on the card now, where they are, so the ones that leave or change can
    /// fade out in place.
    List<(string Key, string Value, FrameworkElement Element, Point At)> Snapshot()
    {
        var list = new List<(string, string, FrameworkElement, Point)>();
        foreach (var (key, value) in now)
        {
            if (!tracked.TryGetValue(key, out var e) || !e.IsVisible || e.ActualWidth < 1 || e.ActualHeight < 1) continue;
            try { list.Add((key, value, e, e.TransformToAncestor(Root).Transform(new Point(0, 0)))); } catch (InvalidOperationException) { }
        }
        return list;
    }

    /// Parts that left, and the old copy of a part whose text changed, fade out where they
    /// were while the rest moves and the new copy fades in: SwiftUI's removal and crossfade.
    void FadeOut(List<(string Key, string Value, FrameworkElement Element, Point At)> old)
    {
        var going = old.Where(o => !now.TryGetValue(o.Key, out var v) || (v != o.Value && crossfades.Contains(o.Key))).ToList();
        foreach (var o in going)
        {
            if (going.Any(g => g.Element != o.Element && g.Element.IsAncestorOf(o.Element))) continue;
            // The old part itself, which left the card when it was rebuilt, fades out in place.
            var ghost = o.Element;
            var w = ghost.ActualWidth; var h = ghost.ActualHeight;
            switch (VisualTreeHelper.GetParent(ghost) ?? LogicalTreeHelper.GetParent(ghost))
            {
                case null: break;
                case Panel p: p.Children.Remove(ghost); break;
                case Decorator d: d.Child = null; break;
                default: continue;
            }
            ghost.Width = w; ghost.Height = h;
            ghost.Margin = new Thickness(0);
            ghost.RenderTransform = Transform.Identity;
            Canvas.SetLeft(ghost, o.At.X); Canvas.SetTop(ghost, o.At.Y);
            ghosts.Children.Add(ghost);
            var fade = new DoubleAnimation(0, Motion.Reduced ? Motion.ContentDuration : new Duration(TimeSpan.FromSeconds(0.3))) { EasingFunction = Motion.EaseOut };
            fade.Completed += (_, _) => ghosts.Children.Remove(ghost);
            ghost.BeginAnimation(UIElement.OpacityProperty, fade);
        }
    }

    /// Keys whose old copy fades out when their value changes.
    readonly HashSet<string> crossfades = new();

    /// Registers a part by key: new parts fade in (sliding from `slide` above), and with
    /// `crossfade`, a part whose value changed fades in again.
    T Keyed<T>(string key, T e, string value = "", double slide = 0, bool crossfade = false) where T : UIElement
    {
        now[key] = value;
        if (crossfade) crossfades.Add(key);
        if (e is FrameworkElement fe) tracked[key] = fe;
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
        if (animate && was != angle) Motion.Animate(r, RotateTransform.AngleProperty, was, angle, Motion.ContentDuration, Motion.ContentEase);
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
        Motion.Animate(e, UIElement.OpacityProperty, a, b, Motion.ContentDuration, Motion.ContentEase);
        Motion.Animate(s, ScaleTransform.ScaleXProperty, sa, sb, Motion.ContentDuration, Motion.ContentEase);
        Motion.Animate(s, ScaleTransform.ScaleYProperty, sa, sb, Motion.ContentDuration, Motion.ContentEase);
    }
}
