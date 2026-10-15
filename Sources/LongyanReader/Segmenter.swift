import Foundation
import NaturalLanguage

func isCJK(_ c: Character) -> Bool {
    c.unicodeScalars.contains { s in
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) ||
        (0x20000...0x2A6DF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
    }
}

/// The word under the cursor and the passage around it.
struct WordInContext {
    let word: String
    let passage: [Character]
    let wordRange: Range<Int>      // character offsets into passage
    let alternatives: [String]     // other dictionary words covering the same character

    var sentence: String {
        let stops: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n"]
        var lo = wordRange.lowerBound, hi = wordRange.upperBound
        while lo > 0, !stops.contains(passage[lo - 1]), wordRange.lowerBound - lo < 160 { lo -= 1 }
        while hi < passage.count, !stops.contains(passage[hi]), hi - wordRange.upperBound < 160 { hi += 1 }
        if hi < passage.count { hi += 1 }   // keep the closing punctuation
        return String(passage[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sentence alone with the word bracketed; a fallback when the wider passage is rejected.
    var markedSentence: String {
        let s = sentence
        guard let r = s.range(of: word) else { return markedPassage }
        return s.replacingCharacters(in: r, with: "【" + word + "】")
    }

    /// Up to ~240 characters around the word with the word bracketed 【】, for the model.
    var markedPassage: String {
        let lo = max(0, wordRange.lowerBound - 160), hi = min(passage.count, wordRange.upperBound + 80)
        return String(passage[lo..<wordRange.lowerBound]) + "【" + word + "】" + String(passage[wordRange.upperBound..<hi])
    }
}

enum Segmenter {
    /// Finds the dictionary word covering `index`.
    /// Prefers the system tokenizer's word (it reads context: 研究/生命 vs 研究生),
    /// unless a longer dictionary entry of 4+ characters (usually an idiom) contains it.
    static func word(at index: Int, in passage: [Character], dict: CEDict) -> WordInContext? {
        guard passage.indices.contains(index), isCJK(passage[index]) else { return nil }

        // Every dictionary word that covers index, longest first.
        var covering: [Range<Int>] = []
        let maxLen = min(dict.maxWordLength, 12)
        for start in max(0, index - maxLen + 1)...index {
            for len in stride(from: min(maxLen, passage.count - start), through: 1, by: -1) where start + len > index {
                let r = start..<(start + len)
                if r.allSatisfy({ isCJK(passage[$0]) }), dict.contains(String(passage[r])) { covering.append(r) }
            }
        }
        covering.sort { $0.count != $1.count ? $0.count > $1.count : $0.lowerBound < $1.lowerBound }

        let token = tokenizerWord(at: index, in: passage)
        var chosen: Range<Int>
        if let t = token, dict.contains(String(passage[t])) {
            chosen = t
            // A lone character that begins a dictionary word usually belongs to it (长得, not 长).
            if t.count == 1, let word = covering.first(where: { $0.lowerBound == t.lowerBound && $0.count > 1 }) {
                chosen = word
            }
            if let longer = covering.first, longer.count >= 4, longer.count > t.count,
               longer.lowerBound <= t.lowerBound, longer.upperBound >= t.upperBound {
                chosen = longer
            }
        } else if let longest = covering.first {
            chosen = longest
        } else {
            chosen = index..<(index + 1)
        }

        let word = String(passage[chosen])
        let alternatives = covering.map { String(passage[$0]) }.filter { $0 != word }
        var unique: [String] = []
        for a in alternatives where !unique.contains(a) { unique.append(a) }
        return WordInContext(word: word, passage: passage, wordRange: chosen, alternatives: Array(unique.prefix(4)))
    }

    private static func tokenizerWord(at index: Int, in passage: [Character]) -> Range<Int>? {
        // Tokenise a window around the index; NLTokenizer works on String indices.
        let lo = max(0, index - 40), hi = min(passage.count, index + 40)
        let text = String(passage[lo..<hi])
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text
        let target = index - lo
        var found: Range<Int>?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let a = text.distance(from: text.startIndex, to: r.lowerBound)
            let b = text.distance(from: text.startIndex, to: r.upperBound)
            if a <= target, target < b { found = (a + lo)..<(b + lo); return false }
            return true
        }
        return found
    }
}
