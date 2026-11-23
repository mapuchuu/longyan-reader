using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Longyan;

/// Dev only, for filming the card beside the Mac's: `--show … --script "<plan>"` works the card
/// from inside the app each time it opens, and `--trace FILE` writes what is on screen each
/// frame while anything moves. Both as the Mac's (Sources/LongyanReader/CardScript.swift,
/// CardTrace.swift), with the same plans, names and lines. Nothing here runs in normal use.
///
/// A plan is steps "t,action[,target]" separated by ";", t in seconds after the card's reveal
/// has finished (0.5 s after it starts): hover T, unhover, press T, release, click T (press,
/// release 70 ms later), esc, close (a click elsewhere), reopen. Targets: row1… (meanings, in
/// the order shown; in a phrase card, the open row's), phrase-row1…, pin, copy, listen, anki,
/// note, back, showall, partof, badge. Each step raises the same mouse events on the target
/// as the pointer would (enter, leave, left button down and up), so the target's own handlers
/// run; the real mouse goes on working beside it.
sealed partial class CardWindow
{
    public readonly record struct Step(double T, string Action, string? Target);

    static readonly HashSet<string> actionNames = new() { "hover", "unhover", "press", "release", "click", "esc", "close", "reopen" };
    static readonly HashSet<string> fixedTargets = new() { "pin", "copy", "listen", "anki", "note", "back", "showall", "partof", "badge" };

