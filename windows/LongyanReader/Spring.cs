using System;

namespace Longyan;

/// SwiftUI's spring, as maths only (no WPF, so windows/MotionCheck can run it anywhere): mass 1,
/// stiffness (2π / response)², damping 4πζ / response. A spring is a curve from a value and a
/// velocity toward a target; retargeting starts a new curve from where the old one is, at the
/// speed it is going, as SwiftUI does when an animation interrupts a running spring.
public readonly record struct SpringSpec(double Response, double Damping)
{
    public double Omega => 2 * Math.PI / Response;
}

/// One spring from `From` at `Velocity` (units a second) toward `To`.
public readonly record struct SpringCurve(double From, double Velocity, double To, SpringSpec Spec)
{
    /// The value and the velocity `t` seconds in.
    public (double Value, double Velocity) At(double t)
    {
        if (t <= 0) return (From, Velocity);
        var w = Spec.Omega;
        var z = Spec.Damping;
        var a = From - To;
        if (z >= 1)
        {
            // Critically damped (the card's cardMotion): x = e^(-wt) (a + b t).
            var b = Velocity + w * a;
            var e = Math.Exp(-w * t);
            return (To + e * (a + b * t), e * (b - w * (a + b * t)));
        }
        var wd = w * Math.Sqrt(1 - z * z);
        var c = (Velocity + z * w * a) / wd;
        var decay = Math.Exp(-z * w * t);
        var cos = Math.Cos(wd * t);
        var sin = Math.Sin(wd * t);
        var x = To + decay * (a * cos + c * sin);
        var v = decay * ((c * wd - z * w * a) * cos - (a * wd + z * w * c) * sin);
        return (x, v);
    }

    /// Done when it's within a hair of the target and all but still: a 2000th of its travel.
    public bool Settled(double t)
    {
        var (x, v) = At(t);
        var travel = Math.Max(Math.Abs(From - To), Math.Abs(Velocity) / Spec.Omega);
        var close = Math.Max(travel * 5e-4, 1e-6);
        return t > 4 || Math.Abs(x - To) < close && Math.Abs(v) < close * Spec.Omega;
    }
}

/// A value moved by springs over time (seconds on any clock): each new target starts a curve
/// from the value and velocity at that moment.
public sealed class SpringTrack
{
    public SpringCurve Curve { get; private set; }
    public double Start { get; private set; }

    public SpringTrack(double value, double velocity, double to, SpringSpec spec, double now)
    {
        Curve = new SpringCurve(value, velocity, to, spec);
        Start = now;
    }

    public (double Value, double Velocity) At(double now) => Curve.At(now - Start);
    public bool Settled(double now) => Curve.Settled(now - Start);

    /// A new target at `now`, keeping the value and velocity (`from` replaces the value when the
    /// thing moved has a new origin, as a part rebuilt somewhere else on the card).
    public void Retarget(double to, SpringSpec spec, double now, double? from = null)
    {
        var (x, v) = At(now);
        Curve = new SpringCurve(from ?? x, v, to, spec);
        Start = now;
    }
}
