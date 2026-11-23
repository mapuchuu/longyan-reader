using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Longyan;

/// Add to Anki in Settings: whether Anki answers, and while it does, the deck cards go into
/// (the Mac's Anki Deck menu: the default deck first, then Anki's own, the chosen one checked).
/// Updated in place when Anki opens or quits.
sealed class AnkiCard
{
    public readonly Border Root;
    readonly Fluent f;
    readonly bool preview;
    readonly StackPanel stack = new();

    public AnkiCard(Fluent look, bool preview)
    {
        f = look;
        this.preview = preview;
        Root = f.CardFrame(stack, new Thickness(0));
        Show();
        if (preview) return;
        Root.Loaded += (_, _) => { Anki.Changed += Changed; Anki.Check(force: true); Show(); };
        Root.Unloaded += (_, _) => Anki.Changed -= Changed;
    }

    void Changed() => Root.Dispatcher.BeginInvoke(Show);

    void Show()
    {
        var available = preview || Anki.Available;
        var decks = preview ? new[] { "Default", "Longyan Reader", "Mandarin::HSK 4" } : Anki.Decks;
        var current = preview ? Anki.DefaultDeck : Anki.Deck;
        stack.Children.Clear();
        var status = f.Caption(available
            ? "Anki is open. Cards have a button that adds them to the deck below."
            : "Anki isn't open. " + Anki.SetupHelp);
        System.Windows.Automation.AutomationProperties.SetAutomationId(status, "AnkiStatus");
        stack.Children.Add(Padded(f.Row("", "Add to Anki", status, null), 16));
        if (!available) return;
        stack.Children.Add(f.Line());
        stack.Children.Add(Padded(f.Row(null, "Deck", "A deck that isn't in Anki yet is made with the first card.", null), 52));
        // The chosen deck stays listed even if it was renamed or deleted in Anki.
        var others = decks.Append(current).Where(d => d != Anki.DefaultDeck).Distinct().OrderBy(d => d, StringComparer.CurrentCulture);
        foreach (var deck in others.Prepend(Anki.DefaultDeck))
        {
            stack.Children.Add(f.Line());
            stack.Children.Add(DeckRow(deck, deck == current));
        }
    }

    Button DeckRow(string deck, bool chosen)
    {
        var check = chosen ? new TextBlock { Text = "", FontFamily = Theme.Icons, FontSize = 14, Foreground = f.B(f.AccentText) } : null;
        var template = new ControlTemplate(typeof(Button));
        var frame = new FrameworkElementFactory(typeof(Border), "frame");
        frame.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        frame.SetValue(Border.PaddingProperty, new Thickness(52, 6, 16, 6));
        frame.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
        template.VisualTree = frame;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, f.B(f.ControlHover), "frame"));
        template.Triggers.Add(hover);
        var button = new Button
        {
            Style = new Style(typeof(Button)), Template = template, Content = f.Row(null, deck, null, check, minHeight: 32),
            HorizontalContentAlignment = HorizontalAlignment.Stretch, Cursor = Cursors.Hand,
        };
        System.Windows.Automation.AutomationProperties.SetName(button, deck + (chosen ? ", chosen" : ""));
        System.Windows.Automation.AutomationProperties.SetAutomationId(button, "AnkiDeck");
        button.Click += (_, _) =>
        {
            if (preview || chosen) return;
            Anki.Deck = deck;
            Show();
        };
        return button;
    }

    static Border Padded(UIElement row, double left) => new() { Padding = new Thickness(left, 12, 16, 12), Child = row };
}
