import Foundation

/// Words that are grammar rather than vocabulary, too common and too hard to label for picking
/// a dictionary sense to help. They get one fixed line, with no model call.
struct GrammarWord {
    let reading: String     // the dictionary's pinyin: "de5"
    let summary: String

    /// The senses worth listing: this reading's, without pronunciation notes.
    func listed(_ senses: [Sense]) -> [Sense] {
        senses.filter { $0.pinyin == reading && !$0.gloss.hasPrefix("also pr.") }
    }
}

enum GrammarWords {
    private static let de = GrammarWord(reading: "de5", summary: "'s; of; marks a description")
    private static let le = GrammarWord(reading: "le5", summary: "action done, or a new situation")
    /// 吃不了, 走得了: "liǎo", about whether something can be done.
    private static let liao = GrammarWord(reading: "liao3", summary: "can / can't (after a verb)")

    /// `index` is where the word starts in `passage`; what comes before it can change the reading.
    static func entry(_ word: String, in passage: [Character], at index: Int) -> GrammarWord? {
        switch word {
        case "的": return de
        case "了":
            let before = passage.indices.contains(index - 1) ? passage[index - 1] : nil
            if before == "不" { return liao }
            guard before == "得" else { return le }
            // 走得了 is liǎo, but after a subject 得 is the verb itself: 他得了感冒 is le. (A name
            // as subject, 小王得了奖, still reads liǎo.)
            let subject = passage.indices.contains(index - 2) ? passage[index - 2] : nil
            return subject.map { isCJK($0) && !"我你他她它们們".contains($0) } ?? false ? liao : le
        default: return nil
        }
    }
}
