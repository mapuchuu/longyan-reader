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
    public static readonly IEasingFunction EyeAppear = new Spring(0.3, 0.68, 0.6);
    public static readonly IEasingFunction EyeHover = new Spring(0.25, 0.7, 0.5);
    public static readonly IEasingFunction EyePress = new Spring(0.2, 0.7, 0.4);

    public static readonly IEasingFunction EaseOut = new CubicEase { EasingMode = EasingMode.EaseOut };

    /// How the content moves when it changes: cardMotion, or easeInOut 0.15 s with Reduce Motion
    /// (the Mac keeps content transitions then, just short and without slides).
    public static Duration ContentDuration => Reduced ? new Duration(TimeSpan.FromSeconds(0.15)) : CardDuration;
    public static IEasingFunction ContentEase => Reduced ? EaseInOut : Card;
    static readonly IEasingFunction EaseInOut = new QuadraticEase { EasingMode = EasingMode.EaseInOut };

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
