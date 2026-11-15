import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One lookup as the History window shows it: a word with the meaning it had in its sentence,
/// or a phrase with its translation.
struct HistoryEntry: Identifiable, Hashable {
    enum Kind: String { case word, phrase }
    let id: Int
    let date: Date
    let kind: Kind
    let text: String
    var pinyin: String       // tone-marked; empty for phrases
    var meaning: String      // the meaning here, or the phrase's translation
    var gloss: String        // the full dictionary sense, for flashcards
    let sentence: String
}

/// Reads lookups.jsonl into entries, newest first. Word records written before pinyin and
/// gloss were logged get them from the dictionary: the sense whose short gloss is the
/// logged meaning, else the first. A reader's later pick on a card ("pick" records)
/// replaces that lookup's meaning.
enum HistoryReader {
    static func entries(dict: CEDict?) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: Log.file, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [HistoryEntry] = []
        for (n, line) in text.split(separator: "\n").enumerated() {
            guard let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = (r["at"] as? String).flatMap(iso.date) else { continue }
            let s = { (k: String) in r[k] as? String ?? "" }
            switch s("event") {
            case "word" where !s("word").isEmpty:
                var e = HistoryEntry(id: n, date: at, kind: .word, text: s("word"), pinyin: s("pinyin"),
                                     meaning: s("meaningHere"), gloss: s("gloss"), sentence: s("sentence"))
                if e.gloss.isEmpty, let dict { fill(&e, dict: dict) }
                if !e.pinyin.isEmpty, !e.pinyin.contains(where: { "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ".contains($0) }) { e.pinyin = Pinyin.marked(e.pinyin) }
                out.append(e)
            case "phrase" where !s("text").isEmpty:
                out.append(HistoryEntry(id: n, date: at, kind: .phrase, text: s("text"), pinyin: "",
                                        meaning: s("translation"), gloss: "", sentence: s("text")))
            case "pick":
                guard let i = out.lastIndex(where: { $0.kind == .word && $0.text == s("word") && $0.sentence == s("sentence") }) else { continue }
                out[i].pinyin = Pinyin.marked(s("pinyin")); out[i].meaning = s("meaning"); out[i].gloss = s("gloss")
            default: continue
            }
        }
        // The same word looked up again in the same sentence (a card reopened) is one entry,
        // dated the latest time.
        var seen: Set<String> = []
        return out.reversed().filter { seen.insert($0.kind.rawValue + "|" + $0.text + "|" + $0.sentence).inserted }
    }

    private static func fill(_ e: inout HistoryEntry, dict: CEDict) {
        let senses = dict.senses(for: e.text)
        let sense = senses.first { headlineGloss($0) == e.meaning } ?? senses.first
        guard let sense else { return }
        e.pinyin = sense.pinyin
        e.gloss = Gloss.readable(sense.gloss)
        if e.meaning.isEmpty { e.meaning = headlineGloss(sense) }
    }
}

