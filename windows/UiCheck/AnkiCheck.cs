using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace Longyan;

/// Add to Anki against a stand-in for AnkiConnect on 127.0.0.1:8765, which keeps notes in
/// memory and records every request (anki-requests.jsonl). Anki opens after the app: the
/// next card has the button; a click adds the note with the requests the Mac sends
/// (anki-mac.json, made on the Mac with Tests/bridge/anki.c); a second click shows it in Anki;
/// the word opens as already added; with Anki gone a click says so, then the button is ready.
static partial class Program
{
    static void AnkiCheck(Process app, IntPtr notepad)
    {
        var mac = File.Exists(Path.Combine("windows", "UiCheck", "anki-mac.json"))
            ? JsonNode.Parse(File.ReadAllText(Path.Combine("windows", "UiCheck", "anki-mac.json"))) as JsonObject : null;
        if (mac == null) { failures.Add("4-anki: windows/UiCheck/anki-mac.json is missing (run from the repo)"); return; }
        using var anki = new FakeAnkiConnect(Path.Combine(outDir, "anki-requests.jsonl"));
        try { anki.Start(); }
        catch (Exception e) { failures.Add("4-anki: couldn't listen on 127.0.0.1:8765: " + e.Message); return; }

        // The app last asked AnkiConnect (and found nothing) when the last card opened: past
        // the 10 s between checks, the next card asks again.
        Thread.Sleep(11000);
        var logStart = File.Exists(log) ? File.ReadAllLines(log).Length : 0;
        SelectInNotepad(notepad, 3, 2);   // 感冒
        Check("4-anki-before", app, new[] { "感冒" });
        if (AnkiButton(app) != null) failures.Add("4-anki: a card that opened before Anki answered has the Anki button");
        var started = DateTime.Now;
        while (!LogHas(logStart, "anki", "available", "true") && (DateTime.Now - started).TotalSeconds < 8) Thread.Sleep(200);
        if (!LogHas(logStart, "anki", "available", "true")) { failures.Add("4-anki: the app didn't find AnkiConnect"); Keys(VK_ESCAPE); return; }
        Keys(VK_ESCAPE);
        Thread.Sleep(800);

        // Anki is open now: the button, and a click adds the note.
        var before = anki.Count;
        SelectInNotepad(notepad, 3, 2);
        Check("4-anki", app, new[] { "感冒" });
        var card = LastCard(logStart);
        var button = AnkiButton(app);
        Console.WriteLine($"[4-anki] button: {button?.Current.Name ?? "none"}");
        if (button == null || button.Current.Name != "Add “感冒” to Anki") { failures.Add($"4-anki: no \"Add “感冒” to Anki\" button ({button?.Current.Name ?? "none"})"); Keys(VK_ESCAPE); return; }
        Invoke(button);
        var added = WaitForAnki(app, "In Anki · click to show it there", 20);
        Shot("4-anki-added");
        if (added == null) failures.Add($"4-anki: the button didn't turn to \"In Anki\" ({AnkiButton(app)?.Current.Name ?? "gone"})");

        // The requests, as the Mac makes them.
        var requests = anki.Since(before);
        var actions = requests.Select(r => (string?)r["action"]).Where(a => a != "deckNames").ToList();
        var macActions = mac["actions"]!.AsArray().Select(a => (string?)a).ToList();
        Console.WriteLine($"[4-anki] actions: {string.Join(", ", actions)}");
        if (!actions.SequenceEqual(macActions)) failures.Add($"4-anki: the actions were {string.Join(", ", actions)}, the Mac's {string.Join(", ", macActions)}");
        var model = requests.FirstOrDefault(r => (string?)r["action"] == "createModel");
        if (model == null || !JsonNode.DeepEquals(model, mac["createModel"])) failures.Add("4-anki: createModel isn't the Mac's");
        else Console.WriteLine("[4-anki] createModel: the same as the Mac's");
        var note = requests.FirstOrDefault(r => (string?)r["action"] == "addNote");
        if (note == null) failures.Add("4-anki: no addNote");
        else if (card != null) CompareNote(note, mac["addNote"]!.DeepClone().AsObject(), card);

        // A second click shows the note in Anki's browser.
        var id = anki.LastId;
        before = anki.Count;
        if (added != null) Invoke(added);
        Thread.Sleep(1500);
        if (!anki.Since(before).Any(r => (string?)r["action"] == "guiBrowse" && (string?)r["params"]?["query"] == $"nid:{id}"))
            failures.Add($"4-anki: clicking \"In Anki\" didn't show note {id} in Anki");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);

