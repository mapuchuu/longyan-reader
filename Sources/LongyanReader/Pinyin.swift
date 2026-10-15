import Foundation

/// A pinyin syllable with its tone mark applied. Tone 5 is neutral.
struct Syllable {
    let text: String
    let tone: Int
}

enum Pinyin {
    /// "xue2 sheng1" -> [xué(2), shēng(1)]; "lu:4" -> lǜ.
    static func syllables(_ numbered: String) -> [Syllable] {
        numbered.split(separator: " ").map { raw in
            var s = String(raw).replacingOccurrences(of: "u:", with: "ü")
                               .replacingOccurrences(of: "U:", with: "Ü")
            var tone = 5
            if let last = s.last, let n = last.wholeNumberValue, (1...5).contains(n) {
                tone = n
                s.removeLast()
            }
            return Syllable(text: tone == 5 ? s : mark(s, tone: tone), tone: tone)
        }
    }

    static func marked(_ numbered: String) -> String {
        syllables(numbered).map(\.text).joined(separator: " ")
    }

    private static let marks: [Character: [Character]] = [
        "a": ["ā", "á", "ǎ", "à"], "e": ["ē", "é", "ě", "è"], "i": ["ī", "í", "ǐ", "ì"],
        "o": ["ō", "ó", "ǒ", "ò"], "u": ["ū", "ú", "ǔ", "ù"], "ü": ["ǖ", "ǘ", "ǚ", "ǜ"],
        "A": ["Ā", "Á", "Ǎ", "À"], "E": ["Ē", "É", "Ě", "È"], "O": ["Ō", "Ó", "Ǒ", "Ò"],
    ]

    /// Standard placement: a or e takes the mark; in "ou" the o does; otherwise the last vowel.
    private static func mark(_ syllable: String, tone: Int) -> String {
        var chars = Array(syllable)
        let lower = syllable.lowercased()
        let target: Int?
        if let i = chars.firstIndex(where: { "aAeE".contains($0) }) {
            target = i
        } else if let r = lower.range(of: "ou") {
            target = lower.distance(from: lower.startIndex, to: r.lowerBound)
        } else {
            target = chars.lastIndex(where: { "iouüIOUÜ".contains($0) })
        }
        guard let t = target, let options = marks[chars[t]] ?? marks[Character(chars[t].lowercased())] else {
            return syllable
        }
        chars[t] = options[tone - 1]
        return String(chars)
    }
}
