using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace Longyan;

/// Add to Anki, as on the Mac (notes/design-anki-tones.md): the core talks to AnkiConnect, the
/// Anki add-on that answers on 127.0.0.1:8765 while Anki is open, and decides everything the
/// card's button does (Sources/LongyanBridge/BridgeAnki.swift over LongyanCore/Anki.swift).
/// Cards show the button only while AnkiConnect answers, so people without Anki never see it.
/// Nothing leaves this computer.
///
/// For the settings window: Available, Decks, Deck (get and set), DefaultDeck, SetupHelp,
/// Check(force: true) when it opens, and Changed, raised when Available or Decks change.
static class Anki
{
    public const string DefaultDeck = "Longyan Reader";

    /// What to tell someone who wants Add to Anki and doesn't see it.
    public const string SetupHelp = "Add to Anki shows on cards while Anki is open with the AnkiConnect add-on. " +
        "To install it, in Anki choose Tools > Add-ons > Get Add-ons and enter 2055492159, then restart Anki.";

    /// Whether AnkiConnect answered the last check. A card takes this as it opens.
    public static bool Available { get; private set; }
    /// Anki's decks, from the last check that found Anki.
    public static IReadOnlyList<string> Decks { get; private set; } = Array.Empty<string>();
    /// Available or Decks changed.
    public static event Action? Changed;

    /// The deck cards go into (the Mac's Anki Deck menu). It's made in Anki with the first card.
    public static string Deck
    {
        get => Settings.AnkiDeck ?? DefaultDeck;
        set
        {
            var deck = string.IsNullOrWhiteSpace(value) ? DefaultDeck : value.Trim();
            Settings.AnkiDeck = deck == DefaultDeck ? null : deck;
            if (started) Native.ly_anki_set_deck(Bridge.Utf8(deck));
            else Start();
        }
    }

    static bool started;
    static readonly Native.Callback callback = OnEvent;   // kept alive for as long as the bridge may call it
    static readonly Dictionary<long, Action<string, string>> buttons = new();

    /// Asks AnkiConnect at once. Call after the core has started; the app does at launch.
    public static void Start()
    {
        if (started) return;
        started = true;
        try { Native.ly_anki_start(callback, Bridge.Utf8(Deck)); }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { Diagnostics.Write("Anki: " + e.Message); }
    }

    /// Asks AnkiConnect again, at most every 10 s unless `force`: when a card opens, when the
    /// eye appears, when the menu or settings open.
    public static void Check(bool force = false)
    {
        if (!started) { Start(); return; }
        Native.ly_anki_check(force ? 1 : 0);
    }

    /// The card `id` shows the Anki button: `changed` gets its state ("ready", "adding",
    /// "added", "failed" with why, or "none" when there's nothing to add) now and on every change.
    public static void Open(long id, Action<string, string> changed)
    {
        Start();
        buttons[id] = changed;
        Native.ly_anki_open(id);
    }

    public static void Click(long id) { if (buttons.ContainsKey(id)) Native.ly_anki_click(id); }

    public static void Close(long id)
    {
        if (buttons.Remove(id)) Native.ly_anki_close(id);
    }

    /// Whether the card has something to add, as the core's ankiNote decides: a word with a
    /// meaning or a dictionary sense, a phrase unless its translation failed.
    public static bool HasNote(JsonObject card) => (string?)card["kind"] == "phrase"
        ? card["translationError"] == null
        : card["meaning"] != null || card["senses"] is JsonArray { Count: > 0 };

    // Called from native code: an exception must not get past it.
    static void OnEvent(IntPtr json)
    {
        try { Handle(Bridge.FromUtf8(json)); }
        catch (Exception e) { Diagnostics.Write("error handling an Anki event: " + Diagnostics.Describe(e)); }
    }

    static void Handle(string text)
    {
        Core.Log(text);
        if (JsonNode.Parse(text) is not JsonObject e) return;
        switch ((string?)e["event"])
        {
            case "anki":
                var available = (bool?)e["available"] == true;
                var decks = (e["decks"] as JsonArray ?? new JsonArray()).Select(d => (string?)d).OfType<string>().ToList();
                if (available != Available) Diagnostics.Write(available ? "Anki: AnkiConnect answers" : "Anki: AnkiConnect doesn't answer");
                if (available == Available && decks.SequenceEqual(Decks)) return;
                Available = available;
                Decks = decks;
                Changed?.Invoke();
                break;
            case "anki-button":
                if (e["id"] is JsonValue v && v.TryGetValue<long>(out var id) && buttons.TryGetValue(id, out var changed))
                    changed((string?)e["state"] ?? "none", (string?)e["message"] ?? "");
                break;
        }
    }

    static class Native
    {
        const string Dll = "LongyanBridge.dll";

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void Callback(IntPtr json);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void ly_anki_start(Callback cb, byte[] deck);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void ly_anki_check(int force);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void ly_anki_set_deck(byte[] deck);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void ly_anki_open(long id);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void ly_anki_click(long id);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern void ly_anki_close(long id);
    }
}
