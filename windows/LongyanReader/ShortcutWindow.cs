using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Longyan;

/// Picks the look-up shortcut, in Settings: a box that records the keys pressed, Reset, and
/// what's wrong with the keys if anything. A pick that works is used at once, as Windows
/// settings apply without a Save.
sealed class ShortcutPicker : UserControl
{
    readonly TextBox field;
    readonly TextBlock message;
    readonly Button reset;
    readonly Fluent look;
    readonly bool preview;
    Combo? picked;          // keys recorded, not yet used
    bool useDefault;        // Reset pressed, not yet used
    string? problem;

    /// `preview`: drawn for --render-windows, with no shortcut registered to ask about.
    public ShortcutPicker(Fluent look, bool preview = false)
    {
        this.look = look;
        this.preview = preview;
        var grid = new Grid { Width = 260 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        field = new TextBox
        {
            IsReadOnly = true, IsReadOnlyCaretVisible = false, Cursor = Cursors.Arrow,
            ContextMenu = null, IsUndoEnabled = false,
        };
        InputMethod.SetIsInputMethodEnabled(field, false);
        System.Windows.Automation.AutomationProperties.SetName(field, "Shortcut");
        System.Windows.Automation.AutomationProperties.SetAutomationId(field, "Shortcut");
        field.PreviewKeyDown += Record;
        // Modifiers let go with no key: back to what was there.
        field.PreviewKeyUp += (_, _) => { if (Keyboard.Modifiers == ModifierKeys.None) Show(); };
        field.GotKeyboardFocus += (_, _) => Shortcut.Pause();
        field.LostKeyboardFocus += (_, _) => Shortcut.Resume();
        grid.Children.Add(field);
        reset = new Button { Content = "Reset", Margin = new Thickness(8, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(reset, "Reset the shortcut to the default");
        reset.Click += (_, _) => { picked = null; useDefault = true; problem = null; Commit(); };
        Grid.SetColumn(reset, 1);
        grid.Children.Add(reset);
        message = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(1, 4, 0, 0), Visibility = Visibility.Collapsed };
        Grid.SetRow(message, 1);
        Grid.SetColumnSpan(message, 2);
        grid.Children.Add(message);
        Content = grid;
        Show();
        Loaded += (_, _) => Show();
        Unloaded += (_, _) => Shortcut.Resume();
    }

    public void FocusField() => field.Focus();

    /// Uses the pick or the default now; says why when it can't be.
    void Commit()
    {
        if (preview) return;
        bool ok;
        if (useDefault) ok = Shortcut.Use(null);
        else if (picked is Combo c)
        {
            Shortcut.Pause();
            problem = Shortcut.Problem(c);
            ok = problem == null && Shortcut.Use(c);
            problem ??= ok ? null : "Another app is using this shortcut";
        }
        else ok = true;
        if (ok) { picked = null; useDefault = false; }
        // Still recording: the shortcut's own keys go to the box, not to a lookup.
        if (field.IsKeyboardFocused) Shortcut.Pause();
        Show();
    }

    void Record(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key == Key.ImeProcessed ? e.ImeProcessedKey : e.Key;
        var mods = Keyboard.Modifiers;
        // Tab and Esc on their own keep their usual jobs: the next control, closing the window.
        if (mods is ModifierKeys.None or ModifierKeys.Shift && key is Key.Tab) return;
        if (mods == ModifierKeys.None && key is Key.Escape or Key.Enter) return;
        e.Handled = true;
        uint m = 0;
        if (mods.HasFlag(ModifierKeys.Control)) m |= Combo.Ctrl;
        if (mods.HasFlag(ModifierKeys.Alt)) m |= Combo.Alt;
        if (mods.HasFlag(ModifierKeys.Shift)) m |= Combo.Shift;
        if (mods.HasFlag(ModifierKeys.Windows) || Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin)) m |= Combo.Win;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
        {
            // Modifiers so far, until a key comes with them.
            picked = null;
            useDefault = false;
            problem = null;
            field.Text = Combo.Prefix(m);
            message.Visibility = Visibility.Collapsed;
            return;
        }
        var vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (vk == 0) return;
        var c = new Combo(m, vk);
        picked = c;
        useDefault = false;
        problem = Shortcut.Problem(c);
        if (problem == null) Commit(); else Show();
    }

    void Show()
    {
        var c = useDefault ? Shortcut.Default : picked ?? Shortcut.Current;
        field.Text = c.Name;
        reset.IsEnabled = preview ? false : Shortcut.Chosen != null || picked != null;
        string? text = null;
        var error = true;
        if (problem != null) text = problem;
        else if (picked == null && !preview && !Shortcut.Registered) text = "Another app is using this shortcut";
        else if (Shortcut.Chosen == null && Shortcut.Default != Shortcut.Usual && !preview)
        {
            text = $"The default is {Shortcut.Default.Name} for the keyboards you have.";
            error = false;
        }
        message.Text = text ?? "";
        message.Foreground = look.B(error ? look.Error : look.TextSecondary);
        message.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
    }
}

/// The shortcut's row in Settings, from the tray (when the shortcut is taken) and the eye.
static class ShortcutWindow
{
    public static void Open() => SettingsWindow.Open(SettingsWindow.Place.Shortcut);
}
