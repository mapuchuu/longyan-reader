using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace Longyan;

/// One lookup as the History window shows it: a word with the meaning it had in its sentence,
/// or a phrase with its translation (the Mac's HistoryEntry).
sealed record HistoryEntry(int Id, DateTime Date, string Kind, string Text, string Pinyin, string Meaning, string Gloss, string Sentence)
{
    public bool IsWord => Kind == "word";
    public string Key => Kind + "|" + Text + "|" + Sentence;
    public override string ToString() => Text;
}

/// The lookup history, as on the Mac: one JSON line per lookup in
/// %LOCALAPPDATA%\LongyanReader\History\lookups.jsonl, on this PC only, in the Mac's format.
/// On unless turned off; "30 days" drops older lines. A word's record is written when its card
/// opens, and a "pick" record each time its meaning changes after (the model's pick or the
/// reader's), which replaces the meaning. A phrase's record is written once its translation is in.
static class History
{
    public static string Directory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "History");
    public static string FilePath => Path.Combine(Directory, "lookups.jsonl");

    /// "off", "days30" or "all" (the Mac's lookupHistory setting).
    public static string Keep
    {
        get => Settings.HistoryKeep;
        set { Settings.HistoryKeep = value; Trim(); }
    }
    public static bool IsOn => Keep != "off";

    /// After a write, a delete or a clear: the window reloads.
    public static event Action? Changed;

    // MARK: Recording

    static Selected? opening;          // the selection of the card being opened
    static string? openingApp;
    static Selected? lastPassage;      // for cards opened from another ("part of")
    static string? lastApp;
    static readonly Dictionary<long, Seen> seen = new();
    static bool trimmed;

    sealed class Seen
    {
        public string Kind = "", Text = "", Sentence = "", Meaning = "";
        public bool Written;
        public JsonObject? Phrase;     // a phrase card not yet written
    }

    /// App.Present: the next new card is for this selection.
    public static void Opening(Selected selected)
    {
        opening = selected;
        try { openingApp = ForegroundApp.Get() is { } app ? ForegroundApp.NameOf(app.Path) : null; } catch { openingApp = null; }
    }

    /// CardWindow.Update: a card's contents, now and on every change.
    public static void Saw(long id, JsonObject card)
    {
        try { See(id, card); }
        catch (Exception e) { Diagnostics.Write("history: " + Diagnostics.Describe(e)); }
    }

    static void See(long id, JsonObject card)
    {
        if (id == 0) return;
        if (!seen.TryGetValue(id, out var s))
        {
            // A new card: one that wasn't written yet is written now, as the Mac does for a card
            // replaced before its answer came (a phrase only if it got its translation).
            foreach (var old in seen.Values) if (old.Phrase != null) WritePhrase(old, old.Phrase, force: true);
            seen.Clear();
            if (opening != null) { lastPassage = opening; lastApp = openingApp; opening = null; }
            s = new Seen { Kind = Str(card["kind"]) };
            seen[id] = s;
        }
        if (s.Kind == "phrase")
        {
            if (!s.Written) WritePhrase(s, card, force: false);
            return;
        }
        if (s.Kind != "word") return;
        var (pinyin, meaning, gloss) = WordMeaning(card);
        if (!s.Written)
        {
            s.Text = Str(card["word"]);
            if (s.Text.Length == 0) return;
            s.Sentence = SentenceOf(s.Text, lastPassage);
            s.Meaning = meaning;
            s.Written = true;
            Write(new JsonObject
            {
                ["event"] = "word", ["word"] = s.Text, ["sentence"] = s.Sentence, ["app"] = lastApp ?? "",
                ["meaningHere"] = meaning, ["pinyin"] = pinyin, ["gloss"] = gloss,
            });
            return;
        }
        if (Str(card["meaning"]).Length == 0 || meaning == s.Meaning) return;
        s.Meaning = meaning;
        Write(new JsonObject { ["event"] = "pick", ["word"] = s.Text, ["sentence"] = s.Sentence, ["meaning"] = meaning, ["pinyin"] = pinyin, ["gloss"] = gloss });
    }

    static void WritePhrase(Seen s, JsonObject card, bool force)
    {
        var translation = Str(card["translation"]);
        var settled = (translation.Length > 0 || card["translationError"] != null)
            && !(card["rows"] as JsonArray ?? new JsonArray()).Any(r => r?["pending"] is JsonValue v && v.TryGetValue<bool>(out var p) && p);
        if (!settled && !(force && translation.Length > 0)) { s.Phrase = card; return; }
        s.Phrase = null;
        s.Written = true;
        var text = Str(card["text"]);
        if (text.Length == 0) return;
        var words = new JsonArray();
        foreach (var r in card["rows"] as JsonArray ?? new JsonArray()) words.Add(Str(r?["text"]));
        Write(new JsonObject { ["event"] = "phrase", ["text"] = text, ["words"] = words, ["translation"] = translation, ["app"] = lastApp ?? "" });
    }

    /// The word card's pinyin, its meaning here and the full dictionary sense: the chosen
    /// meaning's, else the first meaning's (as the Mac fills a lookup made without the model).
    static (string Pinyin, string Meaning, string Gloss) WordMeaning(JsonObject card)
    {
        var syllables = (card["pinyin"] as JsonArray ?? new JsonArray()).Select(p => Str(p?["text"])).Where(t => t.Length > 0);
        var pinyin = string.Join(" ", syllables);
        var senses = (card["senses"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
        var chosen = senses.FirstOrDefault(r => r["chosen"] is JsonValue v && v.TryGetValue<bool>(out var c) && c)
            ?? senses.FirstOrDefault(r => r["index"] is JsonValue v && v.TryGetValue<int>(out var i) && i == 0);
        var meaning = Str(card["meaning"]);
        if (meaning.Length == 0) meaning = Str(chosen?["gloss"]);
        return (pinyin, meaning, Str(chosen?["tip"]));
    }

    /// The sentence around the word, as the core's WordInContext.sentence finds it: back and on
    /// to the nearest stop (at most 160 either way), with the closing punctuation.
    public static string SentenceOf(string word, Selected? s)
    {
        if (s == null || word.Length == 0) return word;
        var p = s.Passage;
        // The word where the selection is: the occurrence that overlaps it, else the nearest.
        int at = -1, best = int.MaxValue;
        for (var i = p.IndexOf(word, StringComparison.Ordinal); i >= 0; i = p.IndexOf(word, i + 1, StringComparison.Ordinal))
        {
            var d = i + word.Length <= s.Start ? s.Start - (i + word.Length) + 1 : i >= s.End ? i - s.End + 1 : 0;
            if (d < best) { best = d; at = i; }
        }
        if (at < 0) return word;
        const string stops = "。！？；!?;\n\r ";
        int lo = at, hi = at + word.Length;
        while (lo > 0 && !stops.Contains(p[lo - 1]) && at - lo < 160) lo--;
        while (hi < p.Length && !stops.Contains(p[hi]) && hi - (at + word.Length) < 160) hi++;
        if (hi < p.Length) hi++;   // keep the closing punctuation
        return p.Substring(lo, hi - lo).Trim();
    }

    static string Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var t) ? t : "";

    // MARK: The file

    static readonly JsonSerializerOptions compact = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// Appends one record, stamped with the time, as the Mac's Log.write does.
    static void Write(JsonObject record)
    {
        if (!IsOn) return;
        if (!trimmed) { trimmed = true; Trim(); }
        record["at"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        // Keys in order, as the Mac writes them.
        var sorted = new JsonObject();
        foreach (var kv in record.OrderBy(kv => kv.Key, StringComparer.Ordinal).ToList()) { record.Remove(kv.Key); sorted[kv.Key] = kv.Value; }
        var line = Encoding.UTF8.GetBytes(sorted.ToJsonString(compact) + "\n");
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            using var f = new FileStream(FilePath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
            // A line cut off by a crash ends first, so it doesn't swallow this one.
            if (f.Length > 0)
            {
                f.Seek(-1, SeekOrigin.End);
                if (f.ReadByte() != '\n') f.WriteByte((byte)'\n');
            }
            f.Seek(0, SeekOrigin.End);
            f.Write(line);
        }
        catch (Exception e) { Diagnostics.Write("history: couldn't write a lookup: " + e.GetType().Name); return; }
        Changed?.Invoke();
    }

    /// The history's lines, or none. A byte that isn't UTF-8 spoils only its own line.
    static string[] Lines()
    {
        try { return File.Exists(FilePath) ? File.ReadAllText(FilePath, new UTF8Encoding(false, false)).Split('\n') : Array.Empty<string>(); }
        catch { return Array.Empty<string>(); }
    }

    /// Replaces the file in one step: a crash part way leaves the old one.
    static void Replace(IEnumerable<string> lines)
    {
        var kept = lines.Where(l => l.Trim().Length > 0).ToList();
        var temp = FilePath + ".tmp";
        File.WriteAllText(temp, kept.Count == 0 ? "" : string.Join("\n", kept) + "\n", new UTF8Encoding(false));
        File.Move(temp, FilePath, overwrite: true);
    }

    static DateTime? At(string line)
    {
        var m = System.Text.RegularExpressions.Regex.Match(line, "\"at\":\"([^\"]+)\"");
        return m.Success && DateTime.TryParse(m.Groups[1].Value, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d) ? d : null;
    }

    /// With "30 days", nothing older. Runs on the first write and when History opens.
    public static void Trim()
    {
        if (Keep != "days30" || !File.Exists(FilePath)) return;
        var cutoff = DateTime.UtcNow.AddDays(-30);
        var lines = Lines().Where(l => l.Trim().Length > 0).ToList();
        var kept = lines.Where(l => At(l) is not DateTime d || d >= cutoff).ToList();
        if (kept.Count == lines.Count) return;
        try { Replace(kept); } catch (Exception e) { Diagnostics.Write("history: couldn't trim: " + e.GetType().Name); }
    }

    /// Takes entries out of the history: every line of those lookups (and their picks).
    public static void Delete(IEnumerable<HistoryEntry> entries)
    {
        var keys = entries.Select(e => e.Key).ToHashSet();
        if (keys.Count == 0) return;
        var kept = Lines().Where(l => KeyOf(l) is not string k || !keys.Contains(k));
        try { Replace(kept); } catch (Exception e) { Diagnostics.Write("history: couldn't delete: " + e.GetType().Name); }
        Changed?.Invoke();
    }

    static string? KeyOf(string line)
    {
        try
        {
            if (JsonNode.Parse(line) is not JsonObject r) return null;
            return Str(r["event"]) switch
            {
                "word" or "pick" => "word|" + Str(r["word"]) + "|" + Str(r["sentence"]),
                "phrase" => "phrase|" + Str(r["text"]) + "|" + Str(r["text"]),
                _ => null,
            };
        }
        catch { return null; }
    }

    /// Moves the history to the Recycle Bin, where it can still be restored (the Mac's Trash).
    public static void Clear()
    {
        if (File.Exists(FilePath) && !Recycle(FilePath))
        {
            try { File.Delete(FilePath); } catch (Exception e) { Diagnostics.Write("history: couldn't clear: " + e.GetType().Name); }
        }
        seen.Clear();
        Changed?.Invoke();
    }

    public static bool HasFile => File.Exists(FilePath);

    /// The entries, newest first (the Mac's HistoryReader): a later "pick" replaces its lookup's
    /// meaning, and the same word looked up again in the same sentence is one entry, dated the latest.
    public static List<HistoryEntry> Entries() => Read(Lines());

    public static List<HistoryEntry> Read(IEnumerable<string> lines)
    {
        var o = new List<HistoryEntry>();
        var n = 0;
        foreach (var line in lines)
        {
            n++;
            if (line.Trim().Length == 0) continue;
            JsonObject? r;
            try { r = JsonNode.Parse(line) as JsonObject; } catch { continue; }
            if (r == null || !DateTime.TryParse(Str(r["at"]), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var at)) continue;
            string S(string k) => Str(r[k]);
            switch (S("event"))
            {
                case "word" when S("word").Length > 0:
                    o.Add(new HistoryEntry(n, at, "word", S("word"), S("pinyin"), S("meaningHere"), S("gloss"), S("sentence")));
                    break;
                case "phrase" when S("text").Length > 0:
                    o.Add(new HistoryEntry(n, at, "phrase", S("text"), "", S("translation"), "", S("text")));
                    break;
                case "pick":
                    var i = o.FindLastIndex(e => e.IsWord && e.Text == S("word") && e.Sentence == S("sentence"));
                    if (i >= 0) o[i] = o[i] with { Pinyin = S("pinyin"), Meaning = S("meaning"), Gloss = S("gloss") };
                    break;
            }
        }
        var keys = new HashSet<string>();
        return o.OrderByDescending(e => e.Date).ThenByDescending(e => e.Id).Where(e => keys.Add(e.Key)).ToList();
    }

    // MARK: Commands

    const string ShowEvent = "LongyanReader.Windows.History";
    static bool showWhenStarted;

    /// Arguments: --render-history OUT draws the window with made-up entries (UiCheck);
    /// --history opens the running copy's History window. Null when the app should start.
    public static int? Command(string[] args)
    {
        if (args.Length == 2 && args[0] == "--render-history") return HistoryWindow.Render(args[1]);
        if (args.Length != 1 || args[0] != "--history") return null;
        if (!EventWaitHandle.TryOpenExisting(ShowEvent, out var show)) { showWhenStarted = true; return null; }
        AllowSetForegroundWindow(-1);   // so the running copy can bring its window forward
        show.Set();
        show.Dispose();
        return 0;
    }

    static EventWaitHandle? showEvent;

    /// The tray's item. Also listens for --history from another copy.
    public static System.Windows.Forms.ToolStripMenuItem MenuItem()
    {
        var app = System.Windows.Application.Current.Dispatcher;
        showEvent ??= new EventWaitHandle(false, EventResetMode.AutoReset, ShowEvent);
        ThreadPool.RegisterWaitForSingleObject(showEvent, (_, _) => app.BeginInvoke(new Action(HistoryWindow.Open)), null, Timeout.Infinite, false);
        if (showWhenStarted) app.BeginInvoke(new Action(HistoryWindow.Open));
        return new System.Windows.Forms.ToolStripMenuItem("Lookup history", null, (_, _) => HistoryWindow.Open());
    }

    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom, pTo;
        public ushort fFlags;
        public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    static bool Recycle(string path)
    {
        // FO_DELETE with FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI.
        var op = new SHFILEOPSTRUCT { wFunc = 3, pFrom = path + "\0\0", pTo = null!, fFlags = 0x40 | 0x10 | 0x4 | 0x400 };
        try { return SHFileOperation(ref op) == 0 && !op.fAnyOperationsAborted && !File.Exists(path); }
        catch { return false; }
    }
}

/// Flashcard and spreadsheet files from history entries (the Mac's HistoryExport, the same
/// files). Repeat lookups of the same word with the same meaning (or the same phrase) are one row.
static class HistoryExport
{
    public static List<HistoryEntry> Unique(IEnumerable<HistoryEntry> entries)
    {
        var seen = new HashSet<string>();
        return entries.Where(e => seen.Add(e.Kind + "|" + e.Text + "|" + e.Meaning)).ToList();
    }

    public static string Csv(IEnumerable<HistoryEntry> entries)
    {
        static string Field(string s)
        {
            // A cell starting with = + - @ is a formula to Excel, even quoted: a leading apostrophe
            // makes it plain text.
            if (s.Length > 0 && "=+-@\t\r".Contains(s[0])) s = "'" + s;
            return s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0 ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
        }
        var rows = Unique(entries).Select(e => string.Join(",", new[]
        {
            e.Date.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), e.Kind, e.Text, e.Pinyin, e.Meaning, e.Gloss, e.Sentence,
        }.Select(Field)));
        // The byte-order mark tells Excel the file is UTF-8.
        return "﻿" + string.Join("\r\n", new[] { "date,type,chinese,pinyin,meaning,dictionary,sentence" }.Concat(rows)) + "\r\n";
    }

    /// Anki's text import (File > Import): one card per word or phrase, the Chinese on the front;
    /// the back has each meaning it was looked up with, newest first, with its pinyin and the
    /// sentence, the word in bold.
    public static string Anki(IEnumerable<HistoryEntry> entries)
    {
        static string Html(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace("\"", "&quot;")
            .Replace(">", "&gt;").Replace("\t", " ").Replace("\n", " ").Replace("\r", " ");
        static string Side(HistoryEntry e)
        {
            var back = new List<string>();
            if (e.Pinyin.Length > 0) back.Add(Html(e.Pinyin));
            if (e.Meaning.Length > 0) back.Add("<b>" + Html(e.Meaning) + "</b>");
            if (e.Gloss.Length > 0 && e.Gloss.ToLowerInvariant() != e.Meaning.ToLowerInvariant()) back.Add("<small>" + Html(e.Gloss) + "</small>");
            if (e.IsWord && e.Sentence.Length > 0) back.Add(Html(e.Sentence).Replace(Html(e.Text), "<b>" + Html(e.Text) + "</b>"));
            return string.Join("<br>", back);
        }
        var order = new List<string>();
        var cards = new Dictionary<string, List<HistoryEntry>>();
        foreach (var e in Unique(entries))
        {
            var key = e.Kind + "|" + e.Text;
            if (!cards.ContainsKey(key)) { order.Add(key); cards[key] = new List<HistoryEntry>(); }
            cards[key].Add(e);
        }
        var rows = order.Select(k => string.Join("\t", Html(cards[k][0].Text), string.Join("<hr>", cards[k].Select(Side)), "longyan " + cards[k][0].Kind));
        var header = new[] { "#separator:tab", "#html:true", "#notetype:Basic", "#deck:Longyan Reader", "#tags column:3" };
        return string.Join("\n", header.Concat(rows)) + "\n";
    }
}
