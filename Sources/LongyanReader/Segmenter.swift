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

/// One unit of a highlighted phrase.
struct PhraseToken: Identifiable {
    let id: Int
    let text: String
    let range: Range<Int>      // character offsets into the passage
}

extension Segmenter {
    /// Splits the selected range into dictionary words. Uses the system tokenizer for
    /// boundaries, splits tokens the dictionary doesn't know by longest match, then
    /// merges tokens that together form a longer dictionary word (有/意思 → 有意思, idioms).
    static func phrase(_ range: Range<Int>, in passage: [Character], dict: CEDict) -> [PhraseToken] {
        let text = String(passage[range])
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text
        var pieces: [Range<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let a = text.distance(from: text.startIndex, to: r.lowerBound) + range.lowerBound
            let b = text.distance(from: text.startIndex, to: r.upperBound) + range.lowerBound
            let piece = a..<b
            if !piece.contains(where: { isCJK(passage[$0]) }) || dict.contains(String(passage[piece])) {
                pieces.append(piece)
            } else {
                pieces += longestMatch(piece, in: passage, dict: dict)
            }
            return true
        }

        pieces = rejoinSingles(resplitAdverbs(pieces, in: passage, dict: dict), in: passage, dict: dict)

        // Merge runs of tokens that form a dictionary word of 3+ characters.
        var merged: [Range<Int>] = []
        var i = 0
        while i < pieces.count {
            var best = i
            var j = i + 1
            while j < pieces.count, pieces[j].upperBound - pieces[i].lowerBound <= dict.maxWordLength {
                let candidate = pieces[i].lowerBound..<pieces[j].upperBound
                if pieces[j].lowerBound == pieces[j - 1].upperBound, candidate.count >= 3,
                   dict.contains(String(passage[candidate])) { best = j }
                j += 1
            }
            merged.append(pieces[i].lowerBound..<pieces[best].upperBound)
            i = best + 1
        }

        return merged.enumerated()
            .filter { _, r in r.contains(where: { isCJK(passage[$0]) }) }
            .map { n, r in PhraseToken(id: n, text: String(passage[r]), range: r) }
    }

    /// Degree adverbs that the tokenizer (and longest match) glue onto the next character:
    /// 真心|疼 should be 真|心疼. (Broader sets broke 别人|家 and 好几|天.)
    static let leadingAdverbs: Set<Character> = ["真", "很", "太", "最", "更", "挺", "超"]
    /// Characters that don't start a rejoined pair (我去, 你好, 的话, 得很 are wrong in running text)
    /// or end one (家的, 中的, 这不).
    private static let noJoinFirst: Set<Character> = leadingAdverbs.union(["的", "得", "地", "了", "我", "你", "他", "她", "它"])
    private static let noJoinSecond: Set<Character> = ["的", "得", "地", "了", "不"]

    /// AB|C → A|BC when A is an adverb, BC is a dictionary word and C on its own is not
    /// joined to anything after it.
    private static func resplitAdverbs(_ pieces: [Range<Int>], in passage: [Character], dict: CEDict) -> [Range<Int>] {
        var out = pieces
        var i = 0
        while i + 1 < out.count {
            let ab = out[i], c = out[i + 1]
            if ab.count == 2, c.count == 1, ab.upperBound == c.lowerBound, leadingAdverbs.contains(passage[ab.lowerBound]),
               dict.contains(String(passage[(ab.lowerBound + 1)..<c.upperBound])) {
                out[i] = ab.lowerBound..<(ab.lowerBound + 1)
                out[i + 1] = (ab.lowerBound + 1)..<c.upperBound
            }
            i += 1
        }
        return out
    }

    /// The tokenizer cuts words it doesn't know (new slang like 躺平, 摸鱼, 破防) into single
    /// characters; join two neighbouring single characters that make a dictionary word.
    private static func rejoinSingles(_ pieces: [Range<Int>], in passage: [Character], dict: CEDict) -> [Range<Int>] {
        func joinable(_ i: Int) -> Bool {
            guard i + 1 < pieces.count else { return false }
            let a = pieces[i], b = pieces[i + 1]
            return a.count == 1 && b.count == 1 && b.lowerBound == a.upperBound && isCJK(passage[a.lowerBound])
                && !noJoinFirst.contains(passage[a.lowerBound]) && !noJoinSecond.contains(passage[b.lowerBound])
                && dict.contains(String(passage[a.lowerBound..<b.upperBound]))
        }
        var out: [Range<Int>] = []
        var i = 0
        while i < pieces.count {
            let a = pieces[i]
            // When the second character also starts a pair, that pair wins: 另|一个, not 另一|个.
            if joinable(i), !joinable(i + 1) {
                out.append(a.lowerBound..<pieces[i + 1].upperBound)
                i += 2
            } else {
                out.append(a)
                i += 1
            }
        }
        return out
    }

    private static func longestMatch(_ piece: Range<Int>, in passage: [Character], dict: CEDict) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = piece.lowerBound
        while start < piece.upperBound {
            var len = min(dict.maxWordLength, piece.upperBound - start)
            while len > 1, !dict.contains(String(passage[start..<(start + len)])) { len -= 1 }
            out.append(start..<(start + len))
            start += len
        }
        return out
    }

    /// Context for a word that sits at a known range (a selection or a phrase token).
    static func context(for range: Range<Int>, in passage: [Character]) -> WordInContext {
        WordInContext(word: String(passage[range]), passage: passage, wordRange: range, alternatives: [])
    }
}