        // The same word again: it opens as already in Anki.
        SelectInNotepad(notepad, 3, 2);
        Check("4-anki-again", app, new[] { "感冒" });
        if (WaitForAnki(app, "In Anki · click to show it there", 5) == null)
            failures.Add($"4-anki: the word added before didn't open as in Anki ({AnkiButton(app)?.Current.Name ?? "none"})");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);

        // Anki quits while a card is up: a click says so, then the button is ready again.
        SelectInNotepad(notepad, 6, 1);   // 吃
        Check("4-anki-gone", app, new[] { "吃" });
        anki.Stop();
        var ready = AnkiButton(app);
        if (ready == null || ready.Current.Name != "Add “吃” to Anki") { failures.Add($"4-anki: no \"Add “吃” to Anki\" button ({ready?.Current.Name ?? "none"})"); Keys(VK_ESCAPE); return; }
        Invoke(ready);
        var failed = WaitForAnki(app, "Anki didn't answer. Is it open?", 10);
        Shot("4-anki-failed");
        if (failed == null) failures.Add($"4-anki: with Anki gone, the button didn't say so ({AnkiButton(app)?.Current.Name ?? "gone"})");
        else Console.WriteLine("[4-anki] with Anki gone: \"Anki didn't answer. Is it open?\"");
        if (WaitForAnki(app, "Add “吃” to Anki", 5) == null) failures.Add("4-anki: the button wasn't ready again after the warning");
        Keys(VK_ESCAPE);
        Thread.Sleep(800);
    }

    /// The note the Windows app added against the Mac's: everything the same, except what the
    /// model picked on each (the meaning, and with it the dictionary sense and note), which is
    /// checked against the Windows card instead.
    static void CompareNote(JsonObject windows, JsonObject mac, JsonObject card)
    {
        var fields = mac["params"]!["note"]!["fields"]!.AsObject();
        var macMeaning = (string?)fields["Meaning"];
        var meaning = (string?)card["meaning"] ?? "";
        var rows = card["senses"]?.AsArray().OfType<JsonObject>().ToList() ?? new List<JsonObject>();
        var chosen = rows.FirstOrDefault(r => (bool?)r["chosen"] == true) ?? rows.FirstOrDefault();
        var dictionary = (string?)chosen?["tip"] ?? "";
        if (string.Equals(dictionary, meaning, StringComparison.OrdinalIgnoreCase)) dictionary = "";
        fields["Meaning"] = meaning;
        fields["Dictionary"] = dictionary;
        fields["Note"] = (string?)card["note"]?["text"] ?? "";
        if (JsonNode.DeepEquals(windows, mac))
            Console.WriteLine(meaning == macMeaning ? "[4-anki] addNote: the same as the Mac's" : $"[4-anki] addNote: the Mac's, with the meaning picked here (\"{meaning}\"; the Mac's \"{macMeaning}\")");
        else
            failures.Add($"4-anki: addNote isn't the Mac's:\n  here {windows.ToJsonString(Pretty)}\n  Mac  {mac.ToJsonString(Pretty)}");
    }

    static readonly JsonSerializerOptions Pretty = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// Selects `length` characters from `start` on Notepad's first line.
    static void SelectInNotepad(IntPtr notepad, int start, int length)
    {
        Focus(notepad);
        Keys(VK_CONTROL, VK_HOME);
        for (var i = 0; i < start; i++) Keys(VK_RIGHT);
        for (var i = 0; i < length; i++) Keys(VK_SHIFT, VK_RIGHT);
    }

    /// The card's Anki button, through UI Automation: named by its help, as on the Mac.
    static AutomationElement? AnkiButton(Process app)
    {
        var cond = new AndCondition(new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id),
                                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, app.Id)))
            foreach (AutomationElement b in w.FindAll(TreeScope.Descendants, cond))
            {
                var name = b.Current.Name;
                if (name.Contains("Anki") || name.StartsWith("Adding")) return b;
            }
        return null;
    }

    /// Waits up to `seconds` for the Anki button's help to be `name`.
    static AutomationElement? WaitForAnki(Process app, string name, double seconds)
    {
        var end = DateTime.Now.AddSeconds(seconds);
        do
        {
            if (AnkiButton(app) is AutomationElement b && b.Current.Name == name) return b;
            Thread.Sleep(200);
        } while (DateTime.Now < end);
        return null;
    }

    static void Invoke(AutomationElement button)
    {
        try { ((InvokePattern)button.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); }
        catch (Exception e) { failures.Add("4-anki: couldn't press the Anki button: " + e.Message); }
    }
}