    /// The plan's steps in time order, or why it can't be read.
    public static (List<Step> Steps, string? Error) ParsePlan(string plan)
    {
        var steps = new List<Step>();
        foreach (var part in plan.Split(';').Select(p => p.Trim()).Where(p => p.Length > 0))
        {
            var f = part.Split(',').Select(x => x.Trim()).ToArray();
            if (f.Length < 2 || !double.TryParse(f[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var t) || !actionNames.Contains(f[1]))
                return (new List<Step>(), $"can't read step \"{part}\"");
            var target = f.Length > 2 ? f[2] : null;
            if (f[1] is "hover" or "press" or "click" && (target == null || !fixedTargets.Contains(target) && !Regex.IsMatch(target, "^(phrase-)?row[1-9][0-9]*$")))
                return (new List<Step>(), $"step \"{part}\" needs a target: row1…, phrase-row1…, " + string.Join(", ", fixedTargets.OrderBy(x => x, StringComparer.Ordinal)));
            steps.Add(new Step(t, f[1], target));
        }
        return (steps.OrderBy(s => s.T).ToList(), null);
    }

    /// The time since boot, in seconds (QueryPerformanceCounter), as the Mac's systemUptime.
    static double Mono => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int process);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);

    /// The console --show was started from, for the script's lines, unless stderr goes to a file.
    public static void UseConsole()
    {
        var err = GetStdHandle(-12);
        if (err == IntPtr.Zero || err == new IntPtr(-1)) AttachConsole(-1);
    }

    /// One line on stderr per step, with the time since boot to line films up (and in the event log).
    static void ScriptLog(string text)
    {
        var mono = Mono;
        try { Console.Error.WriteLine(string.Format(CultureInfo.InvariantCulture, "script mono={0:F3} {1}", mono, text)); Console.Error.Flush(); } catch { }
        Core.Log(FormattableString.Invariant($"{{\"event\":\"script\",\"mono\":{mono:F3},\"step\":\"{text.Replace("\"", "'")}\"}}"));
    }

    // MARK: The script

    static List<Step> steps = new();
    static bool planRunning;
    static double showX, showY;
    // What the script has the pointer on: the card, the target it hovers and the one it pressed.
    static bool scriptOnCard;
    static string? scriptHovered;
    static UIElement? scriptPressed;
    bool rehovers;

    /// A card started to appear: the plan runs from 0.5 s on, when the reveal is done, unless
    /// it's already running (a card it reopened).
    void ScriptRevealed()
    {
        if (showing == null || steps.Count == 0) return;
        if (!rehovers)
        {
            // Built again under the script's pointer: the new part there is hovered, as under a real one.
            rehovers = true;
            view.Rebuilt += () =>
            {
                if (this == current && scriptHovered != null && view.Targets.TryGetValue(scriptHovered, out var e)) Raise(e, UIElement.MouseEnterEvent);
            };
        }
        ScriptLog("reveal");
        if (planRunning) return;
        planRunning = true;
        scriptOnCard = false; scriptHovered = null; scriptPressed = null;
        var start = Mono + 0.5;
        At(start, () => ScriptLog("t=0 (reveal done)"));
        for (var i = 0; i < steps.Count; i++)
        {
            var step = steps[i];
            var last = i == steps.Count - 1;
            At(start + step.T, () => { Run(step); if (last) planRunning = false; });
        }
    }

    static void At(double mono, Action act)
    {
        var t = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromSeconds(Math.Max(0, mono - Mono)) };
        t.Tick += (_, _) => { t.Stop(); act(); };
        t.Start();
    }

    static void Run(Step step)
    {
        ScriptLog(FormattableString.Invariant($"t={step.T:0.###} {step.Action}") + (step.Target != null ? " " + step.Target : ""));
        var w = current;
        if (w == null) return;
        switch (step.Action)
        {
            case "hover": w.ScriptHover(step.Target!); break;
            case "unhover":
                w.ScriptHover(null);
                if (scriptOnCard) { scriptOnCard = false; Raise(w.card, UIElement.MouseLeaveEvent); }
                break;
            case "press":
                w.ScriptHover(step.Target!);
                w.ScriptPress(step.Target!);
                break;
            case "release": ScriptRelease(); break;
            case "click":
                w.ScriptHover(step.Target!);
                w.ScriptPress(step.Target!);
                At(Mono + 0.07, () => { ScriptLog(FormattableString.Invariant($"t={step.T + 0.07:0.###} release")); ScriptRelease(); });
                break;
            case "esc": w.Outside(Hooks.Kind.Escape, default, IntPtr.Zero); break;
            case "close": w.Outside(Hooks.Kind.Click, new POINT { X = -32000, Y = -32000 }, IntPtr.Zero); break;
            case "reopen": ShowAgain(showX, showY); break;
        }
    }

    UIElement? ScriptTarget(string name) => name == "badge" ? badge : view.Targets.TryGetValue(name, out var e) ? e : null;

    /// The pointer onto the card and `name` (off the last target first), or off any target.
    void ScriptHover(string? name)
    {
        if (name != null && !scriptOnCard) { scriptOnCard = true; Raise(card, UIElement.MouseEnterEvent); }
        if (scriptHovered == name) return;
        if (scriptHovered != null && ScriptTarget(scriptHovered) is UIElement old) Raise(old, UIElement.MouseLeaveEvent);
        scriptPressed = null;
        scriptHovered = name;
        if (name == null) return;
        if (ScriptTarget(name) is UIElement e) Raise(e, UIElement.MouseEnterEvent);
        else ScriptLog($"no {name} on this card");
    }

    void ScriptPress(string name)
    {
        if (ScriptTarget(name) is not UIElement e) return;
        scriptPressed = e;
        Raise(e, UIElement.MouseLeftButtonDownEvent);
    }

    /// Letting go over the pressed target, which runs its own action.
    static void ScriptRelease()
    {
        var e = scriptPressed;
        scriptPressed = null;
        if (e != null) Raise(e, UIElement.MouseLeftButtonUpEvent);
    }

    static void Raise(UIElement e, RoutedEvent ev)
    {
        var tick = Environment.TickCount;
        MouseEventArgs a = ev == UIElement.MouseLeftButtonDownEvent || ev == UIElement.MouseLeftButtonUpEvent
            ? new MouseButtonEventArgs(Mouse.PrimaryDevice, tick, MouseButton.Left)
            : new MouseEventArgs(Mouse.PrimaryDevice, tick);
        a.RoutedEvent = ev;
        e.RaiseEvent(a);
    }

    // MARK: The trace

    static System.IO.StreamWriter? trace;
    static string lastTrace = "";

    /// Every rendered frame, a JSON line of what is on screen when it differs from the last.
    static void StartTrace(string path)
    {
        trace = new System.IO.StreamWriter(path, append: false, new UTF8Encoding(false)) { AutoFlush = true };
        CompositionTarget.Rendering += (_, _) =>
        {
            var w = current;
            if (w == null || trace == null) return;
            string line;
            try { line = w.TraceLine(); } catch (Exception) { return; }
            if (line == lastTrace) return;
            lastTrace = line;
            trace.WriteLine(FormattableString.Invariant($"{{\"mono\":{Mono * 1000:F3},") + line + "}");
        };
    }

    static string N(double v) => double.IsNaN(v) ? "null" : Math.Round(v, 4).ToString("0.####", CultureInfo.InvariantCulture);

    /// What the trace says of this card now: the window's opacity and frame (DIPs from the primary
    /// screen's top-left, as --show's X and Y), the card's reveal scale, offset and height, and
    /// each part that animates by its name.
    string TraceLine()
    {
        var sb = new StringBuilder();
        var s = scale <= 0 ? 1 : scale;
        var frameText = "null";
        if (Handle != IntPtr.Zero && GetWindowRect(Handle, out var r))
            frameText = $"[{N(r.Left / s)},{N(r.Top / s)},{N((r.Right - r.Left) / s)},{N((r.Bottom - r.Top) / s)}]";
        var height = double.IsNaN(surface.Height) ? surface.ActualHeight : surface.Height;
        sb.Append($"\"card\":{cardID},\"alpha\":{N(Opacity)},\"scale\":{N(revealScale.ScaleX)},\"dy\":{N(revealShift.Y)},\"height\":{N(height)},\"frame\":{frameText},\"elements\":{{");
        var parts = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, e) in view.Targets)
        {
            if (name is "pin" or "copy" or "listen" or "anki" && e is Border b)
            {
                parts[name + "-hover"] = $"{{\"opacity\":{N(b.Background?.Opacity ?? 0)}}}";
                parts[name + "-press"] = $"{{\"opacity\":{N(b.Opacity)}}}";
                if (b.Child is UIElement symbol) parts[name + "-symbol"] = Values(symbol);
            }
            else if (e is Grid g && g.Children.Count > 0 && g.Children[0] is Border h && h.Background != null)
                parts[name + "-hover"] = $"{{\"opacity\":{N(h.Background.Opacity)}}}";
            else if (name == "back") parts["back-press"] = $"{{\"opacity\":{N(e.Opacity)}}}";
        }
        foreach (var (name, e) in view.Animated) parts[name] = Values(e);
        parts["pin-badge"] = $"{{\"opacity\":{N(badge.Opacity)},\"scale\":{N(badgeScale.ScaleX)}}}";
        sb.Append(string.Join(",", parts.Select(p => $"\"{p.Key}\":{p.Value}")));
        sb.Append('}');
        return sb.ToString();
    }

    /// An element's opacity and its transforms' scale, rotation and offset, as they are this frame.
    static string Values(UIElement e)
    {
        double scaleX = 1, rotation = 0, dx = 0, dy = 0;
        bool scaled = false, rotated = false, moved = false;
        void Walk(Transform? t)
        {
            switch (t)
            {
                case ScaleTransform sc: scaleX *= sc.ScaleX; scaled = true; break;
                case RotateTransform ro: rotation += ro.Angle; rotated = true; break;
                case TranslateTransform tr: dx += tr.X; dy += tr.Y; moved = true; break;
                case TransformGroup gr: foreach (var c in gr.Children) Walk(c); break;
            }
        }
        Walk(e.RenderTransform);
        var v = $"{{\"opacity\":{N(e.Opacity)}";
        if (scaled) v += $",\"scale\":{N(scaleX)}";
        if (rotated) v += $",\"rotation\":{N(rotation)}";
        if (moved) v += $",\"dx\":{N(dx)},\"dy\":{N(dy)}";
        return v + "}";
    }

    /// Sets the run's script and trace before Show (App.cs, --show).
    public static void Prepare(List<Step> plan, string? tracePath)
    {
        steps = plan;
        if (tracePath != null) StartTrace(tracePath);
    }
}
