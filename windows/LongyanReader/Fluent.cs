using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Longyan;

/// Windows 11's look for the windows around the card (welcome, settings): its colours for
/// light and dark, the system accent, Segoe UI Variable, and its buttons, toggle switches,
/// text boxes and setting cards. The card itself keeps the Mac's look (Theme).
sealed class Fluent
{
    public readonly bool Dark;
    public readonly Color Background, Footer, Card, CardStroke, Text, TextSecondary, TextDisabled,
        ControlFill, ControlHover, ControlPressed, ControlStroke, InputFocused, StrongStroke,
        ToggleOffFill, ToggleOffHover, Divider, Accent, AccentText, OnAccent, Error;

    public static readonly FontFamily Font = new(WindowsBuild.Fonts("Segoe UI Variable Text, Segoe UI", "Segoe UI"));
    public static readonly FontFamily DisplayFont = new(WindowsBuild.Fonts("Segoe UI Variable Display, Segoe UI", "Segoe UI"));
    public static readonly FontFamily ChineseFont = new("Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI");

    /// As Windows is set now (the card's Theme.Dark is read once, at launch).
    public static Fluent Now() => new(SystemDark());

    public Fluent(bool dark)
    {
        Dark = dark;
        var (accentFill, accentText) = AccentColors(dark);
        Accent = accentFill;
        AccentText = accentText;
        if (dark)
        {
            Background = Rgb(0x202020); Footer = Rgb(0x1C1C1C);
            Card = Rgb(0x2B2B2B); CardStroke = Rgb(0x1D1D1D);
            Text = Rgb(0xFFFFFF); TextSecondary = White(0.786); TextDisabled = White(0.363);
            ControlFill = White(0.061); ControlHover = White(0.084); ControlPressed = White(0.033);
            ControlStroke = White(0.07); InputFocused = Rgb(0x1F1F1F); StrongStroke = White(0.544);
            ToggleOffFill = Black(0.1); ToggleOffHover = White(0.042); Divider = White(0.084);
            OnAccent = Rgb(0x000000); Error = Rgb(0xFF99A4);
        }
        else
        {
            Background = Rgb(0xF3F3F3); Footer = Rgb(0xEEEEEE);
            Card = Rgb(0xFBFBFB); CardStroke = Rgb(0xE5E5E5);
            Text = Black(0.896); TextSecondary = Black(0.606); TextDisabled = Black(0.361);
            ControlFill = White(0.7); ControlHover = Argb(0x80F9F9F9); ControlPressed = Argb(0x4DF9F9F9);
            ControlStroke = Black(0.09); InputFocused = Rgb(0xFFFFFF); StrongStroke = Black(0.446);
            ToggleOffFill = Black(0.024); ToggleOffHover = Black(0.056); Divider = Black(0.08);
            OnAccent = Rgb(0xFFFFFF); Error = Rgb(0xC42B1C);
        }
    }