/// Flashcard and spreadsheet files from history entries. Repeat lookups of the same word
/// with the same meaning (or the same phrase) become one row, the newest.
enum HistoryExport {
    static func unique(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.kind.rawValue + "|" + $0.text + "|" + $0.meaning).inserted }
    }

    static func csv(_ entries: [HistoryEntry]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let rows = unique(entries).map { e in
            [day.string(from: e.date), e.kind.rawValue, e.text, e.pinyin, e.meaning, e.gloss, e.sentence].map(field).joined(separator: ",")
        }
        return (["date,type,chinese,pinyin,meaning,dictionary,sentence"] + rows).joined(separator: "\r\n") + "\r\n"
    }

    /// Anki's text import (File › Import): the header lines set the separator, note type and
    /// deck, so the file imports without choosing them. One card per word or phrase (Anki
    /// matches notes by their front, so two rows for one word would overwrite each other):
    /// the front is the Chinese; the back has each meaning it was looked up with, newest
    /// first, with its pinyin and the sentence, the word in bold.
    static func anki(_ entries: [HistoryEntry]) -> String {
        func html(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        func side(_ e: HistoryEntry) -> String {
            var back: [String] = []
            if !e.pinyin.isEmpty { back.append(html(e.pinyin)) }
            if !e.meaning.isEmpty { back.append("<b>" + html(e.meaning) + "</b>") }
            if !e.gloss.isEmpty, e.gloss.lowercased() != e.meaning.lowercased() { back.append("<small>" + html(e.gloss) + "</small>") }
            if e.kind == .word, !e.sentence.isEmpty {
                back.append(html(e.sentence).replacingOccurrences(of: html(e.text), with: "<b>" + html(e.text) + "</b>"))
            }
            return back.joined(separator: "<br>")
        }
        var order: [String] = [], cards: [String: [HistoryEntry]] = [:]
        for e in unique(entries) {
            let key = e.kind.rawValue + "|" + e.text
            if cards[key] == nil { order.append(key) }
            cards[key, default: []].append(e)
        }
        let rows = order.map { key -> String in
            let group = cards[key]!
            return [html(group[0].text), group.map(side).joined(separator: "<hr>"), "longyan " + group[0].kind.rawValue].joined(separator: "\t")
        }
        let header = ["#separator:tab", "#html:true", "#notetype:Basic", "#deck:Longyan Reader", "#tags column:3"]
        return (header + rows).joined(separator: "\n") + "\n"
    }
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var search = ""
    @Published var kind: HistoryEntry.Kind? = nil
    @Published var isOn = Log.keep != .off
    let dict: () -> CEDict?
    var onChange: () -> Void = {}

    init(dict: @escaping () -> CEDict?) { self.dict = dict; reload() }

    func reload() {
        isOn = Log.keep != .off
        entries = HistoryReader.entries(dict: dict())
    }

    var shown: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            (kind == nil || e.kind == kind)
                && (q.isEmpty || [e.text, e.meaning, e.gloss, e.sentence, e.pinyin].contains { $0.lowercased().contains(q) })
        }
    }

    func turnOn() { Log.keep = .all; reload(); onChange() }

    func export(anki: Bool) {
        let rows = shown
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = anki ? "Longyan Reader flashcards.txt" : "Longyan Reader history.csv"
        panel.allowedContentTypes = [anki ? .plainText : .commaSeparatedText]
        panel.message = anki ? "In Anki, choose File › Import and pick this file; it goes into the deck \"Longyan Reader\"."
                             : "One row per word and meaning, newest first."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = anki ? HistoryExport.anki(rows) : HistoryExport.csv(rows)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.kind) {
                    Text("All").tag(HistoryEntry.Kind?.none)
                    Text("Words").tag(HistoryEntry.Kind?.some(.word))
                    Text("Phrases").tag(HistoryEntry.Kind?.some(.phrase))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search Chinese, pinyin or English", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Menu("Export") {
                    Button("Anki Flashcards…") { model.export(anki: true) }
                    Button("Spreadsheet (CSV)…") { model.export(anki: false) }
                }
                .fixedSize()
                .disabled(model.shown.isEmpty)
            }
            .padding(10)
            Divider()
            if model.entries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text(model.isOn ? "No lookups yet" : "Lookup history is off").font(.title3.weight(.semibold))
                    Text(model.isOn ? "Words and phrases you look up appear here, with the meaning they had in their sentence."
                                    : "Turn it on to keep the words and phrases you look up, on this Mac only, and export them as flashcards.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    if !model.isOn { Button("Turn On History") { model.turnOn() } }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Table(model.shown) {
                    // Long phrases and sentences are cut to fit; hovering shows them whole.
                    TableColumn("Chinese") { e in Text(e.text).font(.system(size: 15)).help(e.text) }
                        .width(min: 60, ideal: 100)
                    TableColumn("Pinyin") { e in Text(e.pinyin).foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 90)
                    TableColumn("Meaning") { e in Text(e.meaning).help(e.gloss.isEmpty ? e.meaning : e.gloss) }
                        .width(min: 100, ideal: 200)
                    TableColumn("Sentence") { e in Text(e.kind == .word ? e.sentence : "").foregroundStyle(.secondary).help(e.sentence) }
                        .width(min: 100, ideal: 250)
                    TableColumn("When") { e in Text(Self.when.string(from: e.date)).foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 120)
                }
                .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                    Button("Copy") {
                        let rows = model.shown.filter { ids.contains($0.id) }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rows.map { [$0.text, $0.pinyin, $0.meaning].filter { !$0.isEmpty }.joined(separator: "  ") }
                            .joined(separator: "\n"), forType: .string)
                    }
                }
                HStack {
                    let shown = model.shown.count
                    Text(shown == model.entries.count ? "\(shown) lookups" : "\(shown) of \(model.entries.count) lookups")
                    Spacer()
                    if !model.isOn { Text("History is off; new lookups aren't added.") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}

/// The History window, from the menu. Reloads each time it's brought forward.
@MainActor
final class HistoryWindow {
    static let shared = HistoryWindow()
    private var window: NSWindow?
    private var model: HistoryModel?

    func show(dict: @escaping () -> CEDict?, onChange: @escaping () -> Void) {
        if let window, let model {
            model.reload()
            window.makeKeyAndOrderFront(nil); NSApp.activate()
            return
        }
        let model = HistoryModel(dict: dict)
        model.onChange = onChange
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Lookup History"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HistoryView(model: model))
        w.setFrameAutosaveName("LongyanHistory")
        if !w.setFrameUsingName("LongyanHistory") { w.center() }
        window = w; self.model = model
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// After the history is cleared or its setting changes.
    func reloadIfOpen() { model?.reload() }
}
