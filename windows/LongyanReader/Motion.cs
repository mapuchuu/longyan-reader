using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Longyan;

/// The Mac card's motion (notes/card-spec.md, section 6). SwiftUI's springs run on a driver of
/// our own (Spring.cs for the maths), not as WPF animations: a WPF animation that is replaced
/// starts again from rest, while a SwiftUI spring that is given a new target carries on from
/// where it is at the speed it is going. Toggling a row twice quickly showed it.
static class Motion
{
    /// cardMotion: response 0.34 s, no overshoot (CC:191-197).
    public static readonly SpringSpec Card = new(0.34, 1.0);

    /// The card's appearance: response 0.32 s, damping 0.82 (PU:446).
    public static readonly SpringSpec Reveal = new(0.32, 0.82);

    /// The pinned card's close badge: response 0.25 s, damping 0.9 (CC:1006).
    public static readonly SpringSpec Badge = new(0.25, 0.9);

    /// The eye (Chip.swift:212-228): in with response 0.3, damping 0.68; hover 0.25, 0.7; press
    /// 0.2, 0.7. Still WPF easing (Chip.cs is the eye's own work), so they restart from rest.
    public static readonly IEasingFunction EyeAppear = new SpringEase(0.3, 0.68, 0.6);
    public static readonly IEasingFunction EyeHover = new SpringEase(0.25, 0.7, 0.5);
    public static readonly IEasingFunction EyePress = new SpringEase(0.2, 0.7, 0.4);

    /// SwiftUI's .easeOut and .easeInOut are Core Animation's curves, cubic Béziers (0, 0, 0.58, 1)
    /// and (0.42, 0, 0.58, 1). WPF's CubicEase is far steeper at the start (0.875 of the way at
    /// half time, against 0.69), so hovers and fades snapped on rather than eased.
    public static readonly IEasingFunction EaseOut = new Bezier(0, 0, 0.58, 1);

    static readonly IEasingFunction EaseInOut = new Bezier(0.42, 0, 0.58, 1);

    /// A cubic Bézier timing curve from (0, 0) to (1, 1).
    public static IEasingFunction Curve(double x1, double y1, double x2, double y2) => new Bezier(x1, y1, x2, y2);

    /// True when Windows' "Animation effects" are off (Reduce Motion on the Mac).
    public static bool Reduced => !SystemParameters.ClientAreaAnimation;

    /// A change inside the card: cardMotion, or with Reduce Motion easeInOut 0.15 s (the Mac
    /// keeps content transitions then, just short and without slides). `key` carries the motion
    /// over to a part rebuilt in another element, as SwiftUI keeps a view's identity.
    public static void Content(DependencyObject e, DependencyProperty p, double from, double to, string? key = null, Action? done = null)
    {
        if (!Reduced) { Spring(e, p, to, Card, from, key, done); return; }
        Stop(e, p);
        var a = new DoubleAnimation(from, to, new Duration(TimeSpan.FromSeconds(0.15))) { EasingFunction = EaseInOut };
        if (done != null) a.Completed += (_, _) => done();
        ((IAnimatable)e).BeginAnimation(p, a);
    }

    /// Fades an element in with cardMotion, optionally sliding down from `fromY` above.
    public static void FadeIn(UIElement e, double fromY = 0)
    {
        Content(e, UIElement.OpacityProperty, 0, 1);
        if (fromY != 0 && !Reduced)
        {
            var t = new TranslateTransform(0, fromY);
            e.RenderTransform = t;
            Spring(t, TranslateTransform.YProperty, 0, Card, fromY);
        }
    }

    /// Ease-out to `to` over `seconds`, from wherever the value is now.
    public static void To(Animatable e, DependencyProperty p, double to, double seconds)
    {
        Stop(e, p);
        e.BeginAnimation(p, new DoubleAnimation(to, new Duration(TimeSpan.FromSeconds(seconds))) { EasingFunction = EaseOut });
    }

