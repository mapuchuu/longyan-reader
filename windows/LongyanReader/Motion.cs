using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Longyan;

/// The Mac card's motion (notes/card-spec.md, section 6): SwiftUI springs as WPF easing.
static class Motion
{
    /// cardMotion: a spring with response 0.34 s and no overshoot, done in about 0.5 s.
    public static readonly Duration CardDuration = new(TimeSpan.FromSeconds(0.5));
    public static readonly IEasingFunction Card = new Spring(0.34, 1.0, 0.5);

    /// The card's appearance: response 0.32 s, damping 0.82, a little overshoot, about 0.45 s.
    public static readonly Duration RevealDuration = new(TimeSpan.FromSeconds(0.45));
    public static readonly IEasingFunction Reveal = new Spring(0.32, 0.82, 0.45);

    /// The pinned card's close badge: response 0.25 s, damping 0.9.
    public static readonly Duration BadgeDuration = new(TimeSpan.FromSeconds(0.35));
    public static readonly IEasingFunction Badge = new Spring(0.25, 0.9, 0.35);

    /// The eye (Chip.swift:212-228): in with response 0.3, damping 0.68; hover 0.25, 0.7; press 0.2, 0.7.
    /// Each runs until what's left of the spring is under 0.1% of the move (e^-ζωt < 0.001).
    public const double EyeAppearSeconds = 0.6, EyeHoverSeconds = 0.5, EyePressSeconds = 0.4;
    public static readonly IEasingFunction EyeAppear = new Spring(0.3, 0.68, EyeAppearSeconds);
    public static readonly IEasingFunction EyeHover = new Spring(0.25, 0.7, EyeHoverSeconds);
    public static readonly IEasingFunction EyePress = new Spring(0.2, 0.7, EyePressSeconds);

    /// SwiftUI's .easeOut and .easeInOut are Core Animation's curves, cubic Béziers (0, 0, 0.58, 1)
    /// and (0.42, 0, 0.58, 1). WPF's CubicEase is far steeper at the start (0.875 of the way at
    /// half time, against 0.69), so hovers and fades snapped on rather than eased.
    public static readonly IEasingFunction EaseOut = new Bezier(0, 0, 0.58, 1);

    /// How the content moves when it changes: cardMotion, or easeInOut 0.15 s with Reduce Motion
    /// (the Mac keeps content transitions then, just short and without slides).
    public static Duration ContentDuration => Reduced ? new Duration(TimeSpan.FromSeconds(0.15)) : CardDuration;
    public static IEasingFunction ContentEase => Reduced ? EaseInOut : Card;
    static readonly IEasingFunction EaseInOut = new Bezier(0.42, 0, 0.58, 1);

    /// True when Windows' "Animation effects" are off (Reduce Motion on the Mac).
    public static bool Reduced => !SystemParameters.ClientAreaAnimation;

    public static void Animate(UIElement e, DependencyProperty p, double from, double to, Duration? duration = null, IEasingFunction? easing = null)
    {
        var a = new DoubleAnimation(from, to, duration ?? CardDuration) { EasingFunction = easing ?? Card };
        e.BeginAnimation(p, a);
    }

    public static void Animate(Animatable e, DependencyProperty p, double from, double to, Duration? duration = null, IEasingFunction? easing = null)
    {
        var a = new DoubleAnimation(from, to, duration ?? CardDuration) { EasingFunction = easing ?? Card };
        e.BeginAnimation(p, a);
    }

    /// Fades an element in with cardMotion, optionally sliding down from `fromY` above.
    public static void FadeIn(UIElement e, double fromY = 0)
    {
        Animate(e, UIElement.OpacityProperty, 0, 1, ContentDuration, ContentEase);
        if (fromY != 0 && !Reduced)
        {
            var t = new TranslateTransform(0, fromY);
            e.RenderTransform = t;
            Animate(t, TranslateTransform.YProperty, fromY, 0);
        }
    }

    /// Ease-out to `to` over `seconds`, from wherever the value is now.
    public static void To(Animatable e, DependencyProperty p, double to, double seconds)
    {
        e.BeginAnimation(p, new DoubleAnimation(to, new Duration(TimeSpan.FromSeconds(seconds))) { EasingFunction = EaseOut });
    }

    public static void To(UIElement e, DependencyProperty p, double to, double seconds)
    {
        e.BeginAnimation(p, new DoubleAnimation(to, new Duration(TimeSpan.FromSeconds(seconds))) { EasingFunction = EaseOut });
    }

    /// A CSS-style cubic Bézier timing curve from (0, 0) to (1, 1).
    sealed class Bezier : EasingFunctionBase
    {
        readonly double x1, y1, x2, y2;
        public Bezier(double x1, double y1, double x2, double y2)
        {
            this.x1 = x1; this.y1 = y1; this.x2 = x2; this.y2 = y2;
            EasingMode = EasingMode.EaseIn;
        }

        static double Curve(double a, double b, double t) => 3 * a * (1 - t) * (1 - t) * t + 3 * b * (1 - t) * t * t + t * t * t;

        protected override double EaseInCore(double x)
        {
            if (x <= 0) return 0;
            if (x >= 1) return 1;
            // The curve's parameter for this x, by bisection (x rises monotonically with it).
            double lo = 0, hi = 1, t = x;
            for (var i = 0; i < 30; i++)
            {
                t = (lo + hi) / 2;
                if (Curve(x1, x2, t) < x) lo = t; else hi = t;
            }
            return Curve(y1, y2, t);
        }

        protected override Freezable CreateInstanceCore() => new Bezier(x1, y1, x2, y2);
    }

    /// A damped spring's progress (SwiftUI's model: mass 1, stiffness (2π/response)²), over a
    /// fixed duration, ending exactly at 1.
    sealed class Spring : EasingFunctionBase
    {
        readonly double response, damping, seconds;
        public Spring(double response, double damping, double seconds)
        {
            this.response = response; this.damping = damping; this.seconds = seconds;
            EasingMode = EasingMode.EaseIn;   // EaseInCore is the curve as given
        }

        protected override double EaseInCore(double normalized)
        {
            if (normalized >= 1) return 1;
            var t = normalized * seconds;
            var w = 2 * Math.PI / response;
            if (damping >= 1) return 1 - (1 + w * t) * Math.Exp(-w * t);
            var wd = w * Math.Sqrt(1 - damping * damping);
            return 1 - Math.Exp(-damping * w * t) * (Math.Cos(wd * t) + damping / Math.Sqrt(1 - damping * damping) * Math.Sin(wd * t));
        }

        protected override Freezable CreateInstanceCore() => new Spring(response, damping, seconds);
    }
}
