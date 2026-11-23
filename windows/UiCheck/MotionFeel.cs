using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// The card's motion against the Mac's, in the real app (notes/windows-parity.md, "Motion and
/// behaviour"): springs that keep their speed when retargeted, Listen's waves, the symbol swaps,
/// and the touchpad's rubber band. Each films a burst and checks what the app logged.
static partial class Program
{
    static int LogLength() => File.Exists(log) ? File.ReadAllLines(log).Length : 0;

    static List<JsonObject> Events(int skip, string name)
    {
        var list = new List<JsonObject>();
        if (!File.Exists(log)) return list;
        foreach (var line in File.ReadAllLines(log).Skip(skip))
            if (JsonNode.Parse(line) is JsonObject e && (string?)e["event"] == name) list.Add(e);
        return list;
    }

    static AutomationElement? CardButton(Process app, string startsWith)
    {
        var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id);
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, cond))
            foreach (AutomationElement b in w.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)))
                if (b.Current.Name.StartsWith(startsWith)) return b;
        return null;
    }

    static void ClickOn(AutomationElement e)
    {
        var r = e.Current.BoundingRectangle;
        Click(r.Left + r.Width / 2, r.Top + r.Height / 2);
    }

    /// Listen: the waves light in turn while it speaks (a silent stand-in voice, 2.5 s), and when
    /// it stops they finish their round: the end falls on a whole round (1/3 s + k × 4/3 s).
    static void ListenFilm(Process app)
    {
        var button = CardButton(app, "Listen to");
        if (button == null) { failures.Add("1-listen: no Listen button"); return; }
        var skip = LogLength();
        ClickOn(button);
        Burst("1-listen", 4000);
        Thread.Sleep(600);
        var on = Events(skip, "waves");
        var stop = on.FirstOrDefault(e => e["stop"] != null);
        var off = on.FirstOrDefault(e => (bool?)e["on"] == false);
        Console.WriteLine($"[1-listen] {string.Join(" ", on.Select(e => e.ToJsonString()))}");
        if (!on.Any(e => (bool?)e["on"] == true)) { failures.Add("1-listen: the waves didn't start"); return; }
        if (stop == null || off == null) { failures.Add("1-listen: the waves didn't stop"); return; }
        var end = (double)stop["end"]!;
        var rounds = (end / 1000 - 1.0 / 3) / (4.0 / 3);
        if (Math.Abs(rounds - Math.Round(rounds)) > 0.02) failures.Add($"1-listen: the waves stopped mid-round ({end} ms)");
        if (Math.Abs((double)off["ms"]! - end) > 120) failures.Add($"1-listen: the waves ended at {off["ms"]} ms, not at the round's end {end} ms");
    }

    /// Copy, then Pin and Unpin: SF Symbols' replace.downUp (and the pin's bounce), filmed.
    static void SymbolFilms(Process app)
    {
        if (CardButton(app, "Copy") is AutomationElement copy)
        {
            ClickOn(copy);
            Burst("1-copy", 700);
            Thread.Sleep(1200);
            Burst("1-copy-back", 700);
        }
        else failures.Add("1-copy: no Copy button");
        if (CardButton(app, "Pin") is AutomationElement pin)
        {
            ClickOn(pin);
            Burst("1-pin", 900);
            if (CardButton(app, "Unpin") is AutomationElement unpin) { ClickOn(unpin); Burst("1-unpin", 900); }
            else failures.Add("1-pin: no Unpin button after pinning");
        }
        else failures.Add("1-pin: no Pin button");
    }

    /// A row opened and shut again within 0.15 s: the card's height must follow SwiftUI's spring,
    /// which carries on from where it is at the speed it is going. Checked against the closed
    /// form here (not the app's), on the values the app drew every frame.
    static void TwiceCheck(double x, double y)
    {
        var skip = LogLength();
        Click(x, y);
        Thread.Sleep(40);
        Click(x, y);
        Burst("2-twice", 900);
        Thread.Sleep(800);
        var runs = Events(skip, "spring").Where(e => (string?)e["tag"] == "height").ToList();
        Console.WriteLine($"[2-twice] {runs.Count} height springs: " + string.Join("; ", runs.Select(r => $"start {r["start"]} from {r["from"]} v {r["velocity"]} to {r["to"]} ({r["frames"]!.AsArray().Count} frames)")));
        JsonObject? first = null, second = null;
        for (var i = 0; i + 1 < runs.Count; i++)
        {
            var gap = (double)runs[i + 1]["start"]! - (double)runs[i]["start"]!;
            if (gap < 300 && (double)runs[i]["velocity"]! == 0) { first = runs[i]; second = runs[i + 1]; break; }
        }
        if (first == null || second == null) { failures.Add("2-twice: no row opened and shut again within 0.3 s (see the springs above)"); return; }
        double t1 = (double)first["start"]! / 1000, t2 = (double)second["start"]! / 1000;
        double a = (double)first["from"]!, b = (double)first["to"]!, back = (double)second["to"]!;
        var w = 2 * Math.PI / 0.34;
        // cardMotion from rest: x = b - (b - a)(1 + wt) e^(-wt), x' = (b - a) w² t e^(-wt).
        double X1(double t) => b - (b - a) * (1 + w * t) * Math.Exp(-w * t);
        double V1(double t) => (b - a) * w * w * t * Math.Exp(-w * t);
        double x2 = X1(t2 - t1), v2 = V1(t2 - t1);
        double X2(double t) { var A = x2 - back; var B = v2 + w * A; return back + Math.Exp(-w * t) * (A + B * t); }
        double Rest(double t) { var A = x2 - back; return back + Math.Exp(-w * t) * (A + w * A * t); }
        Console.WriteLine($"[2-twice] shut {1000 * (t2 - t1):0} ms after it opened; at that moment {x2:0.00} px going {v2:0} px/s; the app: {second["from"]} px going {second["velocity"]} px/s");
        if (Math.Abs((double)second["from"]! - x2) > 0.05) failures.Add($"2-twice: the shut started at {second["from"]}, SwiftUI's curve was at {x2:0.00}");
        if (Math.Abs((double)second["velocity"]! - v2) > 1) failures.Add($"2-twice: the shut started at {second["velocity"]} px/s, SwiftUI's curve at {v2:0} px/s");
        double worst = 0, restart = 0;
        foreach (var f in first["frames"]!.AsArray()) worst = Math.Max(worst, Math.Abs((double)f![1]! - X1((double)f[0]! / 1000 - t1)));
        foreach (var f in second["frames"]!.AsArray())
        {
            var t = (double)f![0]! / 1000 - t2;
            worst = Math.Max(worst, Math.Abs((double)f[1]! - X2(t)));
            restart = Math.Max(restart, Math.Abs(X2(t) - Rest(t)));
        }
        Console.WriteLine($"[2-twice] every frame within {worst:0.0000} px of SwiftUI's curve; a restart from rest would have been up to {restart:0.0} px off");
        if (worst > 0.05) failures.Add($"2-twice: frames up to {worst:0.000} px off SwiftUI's curve");
    }

    /// The touchpad at the top of a card that scrolls: it pulls past the end and springs back;
    /// a mouse notch there doesn't (the Mac's mouse wheel never bounces).
    static void BandFilm()
    {
        var skip = LogLength();
        for (var i = 0; i < 12; i++) { Wheel(60); Thread.Sleep(16); }
        Burst("2-band", 700);
        Thread.Sleep(300);
        var bands = Events(skip, "band");
        var backs = Events(skip, "band-back");
        Console.WriteLine($"[2-band] {string.Join(" ", bands.Concat(backs).Select(e => e.ToJsonString()))}");
        if (bands.Count == 0 || (double)bands[0]["stretch"]! <= 3) failures.Add("2-band: the touchpad didn't pull the card's top past its end");
        if (backs.Count == 0) failures.Add("2-band: the stretch didn't spring back");
        skip = LogLength();
        Thread.Sleep(400);
        Wheel(120);
        Thread.Sleep(500);
        if (Events(skip, "band").Count > 0) failures.Add("2-band: a mouse notch at the top bounced");
    }
}