    public Brush B(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    public static bool SystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    /// The accent as Windows 11 uses it for controls and links: a darker shade on light, a
    /// lighter one on dark, from the system's accent palette (Windows' blue when there's none).
    static (Color Fill, Color Text) AccentColors(bool dark)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Accent");
            if (key?.GetValue("AccentPalette") is byte[] p && p.Length >= 32)
            {
                Color At(int i) => Color.FromRgb(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]);
                // Light 3, 2, 1, the accent, dark 1, 2, 3.
                return dark ? (At(1), At(0)) : (At(4), At(5));
            }
        }
        catch { }
        return dark ? (Rgb(0x60CDFF), Rgb(0x99EBFF)) : (Rgb(0x005FB8), Rgb(0x003E92));
    }

    static Color Rgb(int rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    static Color Argb(uint argb) => Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);
    static Color White(double a) => Color.FromArgb((byte)Math.Round(a * 255), 255, 255, 255);
    static Color Black(double a) => Color.FromArgb((byte)Math.Round(a * 255), 0, 0, 0);
    static string H(Color c) => $"#{c.A:X2}{c.R:X2}{c.G:X2}{c.B:X2}";
    static Color Fade(Color c, double a) => Color.FromArgb((byte)Math.Round(c.A * a), c.R, c.G, c.B);

    // MARK: Styles

    /// Implicit styles for the window: buttons ("Accent" for the main one), toggle switches,
    /// text boxes, progress bars, scroll bars and links.
    public ResourceDictionary Styles()
    {
        var xaml = $$$"""
            <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                                xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
              <Style x:Key="Focus">
                <Setter Property="Control.Template"><Setter.Value><ControlTemplate>
                  <Border Margin="-3" CornerRadius="7" BorderThickness="2" BorderBrush="{{{H(Text)}}}"/>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="Button">
                <Setter Property="Foreground" Value="{{{H(Text)}}}"/>
                <Setter Property="Background" Value="{{{H(ControlFill)}}}"/>
                <Setter Property="BorderBrush" Value="{{{H(ControlStroke)}}}"/>
                <Setter Property="Padding" Value="11,5,11,6"/>
                <Setter Property="MinHeight" Value="32"/>
                <Setter Property="MinWidth" Value="80"/>
                <Setter Property="FontSize" Value="14"/>
                <Setter Property="FocusVisualStyle" Value="{StaticResource Focus}"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                  <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" SnapsToDevicePixels="True">
                    <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{{{H(ControlHover)}}}"/></Trigger>
                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="{{{H(ControlPressed)}}}"/><Setter Property="Foreground" Value="{{{H(TextSecondary)}}}"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{{{H(TextDisabled)}}}"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
                <Setter Property="Foreground" Value="{{{H(OnAccent)}}}"/>
                <Setter Property="Background" Value="{{{H(Accent)}}}"/>
                <Setter Property="BorderBrush" Value="{{{H(Accent)}}}"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                  <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}" BorderThickness="0" SnapsToDevicePixels="True">
                    <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{{{H(Fade(Accent, 0.9))}}}"/></Trigger>
                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="{{{H(Fade(Accent, 0.8))}}}"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Background" Value="{{{H(TextDisabled)}}}"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ToggleButton">
                <Setter Property="Foreground" Value="{{{H(Text)}}}"/>
                <Setter Property="FontSize" Value="14"/>
                <Setter Property="FocusVisualStyle" Value="{StaticResource Focus}"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
                  <Grid Background="Transparent">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="label" Text="Off" VerticalAlignment="Center" Margin="0,0,12,1" Foreground="{TemplateBinding Foreground}"/>
                    <Border x:Name="track" Grid.Column="1" Width="40" Height="20" CornerRadius="10" BorderThickness="1" BorderBrush="{{{H(StrongStroke)}}}" Background="{{{H(ToggleOffFill)}}}" SnapsToDevicePixels="True">
                      <Ellipse x:Name="knob" Width="12" Height="12" Fill="{{{H(TextSecondary)}}}" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,0,0"/>
                    </Border>
                  </Grid>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="track" Property="Background" Value="{{{H(ToggleOffHover)}}}"/>
                      <Setter TargetName="knob" Property="Width" Value="14"/><Setter TargetName="knob" Property="Height" Value="14"/>
                      <Setter TargetName="knob" Property="Margin" Value="2,0,2,0"/>
                    </Trigger>
                    <Trigger Property="IsChecked" Value="True">
                      <Setter TargetName="label" Property="Text" Value="On"/>
                      <Setter TargetName="track" Property="Background" Value="{{{H(Accent)}}}"/>
                      <Setter TargetName="track" Property="BorderBrush" Value="{{{H(Accent)}}}"/>
                      <Setter TargetName="knob" Property="Fill" Value="{{{H(OnAccent)}}}"/>
                      <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                      <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
                    </Trigger>
                    <MultiTrigger>
                      <MultiTrigger.Conditions><Condition Property="IsChecked" Value="True"/><Condition Property="IsMouseOver" Value="True"/></MultiTrigger.Conditions>
                      <Setter TargetName="track" Property="Background" Value="{{{H(Fade(Accent, 0.9))}}}"/>
                      <Setter TargetName="knob" Property="Margin" Value="0,0,2,0"/>
                    </MultiTrigger>
                    <Trigger Property="Tag" Value="bare"><Setter TargetName="label" Property="Visibility" Value="Collapsed"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False">
                      <Setter TargetName="label" Property="Foreground" Value="{{{H(TextDisabled)}}}"/>
                      <Setter TargetName="track" Property="BorderBrush" Value="{{{H(TextDisabled)}}}"/>
                      <Setter TargetName="knob" Property="Fill" Value="{{{H(TextDisabled)}}}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="TextBox">
                <Setter Property="Foreground" Value="{{{H(Text)}}}"/>
                <Setter Property="Background" Value="{{{H(ControlFill)}}}"/>
                <Setter Property="BorderBrush" Value="{{{H(ControlStroke)}}}"/>
                <Setter Property="CaretBrush" Value="{{{H(Text)}}}"/>
                <Setter Property="SelectionBrush" Value="{{{H(Accent)}}}"/>
                <Setter Property="FontSize" Value="14"/>
                <Setter Property="Padding" Value="10,0,10,1"/>
                <Setter Property="MinHeight" Value="32"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
                  <Grid>
                    <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" SnapsToDevicePixels="True"/>
                    <Border x:Name="u" Height="1" VerticalAlignment="Bottom" Margin="1,0,1,0" Background="{{{H(StrongStroke)}}}" SnapsToDevicePixels="True"/>
                    <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Focusable="False"/>
                  </Grid>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{{{H(ControlHover)}}}"/></Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                      <Setter TargetName="b" Property="Background" Value="{{{H(InputFocused)}}}"/>
                      <Setter TargetName="u" Property="Height" Value="2"/>
                      <Setter TargetName="u" Property="Background" Value="{{{H(Accent)}}}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ProgressBar">
                <Setter Property="Height" Value="3"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
                  <Grid>
                    <Border x:Name="PART_Track" Height="1" VerticalAlignment="Center" Background="{{{H(StrongStroke)}}}"/>
                    <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="1.5" Background="{{{H(Accent)}}}"/>
                  </Grid>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ScrollBar">
                <Setter Property="Width" Value="12"/>
                <Setter Property="MinWidth" Value="12"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
                  <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
                    <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                      <Border Width="4" CornerRadius="2" Margin="0,2,0,2" Background="{{{H(TextSecondary)}}}" Opacity="0.7"/>
                    </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                  </Track>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="Hyperlink">
                <Setter Property="Foreground" Value="{{{H(AccentText)}}}"/>
                <Setter Property="TextDecorations" Value="{x:Null}"/>
                <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="TextDecorations" Value="Underline"/></Trigger></Style.Triggers>
              </Style>
            </ResourceDictionary>
            """;
        return (ResourceDictionary)XamlReader.Parse(xaml);
    }

    // MARK: Pieces

    /// A group's heading above its cards, as in Windows Settings.
    public TextBlock Heading(string text, bool first = false) => new()
    {
        Text = text, FontFamily = Font, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = B(Text),
        Margin = new Thickness(1, first ? 0 : 26, 0, 8),
    };

    /// The frame of a setting card.
    public Border CardFrame(UIElement child, Thickness? padding = null) => new()
    {
        Background = B(Card), BorderBrush = B(CardStroke), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
        Padding = padding ?? new Thickness(16, 12, 16, 12), Margin = new Thickness(0, 0, 0, 4), Child = child, SnapsToDevicePixels = true,
    };

    /// A setting's row: an icon, its name and a short description, and its control on the right.
    public Grid Row(string? glyph, string title, object? description, UIElement? control, double minHeight = 44)
    {
        var grid = new Grid { MinHeight = minHeight };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (glyph != null)
            grid.Children.Add(new TextBlock
            {
                Text = glyph, FontFamily = Theme.Icons, FontSize = 16, Foreground = B(Text), Width = 20,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0),
            });
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        words.Children.Add(new TextBlock { Text = title, FontFamily = Font, FontSize = 14, Foreground = B(Text), TextWrapping = TextWrapping.Wrap });
        if (description is string d) words.Children.Add(Caption(d));
        else if (description is UIElement e) words.Children.Add(e);
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        if (control != null)
        {
            if (control is FrameworkElement f) f.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(control, 2);
            grid.Children.Add(control);
        }
        return grid;
    }

    public TextBlock Caption(string text) => new()
    {
        Text = text, FontFamily = Font, FontSize = 12, Foreground = B(TextSecondary), TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 1, 0, 0),
    };

    public TextBlock Body(string text, double size = 14) => new()
    {
        Text = text, FontFamily = Font, FontSize = size, Foreground = B(Text), TextWrapping = TextWrapping.Wrap,
    };

    public Border Line() => new() { Height = 1, Background = B(Divider), SnapsToDevicePixels = true };

    public ToggleButton Switch(string name, string automationId, bool on)
    {
        var t = new ToggleButton { IsChecked = on };
        System.Windows.Automation.AutomationProperties.SetName(t, name);
        System.Windows.Automation.AutomationProperties.SetAutomationId(t, automationId);
        return t;
    }

    public Button PushButton(string text, Action click, bool accent = false, string? automationId = null)
    {
        var b = new Button { Content = text };
        if (accent) b.SetResourceReference(FrameworkElement.StyleProperty, "Accent");
        if (automationId != null) System.Windows.Automation.AutomationProperties.SetAutomationId(b, automationId);
        b.Click += (_, _) => click();
        return b;
    }

    /// The app's mark (a black shape), drawn in the text colour.
    public FrameworkElement Mark(double size)
    {
        var image = new BitmapImage();
        using (var stream = typeof(Fluent).Assembly.GetManifestResourceStream("longyan-mark.png"))
        {
            image.BeginInit();
            image.StreamSource = stream;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
        }
        image.Freeze();
        return new System.Windows.Shapes.Rectangle
        {
            Width = size, Height = size, Fill = B(Text),
            OpacityMask = new ImageBrush(image) { Stretch = Stretch.Uniform },
        };
    }

    // MARK: Windows

    /// A window in this look: the background, fonts and styles, the app's icon, and a title
    /// bar that matches (dark in dark mode, the background's colour on Windows 11; Windows 10
    /// has no caption colour, so there it's Windows 10's own white or dark).
    public void Dress(Window w)
    {
        w.Background = B(Background);
        w.Foreground = B(Text);
        w.FontFamily = Font;
        w.FontSize = 14;
        w.Resources = Styles();
        TextOptions.SetTextFormattingMode(w, TextFormattingMode.Display);
        var icon = System.IO.Path.Combine(Core.AppDirectory, "LongyanReader.ico");
        if (w.Icon == null && System.IO.File.Exists(icon)) w.Icon = BitmapFrame.Create(new Uri(icon));
        if (new WindowInteropHelper(w).Handle is var h && h != IntPtr.Zero) TitleBar(h);
        else w.SourceInitialized += (_, _) => TitleBar(new WindowInteropHelper(w).Handle);
    }

    void TitleBar(IntPtr hwnd)
    {
        WindowsBuild.DarkTitleBar(hwnd, Dark);
        // Windows 10 has no caption colour: its title bar stays white, or dark in dark mode.
        if (!WindowsBuild.HasCaptionColor) return;
        try
        {
            var caption = Background.R | Background.G << 8 | Background.B << 16;
            DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref caption, 4);
        }
        catch { }
    }

    const int DWMWA_CAPTION_COLOR = 35;
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// Draws `content` at `width` (and its own height) to a PNG at twice the size, on the
    /// window's background: for --render-windows.
    public static void RenderToFile(FrameworkElement content, Fluent look, double width, string path)
    {
        var host = new Border { Background = look.B(look.Background), Child = content, Width = width };
        host.Resources = look.Styles();
        TextOptions.SetTextFormattingMode(host, TextFormattingMode.Ideal);
        TextElement.SetFontFamily(host, Font);
        TextElement.SetFontSize(host, 14);
        TextElement.SetForeground(host, look.B(look.Text));
        host.Measure(new Size(width, double.PositiveInfinity));
        host.Arrange(new Rect(new Point(0, 0), host.DesiredSize));
        host.UpdateLayout();
        var scale = 2.0;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(host.ActualWidth * scale), (int)Math.Ceiling(host.ActualHeight * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(host);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = System.IO.File.Create(path);
        png.Save(file);
    }
}
