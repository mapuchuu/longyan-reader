import Foundation

package func isCJK(_ c: Character) -> Bool {
    c.unicodeScalars.contains { s in
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) ||
        (0x20000...0x2A6DF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) ||
        (0x2A700...0x323AF).contains(s.value) || (0x2F800...0x2FA1F).contains(s.value) ||
        s.value == 0x3007   // 〇, as in 二〇二三年
    }
}

/// Simplified or traditional: the tokenizer splits 我們 and 覺得 when told it's simplified.
package func chineseScript(of text: String) -> ChineseScript { Platform.wordBreaker.script(of: text) }

/// The word under the cursor and the passage around it.
package struct WordInContext {
    package let word: String
    package let passage: [Character]
    package let wordRange: Range<Int>      // character offsets into passage
    package let alternatives: [String]     // other dictionary words covering the same character

    package init(word: String, passage: [Character], wordRange: Range<Int>, alternatives: [String]) {
        self.word = word; self.passage = passage; self.wordRange = wordRange; self.alternatives = alternatives
    }

    /// Where the sentence holding the word starts and ends in the passage.
    private var sentenceBounds: Range<Int> {
        let stops: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n", "\r\n", "\r", "\u{2029}"]
        var lo = wordRange.lowerBound, hi = wordRange.upperBound
        while lo > 0, !stops.contains(passage[lo - 1]), wordRange.lowerBound - lo < 160 { lo -= 1 }
        while hi < passage.count, !stops.contains(passage[hi]), hi - wordRange.upperBound < 160 { hi += 1 }
        if hi < passage.count { hi += 1 }   // keep the closing punctuation
        return lo..<hi
    }

    package var sentence: String {
        String(passage[sentenceBounds]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sentence alone with the word bracketed; a fallback when the wider passage is rejected.
    /// Bracketed where it is, not where it first appears: in 行不行，这一行很难 the second 行 is the one.
    package var markedSentence: String {
        let b = sentenceBounds
        return (String(passage[b.lowerBound..<wordRange.lowerBound]) + "【" + word + "】"
                + String(passage[wordRange.upperBound..<b.upperBound])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Up to ~240 characters around the word with the word bracketed 【】, for the model.
    var markedPassage: String {
        let lo = max(0, wordRange.lowerBound - 160), hi = min(passage.count, wordRange.upperBound + 80)
        return String(passage[lo..<wordRange.lowerBound]) + "【" + word + "】" + String(passage[wordRange.upperBound..<hi])
    }
}

package enum Segmenter {
    /// Finds the dictionary word covering `index`.
    /// Prefers the system tokenizer's word (it reads context: 研究/生命 vs 研究生),
    /// unless a longer dictionary entry of 4+ characters (usually an idiom) contains it.
    package static func word(at index: Int, in passage: [Character], dict: CEDict) -> WordInContext? {
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
            // A lone character that begins a dictionary word usually belongs to it (长得, not 长),
            // but not when the rest is an aspect particle the tokenizer split off: 他得了感冒 is
            // 得 "to catch" + 了, not 得了 "all right!". Traditional is compared once simplified:
            // 看著 is 看 + 着, but 顯著 is one word.
            if t.count == 1, let word = covering.first(where: { $0.lowerBound == t.lowerBound && $0.count > 1 }),
               !(word.count == 2 && "了着过".contains(dict.simplified(String(passage[word])).last!)) {
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
        // Tokenise a window around the index; the word breaker works on String indices.
        let lo = max(0, index - 40), hi = min(passage.count, index + 40)
        let text = String(passage[lo..<hi])
        let target = index - lo
        let starts = Array(text.indices)
        for r in Platform.wordBreaker.words(in: text, script: chineseScript(of: text)) {
            let o = offsets(r, starts: starts)
            if o.lowerBound <= target, target < o.upperBound { return (o.lowerBound + lo)..<(o.upperBound + lo) }
        }
        return nil
    }
}

/// One unit of a highlighted phrase.
package struct PhraseToken: Identifiable, Sendable {
    package let id: Int
    package let text: String
    package let range: Range<Int>      // character offsets into the passage
}

package extension Segmenter {
    /// Splits the selected range into dictionary words. Uses the system tokenizer for
    /// boundaries, splits tokens the dictionary doesn't know by longest match, then
    /// merges tokens that together form a longer dictionary word (有/意思 → 有意思, idioms).
    static func phrase(_ range: Range<Int>, in passage: [Character], dict: CEDict) -> [PhraseToken] {
        var pieces = tokenized(range, in: passage, dict: dict)

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
    /// Characters that don't start a rejoined pair (我去, 你好, 的话, 得很, 把门 are wrong in running text)
    /// or end one (家的, 中的, 这不).
    private static let noJoinFirst: Set<Character> = leadingAdverbs.union(["的", "得", "地", "了", "我", "你", "他", "她", "它", "把", "被"])
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

    /// The tokenizer's words for `range`, with what it doesn't know split by longest match.
    /// It can stop early (at U+FE0F, U+FEFF, control characters: one ❤️ would lose the rest),
    /// so a stretch it leaves out is tokenized again from its first Chinese character, and
    /// split by longest match only if that gets no further.
    private static func tokenized(_ range: Range<Int>, in passage: [Character], dict: CEDict) -> [Range<Int>] {
        let text = String(passage[range])
        var pieces: [Range<Int>] = []
        let starts = Array(text.indices)
        func add(_ piece: Range<Int>) {
            guard !piece.isEmpty else { return }
            if !piece.contains(where: { isCJK(passage[$0]) }) || dict.contains(String(passage[piece])) {
                pieces.append(piece)
            } else {
                pieces += longestMatch(piece, in: passage, dict: dict)
            }
        }
        // Only Chinese in a stretch it left out matters: spaces and punctuation it always skips.
        func fill(_ gap: Range<Int>) {
            guard let first = gap.first(where: { isCJK(passage[$0]) }) else { return }
            if first > gap.lowerBound { pieces += tokenized(first..<gap.upperBound, in: passage, dict: dict); return }
            pieces += longestMatch(gap, in: passage, dict: dict).filter { p in
                p.contains { isCJK(passage[$0]) || passage[$0].isLetter || passage[$0].isNumber }
            }
        }
        var covered = range.lowerBound
        for r in Platform.wordBreaker.words(in: text, script: chineseScript(of: text)) {
            let o = offsets(r, starts: starts)
            let a = max(o.lowerBound + range.lowerBound, covered), b = o.upperBound + range.lowerBound
            guard a < b else { continue }
            fill(covered..<a)
            add(a..<b)
            covered = b
        }
        fill(covered..<range.upperBound)
        return pieces
    }

    /// Character offsets of a tokenizer range, `starts` being the text's character indices. A
    /// range that ends inside a character (a Han character before U+FE0F) takes all of it.
    /// A binary search, so a long text isn't counted from its start for every word.
    static func offsets(_ r: Range<String.Index>, starts: [String.Index]) -> Range<Int> {
        func count(_ include: (String.Index) -> Bool) -> Int {
            var lo = 0, hi = starts.count
            while lo < hi { let m = (lo + hi) / 2; if include(starts[m]) { lo = m + 1 } else { hi = m } }
            return lo
        }
        let a = max(0, count { $0 <= r.lowerBound } - 1)
        let b = count { $0 < r.upperBound }
        return a..<max(a, b)
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

    /// Widens a selection that cuts a word in half (电商平【台大促时】, 职介部门或【子公】司) out to
    /// the whole word. The edges are judged by segmenting the text around them, so a word is
    /// split the way it reads in its sentence. An edge stays put when the stretch would take in
    /// a grammar character (把【门】 is 把 + 门, not 把门; 这【时候】 isn't 这时|候), or move more
    /// than `maxStretch` characters. (Checking whether the selection already starts on a word
    /// can't work: the fragment is often a word itself, as 台大 is in 平【台大】促.) Single characters are left alone: picking one is usually on purpose.
    static func wholeWords(_ range: Range<Int>, in passage: [Character], dict: CEDict, maxStretch: Int = 3) -> Range<Int> {
        guard range.count >= 2 else { return range }
        func takesIn(_ r: Range<Int>) -> Bool { !r.contains { stretchStops.contains(passage[$0]) } }

        let reach = dict.maxWordLength
        let lo = max(0, range.lowerBound - reach), hi = min(passage.count, range.upperBound + reach)
        var start = range.lowerBound, end = range.upperBound
        for t in phrase(lo..<hi, in: passage, dict: dict) where t.range.count >= 2 && dict.contains(t.text) {
            let r = t.range
            if r.lowerBound < start, start < r.upperBound, start - r.lowerBound <= maxStretch,
               takesIn(r.lowerBound..<start) {
                start = r.lowerBound
            }
            if r.lowerBound < end, end < r.upperBound, r.upperBound - end <= maxStretch,
               takesIn(end..<r.upperBound) {
                end = r.upperBound
            }
        }
        return start..<end
    }

    /// The longer word a single character belongs to in its sentence (彻 in 彻底, 务 in 财务),
    /// split the way a phrase card splits it; nil when the character stands on its own. A word
    /// the tokenizer glued onto 把 or 被 (把门 in 把门的合页撬歪) doesn't count; other grammar
    /// characters are part of real words here (过失, 地址, 吃不准).
    static func enclosingWord(of range: Range<Int>, in passage: [Character], dict: CEDict) -> Range<Int>? {
        guard range.count == 1, passage.indices.contains(range.lowerBound), isCJK(passage[range.lowerBound]) else { return nil }
        let reach = dict.maxWordLength
        let lo = max(0, range.lowerBound - reach), hi = min(passage.count, range.upperBound + reach)
        guard let t = phrase(lo..<hi, in: passage, dict: dict).first(where: { $0.range.contains(range.lowerBound) }),
              t.range.count > 1, dict.contains(t.text),
              !t.range.contains(where: { $0 != range.lowerBound && "把被".contains(passage[$0]) }) else { return nil }
        return t.range
    }

    /// Grammar characters a stretch never takes in: the tokenizer glues them onto neighbours
    /// (把门, 这时, 就是, 好的) where the reader meant the word beside them.
    private static let stretchStops: Set<Character> = Set("把被就这那在是的了着过地得和跟给对向从也都还又才不吗呢吧啊" + "這過給對從還嗎")

    /// The sentence a selection sits in, for its translation to read it by; nil when the
    /// selection is the whole sentence. (Adding the sentence before scored no better.)
    static func translationContext(for range: Range<Int>, in passage: [Character]) -> String? {
        let sentence = context(for: range, in: passage).sentence
        let selected = String(passage[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count - selected.count > 1 ? sentence : nil
    }

    /// Context for a word that sits at a known range (a selection or a phrase token).
    static func context(for range: Range<Int>, in passage: [Character]) -> WordInContext {
        WordInContext(word: String(passage[range]), passage: passage, wordRange: range, alternatives: [])
    }
}
