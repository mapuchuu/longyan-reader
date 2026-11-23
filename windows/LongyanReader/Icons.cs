using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace Longyan;

/// The card's symbols, drawn for Windows: SF Symbols are licensed for Apple platforms only, so
/// these are our own shapes with the same idea, size and weight as the Mac card's. Each is a
/// filled outline in the box (points) the Mac's symbol takes at the size the card uses it, so
/// it sits where the Mac's does. Made from circles, rounded boxes and strokes, widened into
/// outlines here, so one brush colours them and they scale with the card.
sealed record Icon(double Width, double Height, Geometry Geometry)
{
    /// The icon as a shape in `brush`, `Width` by `Height`.
    public System.Windows.Shapes.Path Shape(Brush brush) => new()
    {
        Data = Geometry, Fill = brush, Width = Width, Height = Height, Stretch = Stretch.None,
        RenderTransformOrigin = new Point(0.5, 0.5), SnapsToDevicePixels = false,
    };
}

static class Icons
{
    static Geometry G(string data) => Geometry.Parse(data);

    /// A line `width` wide along `data`, as an outline.
    static Geometry S(string data, double width, PenLineCap cap) =>
        Geometry.Parse(data).GetWidenedPathGeometry(new Pen(Brushes.Black, width) { StartLineCap = cap, EndLineCap = cap, LineJoin = PenLineJoin.Round }, 0.01, ToleranceType.Absolute);

    static Geometry U(params Geometry[] parts) =>
        parts.Skip(1).Aggregate(parts[0], (all, p) => Geometry.Combine(all, p, GeometryCombineMode.Union, null));

