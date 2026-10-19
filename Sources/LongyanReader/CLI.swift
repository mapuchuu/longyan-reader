import AppKit
import SwiftUI
import Foundation
import PDFKit

/// Command-line modes for testing the pipeline without the hotkey or screen.
///   --status
///   --lookup "<passage>" <word-or-character-index>
///   --phrase "<text>"
///   --render "<passage>" <word> <out.png>
///   --render-phrase "<text>" <out.png> [word-to-expand]
enum CLI {
    /// Keeps the main thread free (SwiftUI rendering needs it) and exits when done.
    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            do { try await dispatch(args) } catch { print("error:", error.localizedDescription) }
            exit(0)
        }
        // Not dispatchMain(): it exits the main thread, and AppKit then refuses to draw.
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    private static func dispatch(_ args: [String]) async throws {
        switch args[1] {
        case "--status":
            let t = Date()
            let dict = try CEDict.load()
            print("dictionary: \(dict.entryCount) entries, longest word \(dict.maxWordLength) chars, loaded in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
            print("sense chooser: \(SenseChooser.unavailableReason)")
        case "--lookup" where args.count >= 4:
            let dict = try CEDict.load()
            let passage = Array(args[2])
            let index: Int
            if let n = Int(args[3]) { index = n }
            else if let r = args[2].range(of: args[3]) { index = args[2].distance(from: args[2].startIndex, to: r.lowerBound) }
            else { print("word not in passage"); return }
            try await lookup(passage: passage, index: index, dict: dict)
        case "--phrase" where args.count >= 3:
            let dict = try CEDict.load()
            let passage = Array(args[2])
            let tokens = Segmenter.phrase(0..<passage.count, in: passage, dict: dict)
            let t = Date()
            let translation = try await Translator.translate(args[2])
            print("translation: \(translation)  [\(Int(Date().timeIntervalSince(t) * 1000)) ms]")
            print("words: " + tokens.map { token -> String in
                let senses = dict.senses(for: token.text)
                let i = SenseChooser.senseMatching(translation: translation, senses: senses)
                return "\(token.text) (\(shortGloss(i.map { [senses[$0]] } ?? senses)))"
            }.joined(separator: " / "))
        case "--render-phrase" where args.count >= 4:
            try await renderPhrase(args[2], expand: args.count >= 5 ? args[4] : nil, to: URL(fileURLWithPath: args[3]))
        case "--pdf-context" where args.count >= 5:
            // --pdf-context file.pdf <page index> "<selected text>"
            guard let doc = PDFDocument(url: URL(fileURLWithPath: args[2])), let i = Int(args[3]),
                  let raw = doc.page(at: i)?.string else { print("can't read page"); return }
            let text = Array(SelectionReader.joinLines(raw))
            guard let r = SelectionReader.find(args[4], in: text) else { print("selection not found"); return }
            let lo = max(0, r.lowerBound - 40), hi = min(text.count, r.upperBound + 40)
            print("found at \(r): …" + String(text[lo..<r.lowerBound]) + "【" + String(text[r]) + "】" + String(text[r.upperBound..<hi]) + "…")
        case "--render" where args.count >= 5:
            try await render(passage: args[2], click: args[3], to: URL(fileURLWithPath: args[4]))
        case "--eval":
            try await eval(dict: try CEDict.load())
        default:
            print("usage: LongyanReader --status | --lookup \"<passage>\" <word|index> | --phrase \"<text>\" | --eval | --render … | --render-phrase …")
        }
    }

    private static func lookup(passage: [Character], index: Int, dict: CEDict) async throws {
        guard let ctx = Segmenter.word(at: index, in: passage, dict: dict) else { print("no Chinese word at index \(index)"); return }
        let senses = dict.senses(for: ctx.word)
        print("word: \(ctx.word)  alternatives: \(ctx.alternatives)")
        print("sentence: \(ctx.sentence)")
        for (i, s) in senses.enumerated() { print("  \(i + 1). [\(Pinyin.marked(s.pinyin))] \(s.gloss)") }
        guard SenseChooser.isAvailable, !senses.isEmpty else { print("sense chooser: \(SenseChooser.unavailableReason)"); return }
        let t = Date()
        let c = try await SenseChooser.choose(for: ctx, senses: senses)
        print("chosen: \(c.senseNumber). \(senses[c.senseNumber - 1].gloss)  [\(Int(Date().timeIntervalSince(t) * 1000)) ms]")
        print("meaning here: \(c.meaningHere)")
        print("tag: \(c.tag.rawValue)\(c.note.isEmpty ? "" : "\nnote: \(c.note)")")
    }

    /// Hand-labelled cases: (passage, clicked text, expected word, expected sense substring, tag that should appear or nil).
    static let cases: [(String, String, String, String, NuanceTag?)] = [
        ("我们研究生命的起源。", "生", "生命", "life", nil),
        ("他是研究生。", "生", "研究生", "graduate student", nil),
        ("这个办法行不行？", "行", "行", "OK", nil),
        ("他在银行工作。", "行", "银行", "bank", nil),
        ("我已经吃了饭了。", "了", "了", "completed action", nil),
        ("他长得很高。", "长", "长得", "to look", nil),
        ("这条路很长。", "长", "长", "long", nil),
        ("他是我们的校长。", "长", "校长", "head", nil),
        ("他靠关系找到了工作。", "关系", "关系", "connection", .culturalContext),
        ("他们掠夺了村庄的粮食。", "掠夺", "掠夺", "plunder", nil),
        ("明朝实行海禁，闭关锁国。", "闭关锁国", "闭关锁国", "close", .culturalContext),
        ("有识之士都应该站出来说话。", "识", "有识之士", "knowledge", nil),
        ("他打了一个电话。", "打", "打", "", nil),
        ("这本书很有意思。", "意思", "有意思", "interesting", nil),
        ("你这是什么意思？", "意思", "意思", "meaning", nil),
        ("春节的时候大家都回家过年。", "过年", "过年", "New Year", .culturalContext),
    ]

    static func eval(dict: CEDict) async throws {
        var wordOK = 0, senseOK = 0, failures = 0, totalMs = 0
        for (passage, click, wantWord, wantSense, _) in cases {
            let index = passage.distance(from: passage.startIndex, to: passage.range(of: click)!.lowerBound)
            guard let ctx = Segmenter.word(at: index, in: Array(passage), dict: dict) else { continue }
            let senses = dict.senses(for: ctx.word)
            let w = ctx.word == wantWord
            if w { wordOK += 1 }
            var line = "\(w ? "✓" : "✗") \(ctx.word)"
            do {
                let t = Date()
                let c = try await SenseChooser.choose(for: ctx, senses: senses)
                totalMs += Int(Date().timeIntervalSince(t) * 1000)
                let gloss = senses[c.senseNumber - 1].gloss
                let s = wantSense.isEmpty || gloss.localizedCaseInsensitiveContains(wantSense)
                if s { senseOK += 1 }
                line += "  sense \(s ? "✓" : "✗") [\(Pinyin.marked(senses[c.senseNumber - 1].pinyin))] \(gloss)  | here: \(c.meaningHere)\(c.viaTranslation ? " (via translation)" : "")"
                if !c.note.isEmpty { line += "\n      note: \(c.note)" }
            } catch {
                failures += 1
                line += "  ERROR \(error)"
            }
            print("\(passage)  \(line)")
        }
        let n = cases.count
        print("\nwords \(wordOK)/\(n)  senses \(senseOK)/\(n)  errors \(failures)  avg \(totalMs / max(n - failures, 1)) ms")
    }

    /// Draws the popup for a lookup into a PNG, to check the design without the hotkey.
    @MainActor
    static func render(passage: String, click: String, to url: URL) async throws {
        let dict = try CEDict.load()
        guard let r = passage.range(of: click),
              let ctx = Segmenter.word(at: passage.distance(from: passage.startIndex, to: r.lowerBound), in: Array(passage), dict: dict)
        else { print("no word"); return }
        let senses = dict.senses(for: ctx.word)
        let state = LookupState(context: ctx, senses: senses, appName: "Preview", phase: .choosing)
        if SenseChooser.isAvailable, !senses.isEmpty {
            state.choice = try await SenseChooser.choose(for: ctx, senses: senses)
            state.phase = .chosen
        }
        try await writePNG(LookupView(state: state), to: url)
        print("wrote \(url.path)")
    }

    @MainActor
    static func renderPhrase(_ text: String, expand: String?, to url: URL) async throws {
        let dict = try CEDict.load()
        let passage = Array(text)
        let selection = Selection(passage: passage, range: 0..<passage.count, bounds: nil, source: .accessibility, appName: "Safari")
        let state = PhraseState(selection: selection, dict: dict, sourceNote: nil)
        state.translation = try? await Translator.translate(text)
        if let expand, let token = state.tokens.first(where: { $0.text == expand }) {
            state.toggle(token)
            while state.choosing.contains(token.id) { try await Task.sleep(for: .milliseconds(50)) }
        }
        try await writePNG(PhraseView(state: state), to: url)
        print("wrote \(url.path)")
    }

    /// AppKit drawing must happen on the main thread.
    @MainActor
    static func writePNG<V: View>(_ view: V, to url: URL) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.padding(12).background(Color(nsColor: .underPageBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
