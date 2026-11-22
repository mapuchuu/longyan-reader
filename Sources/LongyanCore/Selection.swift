import Foundation

/// Text the user highlighted, with the text around it when the app exposes it.
package struct Selection {
    package enum Source: String { case accessibility, clipboard }
    package let passage: [Character]
    package let range: Range<Int>          // the selection, as character offsets into passage
    package let bounds: CGRect?            // selection on screen, CoreGraphics space (top-left origin)
    package let source: Source
    package let appName: String?

    /// The range is clamped to the passage: apps report selections in UTF-16 units, and an
    /// edge inside a character (CRLF, an emoji sequence) leaves fewer characters than counted.
    package init(passage: [Character], range: Range<Int>, bounds: CGRect?, source: Source, appName: String?) {
        let lo = min(max(0, range.lowerBound), passage.count)
        self.passage = passage
        self.range = lo..<min(max(lo, range.upperBound), passage.count)
        self.bounds = bounds; self.source = source; self.appName = appName
    }

    package var text: String { String(passage[range]) }

    package func withoutBounds() -> Selection {
        Selection(passage: passage, range: range, bounds: nil, source: source, appName: appName)
    }
    package var hasChinese: Bool { passage[range].contains(where: isCJK) }

    /// Trims surrounding whitespace and punctuation so "，研究生。" looks up 研究生.
    package func trimmed() -> Selection {
        let s = unwrapped()
        var lo = s.range.lowerBound, hi = s.range.upperBound
        // Digits stay: 2023年 or 100元 is what was meant.
        func keep(_ c: Character) -> Bool { isCJK(c) || c.isLetter || c.isNumber }
        while lo < hi, !keep(s.passage[lo]) { lo += 1 }
        while hi > lo, !keep(s.passage[hi - 1]) { hi -= 1 }
        return Selection(passage: s.passage, range: lo..<hi, bounds: bounds, source: source, appName: appName)
    }

    /// The selection widened to whole words, so a sloppy drag (平【台大促】) reads as 平台大促.
    package func wholeWords(dict: CEDict) -> Selection {
        let r = Segmenter.wholeWords(range, in: passage, dict: dict)
        return r == range ? self : Selection(passage: passage, range: r, bounds: bounds, source: source, appName: appName)
    }

    /// Text in PDFs and narrow columns wraps mid-word (跟着师⏎父), which splits words and makes
    /// translators treat each line as its own sentence. Removes single line breaks next to
    /// Chinese text, and the spaces around them; a blank line is a real break and stays.
    private func unwrapped() -> Selection {
        var out: [Character] = []
        var lo = 0, hi = 0
        var i = 0
        while i <= passage.count {
            if i == range.lowerBound { lo = out.count }
            if i == range.upperBound { hi = out.count }
            guard i < passage.count else { break }
            guard passage[i].isNewline else { out.append(passage[i]); i += 1; continue }
            // The whole run of whitespace around this line break.
            var end = i
            var breaks = 0
            while end < passage.count, passage[end].isWhitespace {
                if passage[end].isNewline { breaks += 1 }
                end += 1
            }
            var kept = out.count
            while kept > 0, out[kept - 1].isWhitespace { kept -= 1 }
            let prev = kept > 0 ? out[kept - 1] : nil, next = end < passage.count ? passage[end] : nil
            guard breaks == 1, let prev, let next, !prev.isASCII || !next.isASCII else {
                out.append(contentsOf: passage[i..<end])
                for j in i...end where j == range.lowerBound || j == range.upperBound {
                    if j == range.lowerBound { lo = out.count }
                    if j == range.upperBound { hi = out.count }
                }
                i = end
                continue
            }
            out.removeSubrange(kept...)
            if range.lowerBound >= kept, range.lowerBound <= end { lo = min(lo, kept) }
            if range.upperBound >= kept, range.upperBound <= end { hi = min(hi, kept) }
            i = end
        }
        return Selection(passage: out, range: lo..<max(lo, hi), bounds: bounds, source: source, appName: appName)
    }
}

package extension Selection {
    /// One dictionary word (or a single character) gets the word card; anything longer gets
    /// the phrase card.
    func isOneWord(dict: CEDict) -> Bool {
        text.count == 1 || (text.allSatisfy(isCJK) && dict.contains(text))
    }

    /// Whether the selection is all there is (copied text, the ⌘C fallback): no sentence around it.
    var isAlone: Bool {
        !passage.indices.contains { !range.contains($0) && (isCJK(passage[$0]) || passage[$0].isLetter) }
    }
}