/// AnkiConnect as far as the app uses it (Sources/LongyanCore/Anki.swift; the same as
/// scripts/fake-ankiconnect.py), over plain HTTP on a socket.
sealed class FakeAnkiConnect : IDisposable
{
    readonly string record;
    readonly List<JsonObject> requests = new();
    readonly HashSet<string> decks = new() { "Default" };
    readonly HashSet<string> models = new() { "Basic" };
    readonly Dictionary<long, JsonObject> notes = new();
    long nextId = 1732300000000;   // ids the size Anki's are
    TcpListener? listener;
    Thread? thread;

    public FakeAnkiConnect(string record) { this.record = record; }

    public int Count { get { lock (requests) return requests.Count; } }
    public long LastId { get { lock (requests) return nextId; } }
    public List<JsonObject> Since(int n) { lock (requests) return requests.Skip(n).Select(r => r.DeepClone().AsObject()).ToList(); }

    public void Start()
    {
        listener = new TcpListener(IPAddress.Loopback, 8765);
        listener.Start();
        thread = new Thread(Serve) { IsBackground = true };
        thread.Start();
        Console.WriteLine("[4-anki] stand-in AnkiConnect on 127.0.0.1:8765");
    }

    public void Stop()
    {
        try { listener?.Stop(); } catch { }
        listener = null;
        Console.WriteLine("[4-anki] stand-in AnkiConnect stopped");
    }

    public void Dispose() => Stop();

    void Serve()
    {
        while (listener is TcpListener l)
        {
            TcpClient client;
            try { client = l.AcceptTcpClient(); } catch { return; }
            try { using (client) Answer(client.GetStream()); }
            catch (Exception e) { Console.WriteLine("[4-anki] stand-in: " + e.Message); }
        }
    }