    public static void To(UIElement e, DependencyProperty p, double to, double seconds)
    {
        Stop(e, p);
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

    // MARK: The spring driver

    sealed class Run
    {
        public required DependencyObject Target;
        public required DependencyProperty Property;
        public required SpringTrack Track;
        public string? Key, Trace;
        public Action? Done;
        public System.Collections.Generic.List<(double T, double X)>? Frames;
    }

    static readonly System.Collections.Generic.Dictionary<(DependencyObject, DependencyProperty), Run> runs = new();
    static readonly System.Collections.Generic.Dictionary<string, Run> keyed = new();
    static readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    static bool ticking;

    /// Seconds on the springs' clock.
    public static double Now => clock.Elapsed.TotalSeconds;

    /// Springs `p` of `e` to `to`. A spring already moving it (or, with `key`, the part it
    /// replaces) carries on from its value and velocity; otherwise it starts at rest from `from`,
    /// or the value now. `trace` logs every frame (UI check). `done` runs when it settles.
    public static void Spring(DependencyObject e, DependencyProperty p, double to, SpringSpec spec, double? from = null, string? key = null, Action? done = null, string? trace = null)
    {
        var now = Now;
        runs.TryGetValue((e, p), out var old);
        if (old == null && key != null && keyed.TryGetValue(key, out var k)) old = k;
        SpringTrack track;
        if (old != null)
        {
            Drop(old, log: true);
            track = old.Track;
            // The same element carries on from where it is; a rebuilt one from where it was put.
            track.Retarget(to, spec, now, old.Target == e && old.Property == p ? null : from);
        }
        else track = new SpringTrack(from ?? (double)e.GetValue(p), 0, to, spec, now);
        ((IAnimatable)e).BeginAnimation(p, null);
        var run = new Run { Target = e, Property = p, Track = track, Key = key, Trace = Core.Logging ? trace : null, Done = done };
        if (run.Trace != null) run.Frames = new();
        runs[(e, p)] = run;
        if (key != null) keyed[key] = run;
        e.SetValue(p, track.At(now).Value);
        if (!ticking) { ticking = true; CompositionTarget.Rendering += Tick; }
    }

    sealed class Line
    {
        public required DependencyObject Target;
        public required DependencyProperty Property;
        public double From, To, Seconds, Start;
        public bool Ended;
        public string? Trace;
        public Action? Done;
        public System.Collections.Generic.List<(double T, double X)>? Frames;
    }

    static readonly System.Collections.Generic.Dictionary<(DependencyObject, DependencyProperty), Line> lines = new();

    /// Moves `p` of `e` from `from` to `to` in a straight line over `seconds`, timed from now.
    /// `done` runs on the frame after the one that drew `to`, so the end is on screen first
    /// (a window hidden on the last tick never shows its last step).
    public static void Linear(DependencyObject e, DependencyProperty p, double from, double to, double seconds, Action? done = null, string? trace = null)
    {
        Stop(e, p);
        lines.Remove((e, p));
        ((IAnimatable)e).BeginAnimation(p, null);
        var line = new Line { Target = e, Property = p, From = from, To = to, Seconds = seconds, Start = Now, Done = done, Trace = Core.Logging ? trace : null };
        if (line.Trace != null) line.Frames = new() { (line.Start, from) };
        lines[(e, p)] = line;
        e.SetValue(p, from);
        if (!ticking) { ticking = true; CompositionTarget.Rendering += Tick; }
    }

    public static void StopLinear(DependencyObject e, DependencyProperty p) => lines.Remove((e, p));

    /// Whether a spring under `key` is still moving, and its value now.
    public static bool Moving(string key) => keyed.ContainsKey(key);
    public static bool Running(DependencyObject e, DependencyProperty p) => runs.ContainsKey((e, p));
    public static double? Live(string key) => keyed.TryGetValue(key, out var run) ? run.Track.At(Now).Value : null;

    /// Stops a spring on `p` of `e` where it is (another animation or a set takes over).
    public static void Stop(DependencyObject e, DependencyProperty p)
    {
        if (runs.TryGetValue((e, p), out var run)) Drop(run, log: true);
    }

    static void Drop(Run run, bool log)
    {
        if (runs.TryGetValue((run.Target, run.Property), out var r) && r == run) runs.Remove((run.Target, run.Property));
        if (run.Key != null && keyed.TryGetValue(run.Key, out var k) && k == run) keyed.Remove(run.Key);
        if (log && run.Frames != null) LogRun(run);
    }

    static void Tick(object? sender, EventArgs e)
    {
        var now = Now;
        foreach (var run in new System.Collections.Generic.List<Run>(runs.Values))
        {
            if (!runs.TryGetValue((run.Target, run.Property), out var r) || r != run) continue;
            var (x, _) = run.Track.At(now);
            var done = run.Track.Settled(now);
            if (done) x = run.Track.Curve.To;
            run.Target.SetValue(run.Property, x);
            run.Frames?.Add((now, x));
            if (!done) continue;
            Drop(run, log: true);
            run.Done?.Invoke();
        }
        foreach (var line in new System.Collections.Generic.List<Line>(lines.Values))
        {
            if (!lines.TryGetValue((line.Target, line.Property), out var l) || l != line) continue;
            if (line.Ended)
            {
                lines.Remove((line.Target, line.Property));
                if (line.Frames != null)
                    Core.Log(FormattableString.Invariant($"{{\"event\":\"linear\",\"tag\":\"{line.Trace}\",\"start\":{line.Start * 1000:0.00},\"from\":{line.From:0.0000},\"to\":{line.To:0.0000},\"seconds\":{line.Seconds},\"done\":{now * 1000:0.00},\"frames\":[{string.Join(",", line.Frames.ConvertAll(f => FormattableString.Invariant($"[{f.T * 1000:0.00},{f.X:0.0000}]")))}]}}"));
                line.Done?.Invoke();
                continue;
            }
            var t = Math.Min(1, (now - line.Start) / line.Seconds);
            var x = line.From + (line.To - line.From) * t;
            line.Target.SetValue(line.Property, x);
            line.Frames?.Add((now, x));
            if (t >= 1) line.Ended = true;
        }
        if (runs.Count == 0 && lines.Count == 0) { ticking = false; CompositionTarget.Rendering -= Tick; }
    }

    /// For the UI check: the curve this spring started on, and the value it drew each frame.
    static void LogRun(Run run)
    {
        var c = run.Track.Curve;
        var frames = string.Join(",", run.Frames!.ConvertAll(f => FormattableString.Invariant($"[{f.T * 1000:0.00},{f.X:0.0000}]")));
        Core.Log(FormattableString.Invariant($"{{\"event\":\"spring\",\"tag\":\"{run.Trace}\",\"start\":{run.Track.Start * 1000:0.00},\"from\":{c.From:0.0000},\"velocity\":{c.Velocity:0.0000},\"to\":{c.To:0.0000},\"response\":{c.Spec.Response},\"damping\":{c.Spec.Damping},\"frames\":[{frames}]}}"));
        run.Frames = null;
    }

    /// A spring from rest as a WPF easing over a fixed time, ending exactly at 1 (the eye's).
    sealed class SpringEase : EasingFunctionBase
    {
        readonly double response, damping, seconds;
        public SpringEase(double response, double damping, double seconds)
        {
            this.response = response; this.damping = damping; this.seconds = seconds;
            EasingMode = EasingMode.EaseIn;   // EaseInCore is the curve as given
        }

        protected override double EaseInCore(double normalized) =>
            normalized >= 1 ? 1 : new SpringCurve(0, 0, 1, new SpringSpec(response, damping)).At(normalized * seconds).Value;

        protected override Freezable CreateInstanceCore() => new SpringEase(response, damping, seconds);
    }
}
