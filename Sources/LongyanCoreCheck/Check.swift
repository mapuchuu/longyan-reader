import Foundation
import LongyanCore
import llama

/// Runs the shared logic with no system service and prints what it makes of a fixed set of
/// words and sentences, so every platform's build can be compared with the Mac's
/// (scripts/core-check-expected.txt, .github/workflows/core.yml). Run from the repo: it reads
/// Resources/. `--full FILE` also writes every headword's senses and card wording, whose hash
/// is in the summary, to find where two platforms differ.
@main
struct Check {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let fullPath = args.firstIndex(of: "--full").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }

        // FOR THIS CHECK ONLY: one word per Chinese character, so the segmenter's dictionary
        // rules run the same everywhere. The apps use the system's word splitter (see Platform).
        Platform.wordBreaker = OneCharacterBreaker()

        // --parts-of-speech TABLE: TABLE is the Mac app's --gloss-table output; prints the
        // definitions whose part of speech differs without an English tagger, with the Mac's
        // ("-" for none), for Resources/parts-of-speech.tsv (scripts/parts-of-speech.sh).
        if let i = args.firstIndex(of: "--parts-of-speech"), args.indices.contains(i + 1) {
            let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
            for line in text.split(whereSeparator: \.isNewline) {
                let p = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard p.count == 5 else { continue }
                let mac = String(p[4])
                if (PartOfSpeech.guess(String(p[0]))?.rawValue ?? "-") != mac { print("\(p[0])\t\(mac)") }
            }
            return
        }

        // llama links: the backend starts and the patch's function is there.
        llama_backend_init()
        let patched: @convention(c) (OpaquePointer?, UnsafePointer<llama_token>?, Int32) -> Bool = llama_model_set_output_tokens
        guard UInt(bitPattern: unsafeBitCast(patched, to: UnsafeRawPointer.self)) != 0 else { exit(1) }
        let info = String(cString: llama_print_system_info())
        FileHandle.standardError.write(Data("llama: \(info)\n".utf8))
        print("llama: backend ready, llama_model_set_output_tokens linked")

        let dict: CEDict
        do { dict = try CEDict.load() } catch { print("dictionary: \(error)"); exit(1) }
        print("dictionary: \(dict.entryCount) entries, longest word \(dict.maxWordLength)")
        print("notes: \(NotesStore.shared.count), cues: \(NoteCues.byWord.count) words, examples: \(ExamplesStore.shared.count)")

        print("\n# pinyin")
        for p in ["xue2 sheng1", "lu:4 se4", "Nu:3 er2", "ni3 hao3 ma5", "er4", "liang3", "zhuang4 yuan2", "r5"] {
            print("\(p) -> \(Pinyin.marked(p)) tones \(Pinyin.syllables(p).map(\.tone))")
        }

        print("\n# words")
        for word in ["长", "行", "了", "的", "打", "关系", "關係", "意思", "躺平", "摸鱼", "研究生", "闭关锁国", "干活儿", "冡", "态", "里", "地"] {
            let senses = dict.senses(for: word)
            print("\(word): \(senses.count) senses, model sees \(senses.forModel.count), everyday #\(dict.everydayIndex(for: word, in: senses) + 1), short \"\(shortGloss(senses))\"")
            for (i, s) in senses.prefix(6).enumerated() {
                let note = NotesStore.note(word, s).map { " | note[\($0.tag)] \($0.shown)" } ?? ""
                let pos = PartOfSpeech.guess(s.gloss)?.label ?? "-"
                print("  \(i + 1). \(Pinyin.marked(s.pinyin)) | \(s.gloss) | \(Gloss.listed(s.gloss)) | \(Gloss.short(s.gloss)) | \(pos)\(s.rare ? " | rare" : "")\(note)")
            }
        }

        print("\n# glosses")
        for g in ["to do sth for sb", "erhua variant of 幹活|干活[gan4 huo2]", "also written 裏|里[li3]", "(bound form) state; condition",
                  "opposite: passive 被動|被动[bei4 dong4]", "also pr. [di4] or [di5] in poetry", "(of a person) clever; bright",
                  "classifier for books", "abbr. for 中國|中国[Zhong1 guo2], China", "lit. to lie flat; fig. to give up, etc"] {
            print("\(g) -> \(Gloss.readable(g)) / \(Gloss.short(g)) / \(PartOfSpeech.guess(g)?.label ?? "-")")
        }

        let sentences = ["他长得很高。", "行不行，这一行很难", "把门的合页撬歪了", "他得了感冒，吃不了饭。", "他們覺得這個問題很難。",
                         "明朝实行海禁，闭关锁国。", "快递员每天晚上都要上夜班分拣包裹。", "2023年我在iPhone上用App学中文。", "我❤️你，真的。"]
        print("\n# segmenter (one character per token)")
        for s in sentences {
            let chars = Array(s)
            let words = Segmenter.phrase(0..<chars.count, in: chars, dict: dict).map(\.text)
            print("\(s) -> \(words.joined(separator: " | "))")
            var clicks: [String] = []
            for i in chars.indices {
                guard let w = Segmenter.word(at: i, in: chars, dict: dict) else { continue }
                let grammar = GrammarWords.entry(w.word, in: chars, at: w.wordRange.lowerBound).map { "(\($0.reading))" } ?? ""
                clicks.append("\(chars[i])=\(w.word)\(grammar)")
            }
            print("  clicks: \(clicks.joined(separator: " "))")
        }

        print("\n# anki")
        let passage = Array("明朝实行海禁，闭关锁国。他长得很高。")
        if let start = passage.firstIndex(of: "锁") {
            let context = WordInContext(word: "闭关锁国", passage: passage, wordRange: (start - 2)..<(start + 2), alternatives: [])
            let state = LookupState(context: context, senses: dict.senses(for: "闭关锁国"), phase: .choosing)
            state.receive(SenseChoice(senseNumber: 1, meaningHere: "to close the country to the outside world"))
            if let note = state.ankiNote {
                print("chinese \(note.chinese) | pinyin \(note.pinyin) | meaning \(note.meaning)")
            }
            print("sentence \(context.sentence) | marked \(context.markedSentence)")
        }

        // Every headword in the dictionary file, as cards show it.
        var full = ""
        var seen = Set<String>()
        let text = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/cedict_ts.u8"), encoding: .utf8)) ?? ""
        var headwords: [String] = []
        text.enumerateLines { line, _ in
            // "傳統 传统 [chuan2 tong3] /…/": the simplified form is the second field.
            let fields = line.split(separator: " ", maxSplits: 2)
            guard CEDict.parse(line) != nil, fields.count == 3 else { return }
            let word = String(fields[1])
            if seen.insert(word).inserted { headwords.append(word) }
        }
        var senseCount = 0
        for word in headwords {
            let senses = dict.senses(for: word)
            senseCount += senses.count
            full += "\(word)\t\(dict.everydayIndex(for: word, in: senses))\n"
            for s in senses {
                full += "\t\(Pinyin.marked(s.pinyin))\t\(Gloss.listed(s.gloss))\t\(Gloss.short(s.gloss))\t\(PartOfSpeech.guess(s.gloss)?.label ?? "-")"
                full += NotesStore.note(word, s).map { "\t\($0.shown)" } ?? ""
                full += "\n"
            }
        }
        print("\n# every headword")
        print("headwords \(headwords.count), senses \(senseCount), hash \(fnv1a(full))")
        if let fullPath { try? full.write(toFile: fullPath, atomically: true, encoding: .utf8) }
    }

    /// FNV-1a over the UTF-8 bytes: the same on every platform, and needs no library.
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// FOR THIS CHECK ONLY: each Chinese character is a word, everything else is left out.
struct OneCharacterBreaker: WordBreaker {
    func script(of text: String) -> ChineseScript { .simplified }
    func words(in text: String, script: ChineseScript) -> [Range<String.Index>] {
        text.indices.filter { isCJK(text[$0]) }.map { $0..<text.index(after: $0) }
    }
}