    void Answer(NetworkStream stream)
    {
        stream.ReadTimeout = 5000;
        var head = new List<byte>();
        while (head.Count < 4 || head[^4] != '\r' || head[^3] != '\n' || head[^2] != '\r' || head[^1] != '\n')
        {
            var b = stream.ReadByte();
            if (b < 0) return;
            head.Add((byte)b);
        }
        var headers = Encoding.ASCII.GetString(head.ToArray()).Split("\r\n");
        string? Header(string name) => headers.FirstOrDefault(h => h.StartsWith(name + ":", StringComparison.OrdinalIgnoreCase))?.Substring(name.Length + 1).Trim();
        if (Header("Expect")?.Equals("100-continue", StringComparison.OrdinalIgnoreCase) == true)
            stream.Write(Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n"));
        var length = int.Parse(Header("Content-Length") ?? "0");
        var body = new byte[length];
        for (var read = 0; read < length;)
        {
            var n = stream.Read(body, read, length - read);
            if (n <= 0) return;
            read += n;
        }
        var request = JsonNode.Parse(body) as JsonObject ?? new JsonObject();
        lock (requests)
        {
            requests.Add(request);
            File.AppendAllText(record, request.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n");
        }
        JsonNode? result;
        string? error = null;
        lock (requests) result = Act((string?)request["action"] ?? "", request["params"] as JsonObject ?? new JsonObject(), ref error);
        var reply = Encoding.UTF8.GetBytes(new JsonObject { ["result"] = result, ["error"] = error }.ToJsonString());
        stream.Write(Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {reply.Length}\r\nConnection: close\r\n\r\n"));
        stream.Write(reply);
    }

    JsonNode? Act(string action, JsonObject p, ref string? error)
    {
        switch (action)
        {
            case "deckNames": return new JsonArray(decks.Select(d => (JsonNode)d).ToArray());
            case "modelNames": return new JsonArray(models.Select(d => (JsonNode)d).ToArray());
            case "createModel": models.Add((string?)p["modelName"] ?? ""); return new JsonObject { ["name"] = (string?)p["modelName"] };
            case "createDeck": decks.Add((string?)p["deck"] ?? ""); return 1;
            case "findNotes": return new JsonArray(Find((string?)p["query"] ?? "").Select(i => (JsonNode)i).ToArray());
            case "notesInfo":
                return new JsonArray(p["notes"]!.AsArray().Select(n => (long)n!).Where(notes.ContainsKey).Select(i => (JsonNode)new JsonObject
                {
                    ["noteId"] = i,
                    ["fields"] = new JsonObject(notes[i]["fields"]!.AsObject().Select(f => KeyValuePair.Create(f.Key, (JsonNode?)new JsonObject { ["value"] = f.Value?.DeepClone() }))),
                }).ToArray());
            case "addNote":
                var note = p["note"]!.AsObject();
                if (!models.Contains((string?)note["modelName"] ?? "")) { error = "model was not found: " + note["modelName"]; return null; }
                if (!decks.Contains((string?)note["deckName"] ?? "")) { error = "deck was not found: " + note["deckName"]; return null; }
                if (notes.Values.Any(n => (string?)n["deckName"] == (string?)note["deckName"] && Plain((string?)n["fields"]?["Chinese"]) == Plain((string?)note["fields"]?["Chinese"])))
                { error = "cannot create note because it is a duplicate"; return null; }
                nextId++;
                notes[nextId] = note.DeepClone().AsObject();
                return nextId;
            case "guiBrowse": return new JsonArray();
            default: error = "unsupported action"; return null;
        }
    }

    static string Plain(string? field) => System.Text.RegularExpressions.Regex.Replace(field ?? "", "<[^>]*>", "").Replace("&nbsp;", " ").Trim();

    /// Anki's search, for the queries the app makes: quoted deck:, note:, Chinese: and nid: terms.
    IEnumerable<long> Find(string query)
    {
        var terms = System.Text.RegularExpressions.Regex.Matches(query, "\"((?:[^\"\\\\]|\\\\.)*)\"|(\\S+)")
            .Select(m => System.Text.RegularExpressions.Regex.Replace(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value, "\\\\(.)", "$1")).ToList();
        foreach (var (id, n) in notes)
        {
            var ok = true;
            foreach (var t in terms)
            {
                var colon = t.IndexOf(':');
                if (colon < 0) continue;
                var (k, v) = (t[..colon], t[(colon + 1)..]);
                if (k == "deck" && (string?)n["deckName"] != v) ok = false;
                if (k == "note" && (string?)n["modelName"] != v) ok = false;
                if (k == "nid" && id.ToString() != v) ok = false;
                if (k == "Chinese")
                {
                    var f = (string?)n["fields"]?["Chinese"] ?? "";
                    if (v.Length > 1 && v.StartsWith('*') && v.EndsWith('*') ? !f.Contains(v[1..^1]) : f != v) ok = false;
                }
            }
            if (ok) yield return id;
        }
    }
}
