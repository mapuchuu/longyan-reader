using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Longyan;

/// Picks the look-up shortcut: a field that records the keys pressed, what's wrong with them if
/// anything, and Reset to default. Its own Save and Cancel are the host's (ShortcutWindow, and
/// later the settings window).
sealed class ShortcutPicker : UserControl
{
    readonly TextBox field;
    readonly TextBlock message;
    Combo? picked;          // keys recorded, or null for none yet
    bool useDefault;        // Reset to default pressed since
    string? problem;

    /// Raised when what Save would do changes (CanSave).
    public event Action? Changed;

    public ShortcutPicker()
    {
        FontFamily = SystemFonts.MessageFontFamily;
        FontSize = 12;
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock
        {
            Text = "Press the keys you want to use to look up selected text.",
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8),
        });
        field = new TextBox
        {
            IsReadOnly = true, IsReadOnlyCaretVisible = false, Height = 28, Padding = new Thickness(6, 0, 6, 0),
            VerticalContentAlignment = VerticalAlignment.Center, Cursor = Cursors.Arrow,
            ContextMenu = null, IsUndoEnabled = false,
        };
        InputMethod.SetIsInputMethodEnabled(field, false);
        System.Windows.Automation.AutomationProperties.SetName(field, "Shortcut");
        field.PreviewKeyDown += Record;
        // Modifiers let go with no key: back to what was there.
        field.PreviewKeyUp += (_, _) => { if (Keyboard.Modifiers == ModifierKeys.None) Show(); };
        field.GotKeyboardFocus += (_, _) => Shortcut.Pause();
        field.LostKeyboardFocus += (_, _) => Shortcut.Resume();
        panel.Children.Add(field);
        message = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), MinHeight = 16 };
        panel.Children.Add(message);
        var reset = new Button { Content = "Reset to default", Padding = new Thickness(10, 2, 10, 2), MinHeight = 24, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        reset.Click += (_, _) => { picked = null; useDefault = true; problem = null; Show(); Changed?.Invoke(); };
        panel.Children.Add(reset);
        Content = panel;
        Loaded += (_, _) => Show();
        Unloaded += (_, _) => Shortcut.Resume();
    }

    /// Whether Save has something it can save.
    public bool CanSave => problem == null && (useDefault || picked != null);

    /// Saves the pick. False (and says why) when it can't be used.
    public bool Save()
    {
        if (useDefault) return Shortcut.Use(null);
        if (picked is not Combo c) return true;
        Shortcut.Pause();
        problem = Shortcut.Problem(c);
        if (problem == null && Shortcut.Use(c)) return true;
        problem ??= "Another app is using this shortcut";
        Show();
        Changed?.Invoke();
        return false;
    }

    public void FocusField() => field.Focus();

    void Record(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key == Key.ImeProcessed ? e.ImeProcessedKey : e.Key;
        var mods = Keyboard.Modifiers;
        // Tab and Esc on their own keep their usual jobs: the next control, Cancel.
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
            message.Text = "";
            Changed?.Invoke();
            return;
        }
        var vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (vk == 0) return;
        var c = new Combo(m, vk);
        picked = c;
        useDefault = false;
        problem = Shortcut.Problem(c);
        Show();
        Changed?.Invoke();
    }

    void Show()
    {
        var c = useDefault ? Shortcut.Default : picked ?? Shortcut.Current;
        field.Text = c.Name;
        if (problem != null) { message.Text = problem; message.Foreground = ErrorBrush; }
        else if (useDefault) { message.Text = $"The default, {Shortcut.Default.Name}, for the keyboards you have."; message.Foreground = SystemColors.GrayTextBrush; }
        else if (picked == null && !Shortcut.Registered) { message.Text = "Another app is using this shortcut"; message.Foreground = ErrorBrush; }
        else message.Text = "";
    }

    static readonly Brush ErrorBrush = Frozen(Color.FromRgb(0xC4, 0x2B, 0x1C));
    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
}

/// The "Keyboard shortcut" window, from the tray menu or when the shortcut is taken. A normal
/// window that takes the focus, unlike the card.
sealed class ShortcutWindow : Window
{
    static ShortcutWindow? open;

    public static void Open()
    {
        if (open != null) { open.Activate(); return; }
        open = new ShortcutWindow();
        open.Closed += (_, _) => open = null;
        open.Show();
        open.Activate();
    }

    ShortcutWindow()
    {
        Title = "Keyboard shortcut";
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Background = SystemColors.WindowBrush;
        FontFamily = SystemFonts.MessageFontFamily;
        FontSize = 12;
        var icon = System.IO.Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        if (System.IO.File.Exists(icon)) Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(icon));

        var picker = new ShortcutPicker { Margin = new Thickness(20, 16, 20, 16), Width = 340 };
        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 80, MinHeight = 24, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80, MinHeight = 24 };
        save.IsEnabled = picker.CanSave;
        picker.Changed += () => save.IsEnabled = picker.CanSave;
        save.Click += (_, _) => { if (picker.Save()) Close(); };
        // Windows dialogs keep their buttons on a grey band along the bottom, right aligned.
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { save, cancel } };
        var band = new Border { Background = SystemColors.ControlBrush, Padding = new Thickness(20, 12, 20, 12), Child = buttons };
        var root = new DockPanel();
        DockPanel.SetDock(band, Dock.Bottom);
        root.Children.Add(band);
        root.Children.Add(picker);
        Content = root;
        Loaded += (_, _) => picker.FocusField();
    }
}
