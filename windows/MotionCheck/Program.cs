using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Longyan;

/// The card's springs against SwiftUI's. SwiftUI's spring is the ODE x'' = -k (x - target) - c x'
/// with k = (2π / response)², c = 4πζ / response (mass 1); a new target mid-way keeps x and x'
/// (filmed on the Mac: mac-retarget.tsv). Here the ODE is solved step by step (RK4), apart from
/// Spring.cs's closed form, and the two must agree; then Spring.cs is held against the film.
static class Program
{
    static readonly List<string> failures = new();

    static int Main()
    {
        // A row toggled twice: the card's height 100 to 180, back to 100 after `gap` (cardMotion);
        // the reveal and the badge the same way on their own springs.
        foreach (var (name, spec, a, b) in new[]
        {
            ("cardMotion (row height)", new SpringSpec(0.34, 1.0), 100.0, 180.0),
            ("reveal (scale)", new SpringSpec(0.32, 0.82), 0.96, 1.0),
            ("badge (opacity)", new SpringSpec(0.25, 0.9), 0.0, 1.0),
        })
            foreach (var gap in new[] { 0.05, 0.10, 0.15 })
                Twice(name, spec, a, b, gap);
        Film();
        foreach (var f in failures) Console.WriteLine("FAILED: " + f);
        return failures.Count == 0 ? 0 : 1;
    }

    /// The value at `t` (seconds) of SwiftUI's spring from rest at `a`, to `b` at 0 and back to `a`
    /// at `gap`, by RK4 on the ODE, keeping x and x' at the second target.
    static double Ode(SpringSpec s, double a, double b, double gap, double t)
    {
        double k = Math.Pow(2 * Math.PI / s.Response, 2), c = 4 * Math.PI * s.Damping / s.Response;
        double x = a, v = 0, now = 0;
        const double dt = 1e-5;
        while (now < t - 1e-12)
        {
            var h = Math.Min(dt, t - now);
            var target = now < gap - 1e-12 ? b : a;
            if (now < gap && now + h > gap) h = gap - now;   // step exactly onto the retarget
            (double, double) F(double px, double pv) => (pv, -k * (px - target) - c * pv);
            var (k1x, k1v) = F(x, v);
            var (k2x, k2v) = F(x + h / 2 * k1x, v + h / 2 * k1v);
            var (k3x, k3v) = F(x + h / 2 * k2x, v + h / 2 * k2v);
            var (k4x, k4v) = F(x + h * k3x, v + h * k3v);
            x += h / 6 * (k1x + 2 * k2x + 2 * k3x + k4x);
            v += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v);
            now += h;
        }
        return x;
    }

    static void Twice(string name, SpringSpec spec, double a, double b, double gap)
    {
        // The card's driver: one track, retargeted at `gap` (Motion.Spring does the same).
        var track = new SpringTrack(a, 0, b, spec, 0);
        double worst = 0, restart = 0;
        SpringTrack? fromRest = null;
        for (var i = 0; i <= 120; i++)
        {
            var t = i / 120.0;   // 120 frames a second for a second
            if (t >= gap && track.Curve.To == b)
            {
                track.Retarget(a, spec, gap);
                fromRest = new SpringTrack(new SpringTrack(a, 0, b, spec, 0).At(gap).Value, 0, a, spec, gap);
            }
            var want = Ode(spec, a, b, gap, t);
            worst = Math.Max(worst, Math.Abs(track.At(t).Value - want));
            if (fromRest != null) restart = Math.Max(restart, Math.Abs(fromRest.At(t).Value - want));
        }
        var range = Math.Abs(b - a);
        Console.WriteLine(FormattableString.Invariant($"{name}, toggled twice {gap * 1000:0} ms apart: off SwiftUI's curve by {worst / range:0.0e0} of the travel at most (a WPF restart from rest: {restart / range:P1})"));
        if (worst > 1e-6 * range) failures.Add($"{name}, gap {gap}: {worst} off");
        if (restart < 0.01 * range) failures.Add($"{name}, gap {gap}: the check can't tell a restart from rest ({restart})");
    }

    /// The Mac's own spring, filmed: from 20 to 180 pt, then to 178 a moment later (the gap is
    /// the app's clock; the film's start is found by fitting, the gap within 20 ms of the clock's).
    /// Keeping the velocity fits to under 1.5 pt; restarting from rest stalls and misses by 4 pt
    /// or more.
    static void Film()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "mac-retarget.tsv");
        var gaps = new Dictionary<int, double>();
        var samples = new List<(int Cycle, double T, double H)>();
        foreach (var line in File.ReadLines(path))
        {
            if (line.StartsWith("# cycle"))
            {
                var p = line.Split(' ');
                gaps[int.Parse(p[2])] = double.Parse(p[4], CultureInfo.InvariantCulture);
                continue;
            }
            if (line.StartsWith("#") || line.Trim() == "") continue;
            var f = line.Split('\t');
            samples.Add((int.Parse(f[0]), double.Parse(f[1], CultureInfo.InvariantCulture), double.Parse(f[2], CultureInfo.InvariantCulture)));
        }
        var spec = new SpringSpec(0.34, 1);
        foreach (var (cycle, gap) in gaps)
        {
            var points = samples.Where(s => s.Cycle == cycle).ToList();
            double Fit(bool keep)
            {
                var best = double.MaxValue;
                for (var start = -0.06; start <= 0.01; start += 0.001)
                    for (var g = gap - 0.02; g <= gap + 0.02; g += 0.002)
                    {
                        var err = 0.0;
                        foreach (var (_, t, h) in points)
                        {
                            var u = t - start;
                            double x;
                            if (u < 0) x = 20;
                            else if (u < g) x = new SpringTrack(20, 0, 180, spec, 0).At(u).Value;
                            else if (keep) { var tr = new SpringTrack(20, 0, 180, spec, 0); tr.Retarget(178, spec, g); x = tr.At(u).Value; }
                            else x = new SpringTrack(new SpringTrack(20, 0, 180, spec, 0).At(g).Value, 0, 178, spec, g).At(u).Value;
                            err += (x - h) * (x - h);
                        }
                        best = Math.Min(best, Math.Sqrt(err / points.Count));
                    }
                return best;
            }
            double keepFit = Fit(true), restFit = Fit(false);
            Console.WriteLine(FormattableString.Invariant($"Mac film, cycle {cycle} (gap {gap * 1000:0} ms): Spring.cs off by {keepFit:0.00} pt rms; restarting from rest {restFit:0.00} pt"));
            if (keepFit > 1.5) failures.Add($"film cycle {cycle}: Spring.cs {keepFit:0.00} pt off the Mac");
            if (restFit < 2 * keepFit) failures.Add($"film cycle {cycle}: the film can't tell the two apart");
        }
    }
}
