using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;

namespace Longyan;

/// The app's settings, kept in %LOCALAPPDATA%\LongyanReader\settings.json (the Mac keeps the
/// same ones in UserDefaults). Missing or unreadable means the defaults.
static class Settings
{
    static readonly string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LongyanReader", "settings.json");
    static readonly JsonObject data = Load();

    /// The eye by a fresh selection (the Mac's "showChip"), on unless turned off.
    public static bool ShowEye
    {
        get => data["showEye"] is JsonValue v && v.TryGetValue<bool>(out var on) ? on : true;
        set { data["showEye"] = value; Save(); }
    }

    /// Apps the eye stays out of: the process name (lower case) and the name to show.
    public static IReadOnlyList<(string Process, string Name)> EyeHiddenApps =>
        (data["eyeHiddenApps"] as JsonArray ?? new JsonArray())
            .OfType<JsonObject>()
            .Select(o => (Text(o["process"]), Text(o["name"])))
            .Where(a => a.Item1.Length > 0)
            .ToList();

    /// The shortcut the reader picked (RegisterHotKey's modifiers and virtual key), or null to
    /// use the default (Shortcut.Default).
    public static (uint Modifiers, uint Key)? ChosenShortcut
    {
        get => data["shortcut"] is JsonObject o && o["modifiers"] is JsonValue m && m.TryGetValue<uint>(out var mods)
            && o["key"] is JsonValue k && k.TryGetValue<uint>(out var key) && key != 0 ? (mods, key) : null;
        set
        {
            if (value is (uint mods, uint key)) data["shortcut"] = new JsonObject { ["modifiers"] = mods, ["key"] = key };
            else data.Remove("shortcut");
            Save();
        }
    }

    static string Text(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var t) ? t : "";

    public static bool EyeHiddenIn(string process) => EyeHiddenApps.Any(a => a.Process == process);

    public static void HideEyeIn(string process, string name)
    {
        if (EyeHiddenIn(process)) return;
        if (data["eyeHiddenApps"] is not JsonArray list) data["eyeHiddenApps"] = list = new JsonArray();
        list.Add(new JsonObject { ["process"] = process, ["name"] = name });
        Save();
    }

    public static void ShowEyeIn(string process)
    {
        if (data["eyeHiddenApps"] is not JsonArray list) return;
        foreach (var o in list.OfType<JsonObject>().Where(o => Text(o["process"]) == process).ToList()) list.Remove(o);
        Save();
    }

    static JsonObject Load()
    {
        try { return File.Exists(path) && JsonNode.Parse(File.ReadAllText(path)) is JsonObject o ? o : new JsonObject(); }
        catch { return new JsonObject(); }
    }

    static void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, data.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, path, overwrite: true);
        }
        catch { }
    }

    // History (History.cs): "off", "days30" or "all", the Mac's lookupHistory. Kept whole unless changed.
    public static string HistoryKeep
    {
        get => Text(data["lookupHistory"]) is "off" or "days30" or "all" ? Text(data["lookupHistory"]) : "all";
        set { data["lookupHistory"] = value; Save(); }
    }
}
