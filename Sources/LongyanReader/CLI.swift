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
        case "--snap" where args.count >= 3:
            // --snap 电商平【台大促时】，…: prints the selection widened to whole words.
            let dict = try CEDict.load()
            for raw in args[2...] {
                guard let a = raw.firstIndex(of: "【"), let b = raw.firstIndex(of: "】") else { print("mark the selection 【】"); continue }
                let lo = raw.distance(from: raw.startIndex, to: a), hi = raw.distance(from: raw.startIndex, to: b) - 1
                let passage = Array(raw.replacingOccurrences(of: "【", with: "").replacingOccurrences(of: "】", with: ""))
                let r = Segmenter.wholeWords(lo..<hi, in: passage, dict: dict)
                print("\(String(passage[lo..<hi])) → \(String(passage[r]))")
            }
        case "--part-of" where args.count >= 3:
            // --part-of 修车已经【彻】底没戏了: the word a selected character belongs to, as its card shows it.
            let dict = try CEDict.load()
            for raw in args[2...] {
                guard let a = raw.firstIndex(of: "【") else { continue }
                let i = raw.distance(from: raw.startIndex, to: a)
                let passage = Array(raw.replacingOccurrences(of: "【", with: "").replacingOccurrences(of: "】", with: ""))
                guard let r = Segmenter.enclosingWord(of: i..<(i + 1), in: passage, dict: dict) else { print("\(passage[i])\t—"); continue }
                let word = String(passage[r]), senses = dict.senses(for: word)
                let n = NoteCues.senseNumber(word, at: r, in: passage, senses: senses) ?? 1
                print("\(passage[i])\t\(word)\t\(Gloss.short(senses[n - 1].gloss))\t(\(senses.count) senses)")
            }
        case "--segment-file" where args.count >= 3:
            // One sentence per line: prints each line's phrase-card split, for comparing segmenter changes.
            let dict = try CEDict.load()
            for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") {
                let passage = Array(String(line))
                print(Segmenter.phrase(0..<passage.count, in: passage, dict: dict).map(\.text).joined(separator: " "))
            }
        case "--eval-phrase" where args.count >= 3:
            // Word senses as a phrase card picks them, on labelled sentences.
            // --eval-phrase notes/phrase-eval.tsv [D|H]; uses the current sense picker.
            let dict = try CEDict.load()
            var right = 0, total = 0, unoffered = 0, unsplit = 0, calibration = Calibration()
            let started = Date()
            for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 4, args.count < 4 || f[0] == args[3] else { continue }
                let passage = Array(f[1]), wants = f[3].lowercased().split(separator: "|").map(String.init)
                let tokens = Segmenter.phrase(0..<passage.count, in: passage, dict: dict)
                total += 1
                guard let token = tokens.first(where: { $0.text == f[2] }) else {
                    unsplit += 1
                    print("SPLIT \(f[1]) [\(f[2])]: \(tokens.map(\.text).joined(separator: " "))")
                    continue
                }
                let senses = dict.senses(for: token.text)
                let matches = { (s: Sense) in wants.contains { s.gloss.lowercased().contains($0) } }
                if !senses.contains(where: matches) { unoffered += 1 }
                let translation = await LocalModel.isAvailable() ? nil : try? await Translator.translate(f[1])
                let picks = await PhraseState.resolve(tokens, in: passage, dict: dict, translation: translation)
                let n = senses.count == 1 ? 1 : (picks[token.id]?.senseNumber ?? 1)
                let got = senses[safe: n - 1]
                if senses.count > 1 { calibration.add(token.text, n, right: got.map(matches) ?? false) }
                if let got, matches(got) { right += 1 }
                else { print("WRONG \(f[1]) [\(f[2])] want \(f[3]), got: \(got?.gloss.prefix(60) ?? "none")\(senses.contains(where: matches) ? "" : "  (right sense not offered)")") }
            }
            calibration.report()
            print("right \(right)/\(total), right sense not offered \(unoffered), word split differently \(unsplit), \(Int(Date().timeIntervalSince(started))) s")
        case "--check-data":
            // Every override keyed to a dictionary sense still finds it: notes and examples by
            // word|pinyin|gloss, cues by gloss, sense-order lines by sense count. A dictionary
            // update that rewords a gloss would otherwise drop them silently. Exits 1 on any miss.
            let dict = try CEDict.load()
            var misses: [String] = []
            func has(_ key: String) -> Bool {
                let f = key.split(separator: "|", maxSplits: 2).map(String.init)
                return f.count == 3 && dict.senses(for: f[0], handOrdered: false).contains { $0.pinyin == f[1] && $0.gloss == f[2] }
            }
            for key in NotesStore.shared.keys where !has(key) { misses.append("note: \(key)") }
            for key in ExamplesStore.shared.keys where !has(key) { misses.append("examples: \(key)") }
            for (word, cues) in NoteCues.byWord {
                let glosses = Set(dict.senses(for: word, handOrdered: false).map(\.gloss))
                for c in cues where !glosses.contains(c.gloss) { misses.append("cue: \(word) \(c.cue) → \(c.gloss)") }
            }
            for (word, order) in SenseOrder.shared where dict.senses(for: word, handOrdered: false).count != order.count {
                misses.append("sense order: \(word) was written for \(order.count) senses, now \(dict.senses(for: word, handOrdered: false).count)")
            }
            print("notes \(NotesStore.shared.count), examples \(ExamplesStore.shared.count), cues \(NoteCues.byWord.values.map(\.count).reduce(0, +)), sense orders \(SenseOrder.shared.count): \(misses.count) unmatched")
            misses.forEach { print("  " + $0) }
            if !misses.isEmpty { exit(1) }
        case "--senses-all" where args.count >= 3:
            // Every sense of each word with its reading, before sense-order.tsv is applied
            // (LONGYAN_NO_SENSE_ORDER=1), for writing that file: --senses-all 眼 到 …
            let dict = try CEDict.load()
            for word in args.dropFirst(2) {
                let senses = dict.senses(for: word)
                print("\(word)\t\(senses.count)")
                for (i, s) in senses.enumerated() { print("  \(i + 1). [\(s.pinyin)] \(s.gloss)\(s.rare ? "  (rare)" : "")") }
            }
        case "--senses" where args.count >= 3:
            // A word's senses as the model sees them, numbered: --senses 等 [more words…]
            let dict = try CEDict.load()
            for word in args.dropFirst(2) {
                let senses = dict.senses(for: word).forModel
                print(word + "\t" + senses.enumerated().map { "\($0 + 1). \($1.gloss)" }.joined(separator: " | "))
            }
        case "--eval-real" where args.count >= 3:
            // Lookups from real reading: --eval-real notes/real-eval.tsv [P|S|T] [nocontext]
            //   P  passage with the selection in 【】, a word in it, wanted senses: the phrase card's pick
            //   S  sentence, a word in it, wanted senses: the single-word card's pick
            //   T  passage with the selection in 【】, phrases the translation must contain | …,
            //      and optionally ones it must not; `nocontext` translates the selection alone
            // Wanted senses are substrings of the dictionary sense, | separated.
            let dict = try CEDict.load()
            let only = args.count >= 4 && args[3].count == 1 ? args[3] : nil
            let withContext = !args.contains("nocontext")
            var right: [String: Int] = [:], total: [String: Int] = [:], unoffered = 0
            var ms: [String: Int] = [:], calibration = Calibration()
            for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 4, only == nil || f[0] == only else { continue }
                let kind = f[0]
                // The selection is what's between 【】; without them, the whole text.
                let raw = f[1].replacingOccurrences(of: "【", with: "").replacingOccurrences(of: "】", with: "")
                let passage = Array(raw)
                let markedLo = f[1].firstIndex(of: "【").map { f[1].distance(from: f[1].startIndex, to: $0) } ?? 0
                let markedHi = f[1].firstIndex(of: "】").map { f[1].distance(from: f[1].startIndex, to: $0) - 1 } ?? passage.count
                // Widened to whole words, as the app does (LONGYAN_NO_SNAP=1 keeps the selection as marked).
                let snapped = ProcessInfo.processInfo.environment["LONGYAN_NO_SNAP"] == nil
                    ? Segmenter.wholeWords(markedLo..<markedHi, in: passage, dict: dict) : markedLo..<markedHi
                let lo = snapped.lowerBound, hi = snapped.upperBound
                let started = Date()
                total[kind, default: 0] += 1
                defer { ms[kind, default: 0] += Int(Date().timeIntervalSince(started) * 1000) }
                if kind == "T" {
                    let selected = String(passage[lo..<hi])
                    let context = withContext ? Segmenter.translationContext(for: lo..<hi, in: passage) : nil
                    let t = (try? await LocalModel.translate(selected, context: context)) ?? ""
                    let lower = t.lowercased()
                    let must = f[3].lowercased().split(separator: "|").map(String.init)
                    let mustNot = f.count > 4 ? f[4].lowercased().split(separator: "|").map(String.init) : []
                    let ok = (must.isEmpty || must.contains { lower.contains($0) }) && !mustNot.contains { lower.contains($0) }
                    if ok { right[kind, default: 0] += 1 } else { print("WRONG T [\(selected)] want \(f[3])\(mustNot.isEmpty ? "" : ", not " + f[4]): \(t)") }
                    continue
                }
                let wants = f[3].lowercased().split(separator: "|").map(String.init)
                let matches = { (s: Sense) in wants.contains { s.gloss.lowercased().contains($0) } }
                var senses: [Sense] = [], n = 1, word = f[2]
                if kind == "P" {
                    let tokens = Segmenter.phrase(lo..<hi, in: passage, dict: dict)
                    guard let token = tokens.first(where: { $0.text == f[2] }) else {
                        print("SPLIT P [\(f[2])]: \(tokens.map(\.text).joined(separator: " "))"); continue
                    }
                    senses = dict.senses(for: token.text)
                    let picks = await PhraseState.resolve(tokens, in: passage, dict: dict)
                    n = senses.count == 1 ? 1 : (picks[token.id]?.senseNumber ?? 1)
                } else {
                    guard let at = raw.range(of: f[2]).map({ raw.distance(from: raw.startIndex, to: $0.lowerBound) }),
                          let ctx = Segmenter.word(at: at, in: passage, dict: dict) else { continue }
                    word = ctx.word
                    senses = dict.senses(for: ctx.word)
                    n = senses.count == 1 ? 1 : ((try? await SenseChooser.choose(for: ctx, senses: senses))?.senseNumber ?? 1)
                }
                if !senses.contains(where: matches) { unoffered += 1 }
                let got = senses[safe: n - 1]
                if senses.count > 1 { calibration.add(word, n, right: word == f[2] && (got.map(matches) ?? false)) }
                if word == f[2], let got, matches(got) { right[kind, default: 0] += 1 }
                else { print("WRONG \(kind) [\(word)] want \(f[3]), got: \(got?.gloss.prefix(60) ?? "none")\(senses.contains(where: matches) ? "" : "  (right sense not offered)")  …\(String(passage[max(0, lo - 12)..<min(passage.count, hi + 6)]))") }
            }
            calibration.report()
            for k in total.keys.sorted() {
                print("\(k): right \(right[k, default: 0])/\(total[k]!), \(ms[k, default: 0] / max(total[k]!, 1)) ms each")
            }
            if unoffered > 0 { print("right sense not offered: \(unoffered)") }
        case "--eval-single" where args.count >= 3:
            // The same file as --eval-phrase, picked the way a single-word card does.
            let dict = try CEDict.load()
            var right = 0, total = 0, unoffered = 0, calibration = Calibration()
            let started = Date()
            for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 4, args.count < 4 || f[0] == args[3] else { continue }
                let passage = Array(f[1]), wants = f[3].lowercased().split(separator: "|").map(String.init)
                guard let at = f[1].range(of: f[2]).map({ f[1].distance(from: f[1].startIndex, to: $0.lowerBound) }),
                      let ctx = Segmenter.word(at: at, in: passage, dict: dict) else { continue }
                total += 1
                let senses = dict.senses(for: ctx.word)
                let matches = { (s: Sense) in wants.contains { s.gloss.lowercased().contains($0) } }
                if !senses.contains(where: matches) { unoffered += 1 }
                let n = (try? await SenseChooser.choose(for: ctx, senses: senses))?.senseNumber ?? 1
                let got = senses[safe: n - 1]
                if senses.count > 1 { calibration.add(ctx.word, n, right: ctx.word == f[2] && (got.map(matches) ?? false)) }
                if ctx.word == f[2], let got, matches(got) { right += 1 }
                else { print("WRONG \(f[1]) [\(ctx.word)] want \(f[3]), got: \(got?.gloss.prefix(60) ?? "none")\(senses.contains(where: matches) ? "" : "  (right sense not offered)")") }
            }
            calibration.report()
            print("right \(right)/\(total), right sense not offered \(unoffered), \(Int(Date().timeIntervalSince(started))) s")
        case "--gloss-audit" where args.count >= 3:
            // Every sense of every word in a file of sentences, with the short meaning a card
            // would show; flags the ones that still read like a dictionary. --gloss-audit f [all]
            let dict = try CEDict.load()
            var seen: Set<String> = []
            for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") {
                let passage = Array(String(line))
                for t in Segmenter.phrase(0..<passage.count, in: passage, dict: dict) {
                    for sense in dict.senses(for: t.text) where seen.insert(t.text + sense.gloss).inserted {
                        let short = Gloss.short(sense.gloss), lower = short.lowercased()
                        let flagged = short.count > 32 || short.contains(where: isCJK)
                            || ["particle", "classifier", "marker", "used ", "variant", "suffix", "prefix", "structural", "modal", "(", "\""].contains { lower.contains($0) }
                        if flagged || args.count >= 4 { print("\(t.text)\t\(short)\t<<\(sense.gloss)>>") }
                    }
                }
            }
        case "--phrase" where args.count >= 3:
            let dict = try CEDict.load()
            let raw = Array(args[2])
            let selection = Selection(passage: raw, range: 0..<raw.count, bounds: nil, source: .accessibility, appName: nil).trimmed()
            let passage = selection.passage, text = selection.text
            let tokens = Segmenter.phrase(selection.range, in: passage, dict: dict)
            // The phrase card's pipeline: translation first, then every word's sense, streamed.
            let t = Date()
            let local = await LocalModel.isAvailable()
            let translation = local ? try await LocalModel.translate(text) : try await Translator.translate(text)
            let apple = ProcessInfo.processInfo.environment["LONGYAN_COMPARE_APPLE"] == "1" ? try? await Translator.translate(text) : nil
            print("translation: \(translation)  [\(local ? "local" : "Apple"), \(Int(Date().timeIntervalSince(t) * 1000)) ms]")
            if let apple { print("Apple:       \(apple)") }
            let r = Date()
            var firstPick: Int?
            let picks = await PhraseState.resolve(tokens, in: passage, dict: dict) { _, _ in
                if firstPick == nil { firstPick = Int(Date().timeIntervalSince(r) * 1000) }
            }
            // Exactly what each row of the card shows.
            for t in tokens {
                let list = dict.senses(for: t.text)
                let shown = picks[t.id].map { [list[$0.senseNumber - 1]] } ?? list
                let grammar = GrammarWords.entry(t.text, in: passage, at: t.range.lowerBound)
                print("  \(t.text)\t\(grammar?.summary ?? shortGloss(shown))")
            }
            print("senses: first in \(firstPick ?? 0) ms, all \(picks.count) in \(Int(Date().timeIntervalSince(r) * 1000)) ms: " + tokens.map { t in
                picks[t.id].map { "\(t.text)=\(headlineGloss(dict.senses(for: t.text)[$0.senseNumber - 1]))" } ?? t.text
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
        case "--render-onboarding" where args.count >= 4:
            // --render-onboarding <access|checking|offer|nospace|downloading|verifying|failed|done|ollama|file> out.png
            try await renderOnboarding(args[2], to: URL(fileURLWithPath: args[3]))
        case "--render-chip" where args.count >= 3:
            try await writePNG(ChipButtonView {}.frame(width: 30, height: 30), to: URL(fileURLWithPath: args[2]))
        case "--render" where args.count >= 5:
            try await render(passage: args[2], click: args[3], to: URL(fileURLWithPath: args[4]))
        case "--notes-select" where args.count >= 4:
            let words = try NotesBuilder.select(frequencyFile: URL(fileURLWithPath: args[2]), dict: try CEDict.load(),
                                                count: args.count >= 5 ? Int(args[4]) ?? 500 : 500)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(words).write(to: URL(fileURLWithPath: args[3]))
            let senses = words.map(\.senses.count).reduce(0, +)
            print("selected \(words.count) words (\(words.filter { $0.kind == "idiom" }.count) idioms), \(senses) senses")
            print("sample: " + words.prefix(40).map(\.word).joined(separator: " "))
        case "--notes-from-list" where args.count >= 4:
            let (words, missing) = NotesBuilder.fromList(try String(contentsOfFile: args[2], encoding: .utf8), dict: try CEDict.load())
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(words).write(to: URL(fileURLWithPath: args[3]))
            print("\(words.count) words (\(words.filter { $0.kind == "idiom" }.count) idioms), \(words.map(\.senses.count).reduce(0, +)) senses")
            if !missing.isEmpty { print("not in dictionary: " + missing.joined(separator: " ")) }
        case "--notes-review" where args.count >= 6:
            // --notes-review selection.json annotations.tsv notes.json review.md
            let words = try JSONDecoder().decode([NotesBuilder.PilotWord].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            var report = NotesBuilder.fromTSV(try String(contentsOfFile: args[3], encoding: .utf8), words: words)
            let written = report.notes.count
            if args.count >= 7 {
                NotesBuilder.applyCovers(try String(contentsOfFile: args[6], encoding: .utf8), to: &report, words: words)
                print("covers: \(report.notes.count - written) paraphrase senses share an existing note")
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            try enc.encode(report.notes.filter { $0.problems.isEmpty }).write(to: URL(fileURLWithPath: args[4]))
            try NotesBuilder.review(report, words: words).write(to: URL(fileURLWithPath: args[5]), atomically: true, encoding: .utf8)
            print("notes \(report.notes.count), flagged \(report.notes.filter { !$0.problems.isEmpty }.count), unmatched \(report.errored.count)")
            for e in report.errored { print("  " + e) }
            for n in report.notes where !n.problems.isEmpty { print("  flagged \(n.word) \(n.problems): \(n.note)") }
        case "--examples-build" where args.count >= 5:
            // --examples-build selection.json examples.tsv Resources/examples.json
            let words = try JSONDecoder().decode([NotesBuilder.PilotWord].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let byWord = Dictionary(words.map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })
            var map: [String: [String]] = [:]
            var unmatched: [String] = []
            let evalText = (try? String(contentsOfFile: "notes/phrase-eval.tsv", encoding: .utf8)) ?? ""
            for line in try String(contentsOfFile: args[3], encoding: .utf8).split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard cols.count == 3, let w = byWord[cols[0]], let i = Int(cols[1]),
                      let sense = w.senses.first(where: { $0.index == i }) else { unmatched.append(String(line.prefix(30))); continue }
                map[NotesStore.key(w.word, sense.pinyin, sense.gloss), default: []].append(cols[2])
                if !cols[2].contains(w.word) { unmatched.append("doesn't use the word: \(cols[2])") }
                if evalText.contains(cols[2]) { unmatched.append("reuses an eval sentence: \(cols[2])") }
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            try enc.encode(map).write(to: URL(fileURLWithPath: args[4]))
            print("\(map.values.map(\.count).reduce(0, +)) examples for \(map.count) senses; unmatched \(unmatched.count)")
            unmatched.forEach { print("  " + $0) }
        case "--notes-next" where args.count >= 4:
            // --notes-next <batch dir> <count>: starts a batch of the most looked-up unjudged words.
            let dict = try CEDict.load()
            let dir = URL(fileURLWithPath: args[2]), count = Int(args[3]) ?? 60
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var words: [NotesBuilder.PilotWord] = [], names: [String] = [], skipped: [String] = []
            var context: [String: String] = [:]
            for candidate in try NotesBuilder.nextCandidates() where words.count < count {
                let found = NotesBuilder.fromList(candidate.word, dict: dict).words
                // Place names and the like have nothing to judge. They're recorded with a
                // no-sense entry so that they don't come back in the next batch.
                if found.isEmpty { skipped.append(candidate.word); continue }
                words += found
                names.append(candidate.word)
                context[candidate.word] = candidate.sentence
            }
            let skippedWords = skipped.map { NotesBuilder.PilotWord(word: $0, rank: 0, kind: "skipped", senses: []) }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(words + skippedWords).write(to: dir.appendingPathComponent("selection.json"))
            try ("# Next words not yet judged: lookups first, then by frequency.\n" + names.joined(separator: " ") + "\n")
                .write(to: dir.appendingPathComponent("words.txt"), atomically: true, encoding: .utf8)
            let headers = ["annotations.tsv": "# word\tsense\ttag (L = lost in translation, C = cultural context)\tnote\n",
                           "note-covers.tsv": "# word\tnoted sense\tother senses that mean the same thing (the note shows for them too)\n",
                           "examples.tsv": "# word\tsense number (as in selection.json)\texample sentence. Never reuse eval sentences here.\n"]
            for (name, header) in headers where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                try header.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            for w in words {
                print(w.word + " | " + w.senses.map { "\($0.index)[\($0.pinyin)] \($0.gloss.prefix(60))" }.joined(separator: " / "))
                if let s = context[w.word], !s.isEmpty { print("    seen in: " + s) }
            }
            print("\(words.count) words, \(words.map(\.senses.count).reduce(0, +)) senses; skipped: \(skipped.joined(separator: " "))")
        case "--notes-progress":
            let judged = try NotesBuilder.judgedWords().filter { $0.kind != "skipped" }
            let notes = try JSONDecoder().decode([NotesBuilder.Note].self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/notes.json")))
            print("\(judged.count) words judged, target 5000; \(Set(notes.map(\.word)).count) words have notes (\(notes.count) notes); \(try NotesBuilder.unjudgedLookups().count) looked-up words waiting")
        case "--notes-lint":
            // --notes-lint [notes.json]: the style checks on every distinct note, with counts.
            let url = URL(fileURLWithPath: args.count >= 3 ? args[2] : "Resources/notes.json")
            let notes = try JSONDecoder().decode([NotesBuilder.Note].self, from: Data(contentsOf: url))
            var seen = Set<String>(), counts: [String: Int] = [:], flagged = 0
            for n in notes where seen.insert(n.note).inserted {
                let found = NotesBuilder.problems(in: n.note)
                if !found.isEmpty { flagged += 1 }
                for p in found { counts[p.hasPrefix("long") ? "long" : p, default: 0] += 1 }
                if args.contains("--list"), !found.isEmpty { print("\(n.word)\t\(found.joined(separator: ", "))\t\(n.note)") }
            }
            print("\(seen.count) distinct notes, \(flagged) flagged")
            for (p, c) in counts.sorted(by: { $0.value > $1.value }) { print("  \(c)\t\(p)") }
        case "--notes-merge" where args.count >= 4:
            // --notes-merge batch-notes.json batch-examples.json: adds a batch to Resources/. A sense
            // that's already there keeps its place and takes the batch's text.
            let notesURL = URL(fileURLWithPath: "Resources/notes.json"), examplesURL = URL(fileURLWithPath: "Resources/examples.json")
            func key(_ n: NotesBuilder.Note) -> String { NotesStore.key(n.word, n.pinyin, n.gloss) }
            var notes = try JSONDecoder().decode([NotesBuilder.Note].self, from: Data(contentsOf: notesURL))
            for note in try JSONDecoder().decode([NotesBuilder.Note].self, from: Data(contentsOf: URL(fileURLWithPath: args[2]))) {
                if let i = notes.firstIndex(where: { key($0) == key(note) }) { notes[i] = note } else { notes.append(note) }
            }
            var examples = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: examplesURL))
            examples.merge(try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))) { _, new in new }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            try enc.encode(notes).write(to: notesURL)
            try enc.encode(examples).write(to: examplesURL)
            print("now \(notes.count) notes across \(Set(notes.map(\.word)).count) words, examples for \(examples.count) senses")
        case "--notes-submit" where args.count >= 4:
            let words = try JSONDecoder().decode([NotesBuilder.PilotWord].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let batch = try await NotesBuilder.submit(words)
            try JSONSerialization.data(withJSONObject: batch, options: .prettyPrinted).write(to: URL(fileURLWithPath: args[3]))
            print("batch \(batch["id"] ?? "?"): \(batch["processing_status"] ?? "?"), \(words.count) requests")
        case "--notes-status" where args.count >= 3:
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as? [String: Any] ?? [:]
            let batch = try await NotesBuilder.status(id: saved["id"] as? String ?? "")
            print("\(batch["processing_status"] ?? "?") \(batch["request_counts"] ?? "")")
        case "--notes-fetch" where args.count >= 6:
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as? [String: Any] ?? [:]
            let words = try JSONDecoder().decode([NotesBuilder.PilotWord].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let report = try await NotesBuilder.fetch(id: saved["id"] as? String ?? "", words: words)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(report.notes).write(to: URL(fileURLWithPath: args[4]))
            try NotesBuilder.review(report, words: words).write(to: URL(fileURLWithPath: args[5]), atomically: true, encoding: .utf8)
            print("notes \(report.notes.count), flagged \(report.notes.filter { !$0.problems.isEmpty }.count), failed \(report.errored.count)")
        case "--history-export" where args.count >= 4:
            // --history-export anki|csv OUT: the History window's export of the whole history.
            let entries = HistoryReader.entries(dict: try CEDict.load())
            let text = args[2] == "anki" ? HistoryExport.anki(entries) : HistoryExport.csv(entries)
            try text.write(toFile: args[3], atomically: true, encoding: .utf8)
            print("\(entries.count) lookups, \(HistoryExport.unique(entries).count) rows to \(args[3])")
        case "--compile-dict" where args.count >= 3:
            // --compile-dict OUT: the text dictionary as the app's compiled file, checked word by word.
            let dict = try CEDict.load()
            print("compiled \(try dict.compile(to: URL(fileURLWithPath: args[2]))) headwords to \(args[2])")
        case "--eval-notes":
            try await evalNotes(dict: try CEDict.load())
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
        _ = await LocalModel.isAvailable()
        guard SenseChooser.canChoose, !senses.isEmpty else { print("sense chooser: \(SenseChooser.noPickerReason)"); return }
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
        // Senses that carry a prewritten note: the note only shows if the right sense is chosen.
        ("他靠关系找到了工作。", "关系", "关系", "guanxi", .culturalContext),
        ("这是一点小意思，请收下。", "意思", "小意思", "token", nil),
        ("他给医生塞了一个红包。", "红包", "红包", "bribe", .culturalContext),
        ("奶奶上个月走了，全家人都很难过。", "走", "走", "to die", .lostInTranslation),
        ("我这个人比较佛系，不想跟别人争。", "佛系", "佛系", "chill", .lostInTranslation),
        ("这条新闻太离谱了。", "离谱", "离谱", "inappropriate", .lostInTranslation),
        ("他上班的时候经常摸鱼。", "摸鱼", "摸鱼", "loaf", .lostInTranslation),
        // The noted sense is wrong here: the tie-break must not switch to it.
        ("时间不早了，我们走吧。", "走", "走", "to go", nil),
        ("他每天走路去学校。", "走", "走路", "to walk", nil),
        ("这件事跟你没关系。", "关系", "没关系", "doesn't matter", nil),
        ("我们周末去河边摸鱼。", "摸鱼", "摸鱼", "catch fish", nil),
        ("这个人很老实，从来不说谎。", "老实", "老实", "honest", nil),
        ("他太老实了，总是被人骗。", "老实", "老实", "gullible", .lostInTranslation),
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
                let hasNote = NotesStore.note(ctx.word, senses[c.senseNumber - 1]) != nil
                line += "  sense \(s ? "✓" : "✗") [\(Pinyin.marked(senses[c.senseNumber - 1].pinyin))] \(gloss)  | here: \(c.meaningHere)\(c.viaTranslation ? " (via translation)" : "")\(hasNote ? " | NOTE" : "")"
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
              var ctx = Segmenter.word(at: passage.distance(from: passage.startIndex, to: r.lowerBound), in: Array(passage), dict: dict)
        else { print("no word"); return }
        // A one-character click draws that character's card, with the word it's in.
        let at = passage.distance(from: passage.startIndex, to: r.lowerBound)
        if click.count == 1 { ctx = Segmenter.context(for: at..<(at + 1), in: Array(passage)) }
        let senses = dict.senses(for: ctx.word)
        let state = LookupState(context: ctx, senses: senses, phase: .choosing)
        _ = await LocalModel.isAvailable()
        if SenseChooser.canChoose, !senses.isEmpty, state.grammar == nil {
            state.choice = try await SenseChooser.choose(for: ctx, senses: senses)
            if let wording = ProcessInfo.processInfo.environment["LONGYAN_RENDER_MEANING"] { state.choice?.meaningHere = wording }
            state.phase = .chosen
        }
        if let w = Segmenter.enclosingWord(of: ctx.wordRange, in: ctx.passage, dict: dict) {
            let whole = Segmenter.context(for: w, in: ctx.passage), ws = dict.senses(for: whole.word)
            let c = ws.count > 1 ? try? await SenseChooser.choose(for: whole, senses: ws) : nil
            state.partOf = .init(word: whole.word, pinyin: ws[safe: (c?.senseNumber ?? 1) - 1]?.pinyin ?? "",
                                 meaning: c?.meaningHere ?? ws.first.map { Gloss.short($0.gloss) })
        }
        try await writePNG(CardChrome(layout: renderLayout(.word)) { LookupView(state: state) }, to: url)
        print("wrote \(url.path)")
    }

    @MainActor
    static func renderPhrase(_ text: String, expand: String?, to url: URL) async throws {
        let dict = try CEDict.load()
        let passage = Array(text)
        let selection = Selection(passage: passage, range: 0..<passage.count, bounds: nil, source: .accessibility, appName: "Safari")
        let state = PhraseState(selection: selection, dict: dict)
        state.translation = await LocalModel.isAvailable() ? try? await LocalModel.translate(text) : try? await Translator.translate(text)
        // LONGYAN_RENDER_PENDING=1 draws the card as it looks while senses are still being chosen.
        if ProcessInfo.processInfo.environment["LONGYAN_RENDER_PENDING"] == "1" { state.resolving = true }
        else { state.apply(await PhraseState.resolve(state.tokens, in: passage, dict: dict)) }
        if let expand, let token = state.tokens.first(where: { $0.text == expand }) {
            state.toggle(token)
            while state.choosing.contains(token.id) { try await Task.sleep(for: .milliseconds(50)) }
        }
        try await writePNG(CardChrome(layout: renderLayout(.phrase)) { PhraseView(state: state) }, to: url)
        print("wrote \(url.path)")
    }

    @MainActor
    static func renderOnboarding(_ state: String, to url: URL) async throws {
        let m: OnboardingModel = switch state {
            case "access": .init(trusted: false, download: .idle, found: nil)
            case "checking": .init(trusted: true, download: .idle, found: nil)
            case "nospace": .init(trusted: true, download: .idle, found: false, spaceProblem: "needs 3.7 GB free and the disk has 2.1 GB")
            case "downloading": .init(trusted: true, download: .downloading(0.42), found: false, timeLeft: "About 4 minutes left")
            case "verifying": .init(trusted: true, download: .verifying, found: false)
            case "failed": .init(trusted: true, download: .failed("The network connection was lost."), found: false)
            case "done": .init(trusted: true, download: .done, found: true)
            case "ollama": .init(trusted: true, download: .idle, found: true, ollama: true)
            case "file": .init(trusted: true, download: .idle, found: true)
            default: .init(trusted: true, download: .idle, found: false)
            }
        try await writePNG(OnboardingView(model: m) {}.background(Color(nsColor: .windowBackgroundColor)), to: url)
    }

    /// AppKit drawing must happen on the main thread.
    @MainActor
    static func writePNG<V: View>(_ view: V, to url: URL) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.renderingSnapshot, true)
            .padding(12).background(Color(nsColor: .underPageBackgroundColor)))
        if let mode = ProcessInfo.processInfo.environment["LONGYAN_APPEARANCE"] {
            host.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Held-out sentences (never used as examples) for words with a noted sense.
    /// (passage, word, expected gloss substring, should the noted sense win?)
    static let noteCases: [(String, String, String, Bool)] = [
        ("奶奶上个月走了，全家人都很难过。", "走", "to die", true),
        ("他父亲前年就走了，是癌症。", "走", "to die", true),
        ("时间不早了，我们走吧。", "走", "", false),
        ("他刚走，你晚来了五分钟。", "走", "", false),
        ("他给医生塞了一个红包。", "红包", "bribe", true),
        ("这位法官从来不收红包。", "红包", "bribe", true),
        ("过年的时候孩子们都收到了很多红包。", "红包", "gift", true),
        ("参加婚礼要准备红包。", "红包", "gift", true),
        ("他靠关系找到了工作。", "关系", "guanxi", true),
        ("我和他的关系很好。", "关系", "relation", false),
        ("一点小意思，不成敬意。", "意思", "token", true),
        ("你说的这句话是什么意思？", "意思", "meaning", false),
        ("他太老实了，总是被人骗。", "老实", "naive", true),
        ("这孩子很老实，从来不撒谎。", "老实", "honest", false),
        ("你这个东西，怎么能这样对你妈说话？", "东西", "person", true),
        ("桌子上的东西是谁的？", "东西", "thing", false),
        ("他现在在网上很红。", "红", "popular", false),
        ("中医说她气血不足。", "气", "qi", true),
        ("他气得脸都红了。", "气", "angry", false),
        ("我的机场又不能用了，上不了谷歌。", "机场", "Shadowsocks", true),
        ("我们打车去机场吧。", "机场", "airport", false),
        ("周五下午大家都在公司摸鱼。", "摸鱼", "loaf", true),
        ("孩子们在池塘里摸鱼摸虾。", "摸鱼", "catch fish", false),
        ("考研的人越来越多，太卷了。", "卷", "compete", true),
        ("她把头发卷了起来。", "卷", "roll", false),
        ("新买的电脑摔坏了，真心疼。", "心疼", "grudge", true),
        ("吃火锅吃得上火了，喉咙疼。", "上火", "internal heat", true),
        ("他为这件事上火，跟老婆吵了一架。", "上火", "angry", false),
        ("你这身打扮太土了。", "土", "unsophisticated", true),
        ("花盆里的土太干了。", "土", "earth", false),
        // Second batch: words given examples later, plus paraphrase coverage.
        ("他在会上被领导当众批评，一点面子都没有。", "面子", "prestige", true),
        ("这个沙发的面子破了，得换一块布。", "面子", "surface", false),
        ("这次他帮我搬家，我欠他一个人情。", "人情", "favor", true),
        ("没有北京户口，买房要交五年社保。", "户口", "registered residence", true),
        ("工作太累了，我只想躺平。", "躺平", "opt out", true),
        ("他一进门就躺平在床上睡着了。", "躺平", "lie stretched out", false),
        ("清明那天，我们全家去给外婆扫墓。", "清明", "Tomb Sweeping", true),
        ("小时候她和婆婆住在一起，婆媳关系很紧张。", "婆婆", "husband's mother", true),
        ("师傅，麻烦在前面路口停一下。", "师傅", "form of address", true),
        ("他在店里跟着师傅学做面包。", "师傅", "master", false),
        ("别跟这种小人计较。", "小人", "nasty person", true),
        ("考了三年，他终于不纠结了，决定出国。", "纠结", "struggle", true),
        ("他是东北人，特别能喝酒。", "东北", "Manchuria", true),
        ("飞机朝东北方向飞去。", "东北", "northeast", false),
        ("我妈看了那段视频，当场就破防了。", "破防", "emotional defenses", true),
        ("解放以后，他家分到了土地。", "解放", "Communists' victory", true),
        ("周末终于不用上班，感觉整个人都解放了。", "解放", "to liberate", false),
        ("这家公司有很多奇葩规定。", "奇葩", "outlandish", true),
        ("他这人太世故，说话从不得罪人。", "世故", "worldly-wise", true),
        ("饺子是北方人过年必吃的。", "饺子", "dumpling", true),
        ("他请大家吃饭，说今天他请客。", "请客", "invite", true),
        ("开会的时候，他总是很低调，不多说话。", "低调", "low-key", true),
    ]

    static func evalNotes(dict: CEDict) async throws {
        var right = 0, falseNotes = 0
        for (passage, word, want, noted) in noteCases {
            let index = passage.distance(from: passage.startIndex, to: passage.range(of: word)!.lowerBound)
            let ctx = Segmenter.context(for: index..<(index + word.count), in: Array(passage))
            let senses = dict.senses(for: word)
            var batched: SenseChoice?
            if ProcessInfo.processInfo.environment["LONGYAN_BATCH"] == "1" {
                // As in a phrase card: every ambiguous word of the sentence picked in one request.
                let chars = Array(passage)
                let tokens = Segmenter.phrase(0..<chars.count, in: chars, dict: dict)
                let picks = await PhraseState.resolve(tokens, in: chars, dict: dict)
                batched = tokens.first { $0.range.lowerBound == index && $0.text == word }.flatMap { picks[$0.id] }
                if batched == nil { print("- \(passage)  (\(word) not a phrase token)"); continue }
            }
            let c: SenseChoice? = if let batched { batched } else { try? await SenseChooser.choose(for: ctx, senses: senses) }
            guard let c else {
                print("? \(passage)  → model refused; dictionary order")
                continue
            }
            let sense = senses[c.senseNumber - 1]
            // Judge by the note shown: the expected sense's note (or none), whichever paraphrase carried it.
            let shown = NotesStore.hasExactNote(word, sense) ? NotesStore.note(word, sense)?.note : nil
            let expectedSense = want.isEmpty ? nil : senses.first { $0.gloss.localizedCaseInsensitiveContains(want) }
            let expectedNote = expectedSense.flatMap { NotesStore.hasExactNote(word, $0) ? NotesStore.note(word, $0)?.note : nil }
            let ok = shown == expectedNote && (noted ? shown != nil : true)
            if ok { right += 1 }
            if let shown, shown != expectedNote { falseNotes += 1 }
            print("\(ok ? "✓" : "✗") \(passage)  → \(sense.gloss.prefix(45))\(shown != nil ? "  [NOTE]" : "")")
        }
        print("\nright \(right)/\(noteCases.count), wrong notes shown \(falseNotes)")
    }

    /// A card layout for test renders; LONGYAN_CARD_SCALE sets the zoom (default 1).
    @MainActor
    static func renderLayout(_ kind: CardLayout.Kind) -> CardLayout {
        let layout = CardLayout(kind: kind)
        let scale = Double(ProcessInfo.processInfo.environment["LONGYAN_CARD_SCALE"] ?? "") ?? 1
        layout.zoom = scale
        layout.width = layout.baseWidth * scale
        // The card's buttons as they appear in the app (nothing is copied or read aloud here).
        layout.copyText = { "" }
        layout.speech = { SpeechPlan(text: "", help: "") }
        return layout
    }
}

/// How often the model's picks were right at each level of its confidence, for deciding
/// below what confidence a pick shouldn't be trusted. Picks without a confidence (Apple's
/// model, a written reply, words settled by rules) are left out.
struct Calibration {
    static let bands: [(floor: Double, label: String)] = [(0.9, "90%+"), (0.7, "70-90%"), (0.5, "50-70%"), (0, "under 50%")]
    private var counts = [(right: Int, all: Int)](repeating: (0, 0), count: bands.count)

    mutating func add(_ word: String, _ n: Int, right: Bool) {
        guard let p = LocalModel.confidence(word, picked: n) else { return }
        let b = Self.bands.firstIndex { p >= $0.floor }!
        counts[b].all += 1
        if right { counts[b].right += 1 }
        if ProcessInfo.processInfo.environment["LONGYAN_TRACE"] == "1" { print(String(format: "    · %@ %@ at %.0f%%", word, right ? "right" : "wrong", p * 100)) }
    }

    func report() {
        guard counts.contains(where: { $0.all > 0 }) else { return }
        print("confidence: " + zip(Self.bands, counts).map { "\($0.label) \($1.right) of \($1.all) correct" }.joined(separator: ", "))
    }
}
