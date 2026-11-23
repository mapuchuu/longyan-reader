using System.Windows;
using System.Windows.Controls;

namespace Longyan;

/// History's card in Settings (the Mac's Keep History menu): open it, keep it or not, only
/// the last 30 days, and clear it.
static class HistorySettings
{
    public static FrameworkElement Card(Fluent f, bool preview)
    {
        var keep = preview ? "all" : History.Keep;
        var stack = new StackPanel();
        stack.Children.Add(Padded(f.Row("\uE81C", "Lookup history",
            "The words and phrases you look up, with the meaning they had in their sentence. Kept on this PC only.",
            f.PushButton("Open", preview ? () => { } : HistoryWindow.Open, automationId: "OpenHistory"))));

        var on = f.Switch("Keep history", "KeepHistory", keep != "off");
        var month = f.Switch("Only the last 30 days", "KeepHistory30Days", keep == "days30");
        month.IsEnabled = keep != "off";
        if (!preview)
        {
            on.Checked += (_, _) => { History.Keep = month.IsChecked == true ? "days30" : "all"; month.IsEnabled = true; };
            on.Unchecked += (_, _) => { History.Keep = "off"; month.IsEnabled = false; };
            month.Checked += (_, _) => { if (History.IsOn) History.Keep = "days30"; };
            month.Unchecked += (_, _) => { if (History.IsOn) History.Keep = "all"; };
        }
        stack.Children.Add(f.Line());
        stack.Children.Add(Padded(f.Row(null, "Keep history", "When it's off, new lookups aren't added.", on), indent: true));
        stack.Children.Add(f.Line());
        stack.Children.Add(Padded(f.Row(null, "Only the last 30 days", "Older lookups are removed.", month), indent: true));
        stack.Children.Add(f.Line());
        stack.Children.Add(Padded(f.Row(null, "Clear history", "Moves the history file to the Recycle Bin, where you can still restore it.",
            f.PushButton("Clear…", preview ? () => { } : HistoryWindow.OpenToClear, automationId: "ClearHistory")), indent: true));
        return f.CardFrame(stack, new Thickness(0));
    }

    static Border Padded(UIElement row, bool indent = false) => new()
    {
        Padding = new Thickness(indent ? 52 : 16, 12, 16, 12), Child = row,
    };
}