    /// Cultural context (globe.asia.australia.fill): a ring, Asia and Australia filled, the sea open.
    public static readonly Icon Globe = new(13.12, 13.12, U(Geometry.Combine(new EllipseGeometry(new Point(6.56, 6.56), 5.62, 5.62), new EllipseGeometry(new Point(6.56, 6.56), 4.62, 4.62), GeometryCombineMode.Exclude, null), Geometry.Combine(U(G("M -1,-1 H 9.3 L 9.3,2.2 C 9.3,3.0 8.8,3.8 8.0,4.2 C 7.5,4.4 7.0,4.3 6.8,4.7 C 6.6,5.2 7.4,5.4 7.1,6.1 C 6.8,6.7 6.1,6.7 5.8,7.2 C 5.6,7.6 5.7,8.3 5.2,8.6 C 4.8,8.7 4.6,8.2 4.4,7.8 C 4.2,7.3 3.8,7.1 3.4,7.3 C 3.0,7.5 2.9,8.3 2.5,8.8 C 2.2,9.2 1.8,9.4 1.5,9.5 L -1,10.5 Z"), S("M 10.0,4.0 C 9.8,4.7 9.4,5.2 8.7,5.5", 0.75, PenLineCap.Round), U(S("M 3.6,9.6 L 4.6,9.9", 0.7, PenLineCap.Round), new EllipseGeometry(new Point(6.35, 8.5), 0.45, 0.52)), G("M 6.9,10.8 C 6.5,9.9 6.8,9.1 7.7,8.8 C 8.3,8.7 8.6,8.2 9.3,8.1 C 10.0,8.0 10.4,8.4 10.8,8.3 L 12.5,7.6 L 12.5,9.4 C 11.6,9.9 10.9,10.4 10.2,10.8 C 9.5,11.1 8.8,10.8 8.2,11.1 C 7.6,11.3 7.1,11.2 6.9,10.8 Z")), new EllipseGeometry(new Point(6.56, 6.56), 4.7700000000000005, 4.7700000000000005), GeometryCombineMode.Intersect, null)));
    /// Part of, and a phrase row that opens (chevron.forward).
    public static readonly Icon ChevronForward = new(7.56, 10.56, S("M 2.55,1.55 L 6.33,5.29 L 2.55,9.02", 1.35, PenLineCap.Round));
    /// Show All (chevron.down).
    public static readonly Icon ChevronDown = new(11.31, 6.88, S("M 1.93,1.55 L 5.65,5.33 L 9.38,1.55", 1.35, PenLineCap.Round));
    /// The chosen meaning, and Copied (checkmark).
    public static readonly Icon Checkmark = new(13.56, 12.44, S("M 2.4,6.9 L 5.3,10.4 L 11.2,1.95", 1.75, PenLineCap.Round));
    /// A pinned card's close badge (xmark).
    public static readonly Icon Xmark = new(8.5, 8, S("M 1.65,1.4 L 6.85,6.6 M 6.85,1.4 L 1.65,6.6", 1.3, PenLineCap.Round));
    /// Back to the suggested meaning (arrow.uturn.backward).
    public static readonly Icon UturnBack = new(14.12, 12.56, S("M 5.0,1.41 L 2.1,4.3 L 5.0,7.19 M 2.1,4.3 H 8.6 A 3.42,3.42 0 0 1 8.6,11.15 H 7.0", 1.2, PenLineCap.Round));
    /// A meaning with a note (text.bubble).
    public static readonly Icon Bubble = new(14.62, 12.62, U(S("M 3.88,1.25 H 10.75 A 2,2 0 0 1 12.75,3.25 V 6.9 A 2,2 0 0 1 10.75,8.9 H 6.2 L 3.9,11.3 V 8.9 H 3.88 A 2,2 0 0 1 1.88,6.9 V 3.25 A 2,2 0 0 1 3.88,1.25 Z", 1.0, PenLineCap.Round), S("M 4.4,3.6 H 10.2 M 4.4,5.1 H 10.2 M 4.4,6.6 H 8.4", 0.85, PenLineCap.Round)));
    /// Listen (speaker.wave.2).
    public static readonly Icon Speaker = new(17.25, 12.62, U(SpeakerBody, SpeakerWave1, SpeakerWave2));
    /// Its parts, so the waves can light in turn while it speaks: the speaker, the inner wave, the outer wave.
    public static Geometry SpeakerBody => speakerBody ??= S("M 2.4,4.3 H 4.4 L 7.2,1.65 V 10.97 L 4.4,8.3 H 2.4 Z", 1.15, PenLineCap.Round);
    public static Geometry SpeakerWave1 => speakerWave1 ??= S("M 9.8,4.3 A 2.37,2.37 0 0 1 9.8,8.3", 1.15, PenLineCap.Round);
    public static Geometry SpeakerWave2 => speakerWave2 ??= S("M 12.9,2.3 A 5.16,5.16 0 0 1 12.9,10.3", 1.15, PenLineCap.Round);
    static Geometry? speakerBody, speakerWave1, speakerWave2;
    /// Copy (doc.on.doc): two pages with a folded corner.
    public static readonly Icon Copy = new(15.19, 17.06, S("M 3.25,5.0 H 7.3 L 10.0,7.7 V 14.25 A 1.2,1.2 0 0 1 8.8,15.45 H 3.25 A 1.2,1.2 0 0 1 2.05,14.25 V 6.2 A 1.2,1.2 0 0 1 3.25,5.0 Z M 7.3,5.15 V 7.7 H 9.85 M 5.2,4.6 V 2.8 A 1.2,1.2 0 0 1 6.4,1.6 H 10.4 L 13.14,4.35 V 10.3 A 1.2,1.2 0 0 1 11.94,11.5 H 10.6 M 10.4,1.75 V 4.35 H 13.0", 1.1, PenLineCap.Round));
    /// Pin (pin).
    public static readonly Icon Pin = new(13.94, 16.06, U(S("M 5.6,1.65 C 5.6,2.5 5.75,3.3 5.75,4.1 V 6.3 C 4.0,6.9 2.9,7.9 2.9,9.2 H 11.0 C 11.0,7.9 9.9,6.9 8.15,6.3 V 4.1 C 8.15,3.3 8.3,2.5 8.3,1.65 Z", 1.15, PenLineCap.Round), S("M 3.9,1.65 H 10.0 M 6.95,9.2 V 14.4", 1.15, PenLineCap.Round)));
    /// Pinned (pin.fill).
    public static readonly Icon PinFill = new(13.94, 16.06, U(G("M 5.6,1.65 C 5.6,2.5 5.75,3.3 5.75,4.1 V 6.3 C 4.0,6.9 2.9,7.9 2.9,9.2 H 11.0 C 11.0,7.9 9.9,6.9 8.15,6.3 V 4.1 C 8.15,3.3 8.3,2.5 8.3,1.65 Z"), S("M 5.6,1.65 C 5.6,2.5 5.75,3.3 5.75,4.1 V 6.3 C 4.0,6.9 2.9,7.9 2.9,9.2 H 11.0 C 11.0,7.9 9.9,6.9 8.15,6.3 V 4.1 C 8.15,3.3 8.3,2.5 8.3,1.65 Z", 1.15, PenLineCap.Round), S("M 3.9,1.65 H 10.0 M 6.95,9.2 V 14.4", 1.15, PenLineCap.Round)));
    /// Lost in translation (translate): a bubble with an A behind a filled one with 文.
    public static readonly Icon Translate = new(20.25, 14.44, U(Geometry.Combine(U(S("M 3.88,1.44 H 9.4 A 2,2 0 0 1 11.4,3.44 V 6.4 A 2,2 0 0 1 9.4,8.4 H 6.1 L 3.7,10.6 V 8.4 A 2,2 0 0 1 1.88,6.4 V 3.44 A 2,2 0 0 1 3.88,1.44 Z", 1.0, PenLineCap.Round), S("M 4.0,7.0 L 5.4,3.1 L 6.8,7.0 M 4.5,5.75 H 6.3", 0.95, PenLineCap.Round)), S("M 10.4,4.2 H 16.31 A 2,2 0 0 1 18.31,6.2 V 9.0 A 2,2 0 0 1 16.31,11.0 H 16.3 V 13.1 L 14.0,11.0 H 10.4 A 2,2 0 0 1 8.4,9.0 V 6.2 A 2,2 0 0 1 10.4,4.2 Z", 2.4, PenLineCap.Round), GeometryCombineMode.Exclude, null), Geometry.Combine(U(G("M 10.4,4.2 H 16.31 A 2,2 0 0 1 18.31,6.2 V 9.0 A 2,2 0 0 1 16.31,11.0 H 16.3 V 13.1 L 14.0,11.0 H 10.4 A 2,2 0 0 1 8.4,9.0 V 6.2 A 2,2 0 0 1 10.4,4.2 Z"), S("M 10.4,4.2 H 16.31 A 2,2 0 0 1 18.31,6.2 V 9.0 A 2,2 0 0 1 16.31,11.0 H 16.3 V 13.1 L 14.0,11.0 H 10.4 A 2,2 0 0 1 8.4,9.0 V 6.2 A 2,2 0 0 1 10.4,4.2 Z", 0.5, PenLineCap.Round)), S("M 13.2,5.15 L 13.5,5.8 M 11.05,6.55 H 15.75 M 11.85,6.6 C 12.4,8.55 13.6,9.65 15.65,10.05 M 14.95,6.6 C 14.4,8.55 13.2,9.65 11.15,10.05", 0.9, PenLineCap.Round), GeometryCombineMode.Exclude, null)));
    /// In Anki (checkmark.rectangle.stack).
    public static readonly Icon AnkiAdded = new(15.44, 16.38, U(S("M 3.63,5.25 H 11.81 A 1.6,1.6 0 0 1 13.41,6.85 V 12.25 A 1.6,1.6 0 0 1 11.81,13.85 H 3.63 A 1.6,1.6 0 0 1 2.03,12.25 V 6.85 A 1.6,1.6 0 0 1 3.63,5.25 Z", 1.05, PenLineCap.Round), U(G("M 3.65,3.3 H 11.8 A 0.47,0.47 0 0 1 11.8,4.25 H 3.65 A 0.47,0.47 0 0 1 3.65,3.3 Z"), G("M 4.85,1.06 H 10.6 A 0.45,0.45 0 0 1 10.6,1.96 H 4.85 A 0.45,0.45 0 0 1 4.85,1.06 Z")), S("M 5.7,9.7 L 7.05,11.3 L 9.9,7.4", 1.0, PenLineCap.Round)));
    /// Add to Anki (rectangle.stack.badge.plus).
    public static readonly Icon AnkiAdd = new(15.44, 17.06, U(Geometry.Combine(S("M 3.63,5.25 H 11.81 A 1.6,1.6 0 0 1 13.41,6.85 V 12.25 A 1.6,1.6 0 0 1 11.81,13.85 H 3.63 A 1.6,1.6 0 0 1 2.03,12.25 V 6.85 A 1.6,1.6 0 0 1 3.63,5.25 Z", 1.05, PenLineCap.Round), new EllipseGeometry(new Point(2.0, 12.9), 3.75, 3.75), GeometryCombineMode.Exclude, null), U(G("M 3.65,3.3 H 11.8 A 0.47,0.47 0 0 1 11.8,4.25 H 3.65 A 0.47,0.47 0 0 1 3.65,3.3 Z"), G("M 4.85,1.06 H 10.6 A 0.45,0.45 0 0 1 10.6,1.96 H 4.85 A 0.45,0.45 0 0 1 4.85,1.06 Z")), Geometry.Combine(new EllipseGeometry(new Point(2.0, 12.9), 2.85, 2.85), S("M 0.65,12.9 H 3.35 M 2.0,11.55 V 14.25", 0.8, PenLineCap.Round), GeometryCombineMode.Exclude, null)));
    /// Anki didn't answer (exclamationmark.triangle).
    public static readonly Icon Warning = new(14.81, 13.38, U(S("M 6.55,2.3 A 0.95,0.95 0 0 1 8.2,2.3 L 12.85,10.6 A 0.95,0.95 0 0 1 12.0,12.0 H 2.75 A 0.95,0.95 0 0 1 1.9,10.6 Z", 1.05, PenLineCap.Round), S("M 7.38,5.0 V 8.2", 1.15, PenLineCap.Round), new EllipseGeometry(new Point(7.38, 10.05), 0.68, 0.68)));
}
