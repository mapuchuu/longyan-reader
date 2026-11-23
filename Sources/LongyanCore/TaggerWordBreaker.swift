import Foundation

/// The word splitter for systems without Apple's: a character tagger (begin, middle, end or
/// single) trained on Apple's splits of text the reading model wrote
/// (~/workspace/longyan-ft/splitter, notes/windows-plan.md). Integer weights, so it gives the
/// same answer on every system.
package final class TaggerWordBreaker: WordBreaker, @unchecked Sendable {
    let weights: [String: [Int]]
    let words: Set<String>
    let toSimplified: [Unicode.Scalar: Unicode.Scalar]
    let simplifiedOnly: Set<Unicode.Scalar>

    /// `weights`: the tagger's tab-separated weights. `cedict`: the dictionary text it was trained with.
    package init(weights weightsURL: URL, cedict cedictURL: URL) {
        var w: [String: [Int]] = [:]
        for l in ((try? String(contentsOf: weightsURL, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline) {
            let p = l.split(separator: "\t", maxSplits: 1)
            guard p.count == 2 else { continue }
            w[String(p[0])] = p[1].split(separator: " ").compactMap { Int($0) }
        }
        weights = w
        var ws = Set<String>(), t2s: [Unicode.Scalar: Unicode.Scalar] = [:]
        // Split on any line break: the file has CRLF endings, and "\r\n" is one Character.
        for l in ((try? String(contentsOf: cedictURL, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline) where !l.hasPrefix("#") {
            let p = l.split(separator: " ", maxSplits: 2)
            guard p.count >= 2 else { continue }
            for x in [p[0], p[1]] where (2...8).contains(x.unicodeScalars.count) { ws.insert(String(x)) }
            let a = Array(p[0].unicodeScalars), b = Array(p[1].unicodeScalars)
            if a.count == 1, b.count == 1, a != b, t2s[a[0]] == nil { t2s[a[0]] = b[0] }
        }
        words = ws; toSimplified = t2s
        simplifiedOnly = Set(t2s.values).subtracting(t2s.keys)
    }

    package var isLoaded: Bool { !weights.isEmpty && !words.isEmpty }

    /// Traditional when more of its characters are traditional-only forms than simplified-only ones.
    package func script(of text: String) -> ChineseScript {
        var t = 0, s = 0
        for c in text.unicodeScalars {
            if toSimplified[c] != nil { t += 1 } else if simplifiedOnly.contains(c) { s += 1 }
        }
        return t > s ? .traditional : .simplified
    }

    static func isHan(_ c: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(c.value) || (0xF900...0xFAFF).contains(c.value) || c == "〇"
    }
    static func isLatin(_ c: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(c) || ("a"..."z").contains(c) || (0xFF21...0xFF3A).contains(c.value) || (0xFF41...0xFF5A).contains(c.value)
    }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) || (0xFF10...0xFF19).contains(c.value) }

    package func words(in text: String, script: ChineseScript) -> [Range<String.Index>] {
        let u = text.unicodeScalars
        let idx = Array(u.indices) + [u.endIndex]
        let s = Array(u)
        var out: [Range<String.Index>] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if Self.isHan(c) {
                var j = i; while j < s.count, Self.isHan(s[j]) { j += 1 }
                var k = i
                for n in split(Array(s[i..<j]).map { toSimplified[$0] ?? $0 }) { out.append(idx[k]..<idx[k + n]); k += n }
                i = j
            } else if Self.isLatin(c) {
                // letters, with ASCII hyphens between ASCII letter runs
                var j = i; while j < s.count, Self.isLatin(s[j]) { j += 1 }
                while j + 1 < s.count, s[j] == "-", s[j + 1].isASCII, Self.isLatin(s[j + 1]), s[j + 1].properties.isAlphabetic {
                    j += 1; while j < s.count, s[j].isASCII, Self.isLatin(s[j]) { j += 1 }
                }
                out.append(idx[i]..<idx[j]); i = j
            } else if Self.isDigit(c) {
                var j = i; while j < s.count, Self.isDigit(s[j]) { j += 1 }
                if j + 1 < s.count, s[j] == ".", ("0"..."9").contains(s[j + 1]) { j += 1; while j < s.count, ("0"..."9").contains(s[j]) { j += 1 } }
                out.append(idx[i]..<idx[j]); i = j
            } else { i += 1 }
        }
        return out
    }

    /// Word lengths for one run of Chinese characters.
    func split(_ run: [Unicode.Scalar]) -> [Int] {
        let n = run.count
        let str = run.map { String($0) }
        var st = [Int](repeating: 0, count: n), en = st, inside = st
        for a in 0..<n {
            var w = str[a]
            for len in 2...8 where a + len <= n {
                w += str[a + len - 1]
                if words.contains(w) {
                    st[a] = max(st[a], len); en[a + len - 1] = max(en[a + len - 1], len)
                    if len > 2 { for k in (a + 1)..<(a + len - 1) { inside[k] = max(inside[k], len) } }
                }
            }
        }
        let p = ["^", "^"] + str + ["$", "$"]
        let zero = [0, 0, 0, 0]
        var emit: [[Int]] = []
        for a in 0..<n {
            let c = a + 2
            let f = ["c0" + p[c], "c-1" + p[c - 1], "c1" + p[c + 1], "c-2" + p[c - 2], "c2" + p[c + 2],
                     "b-1" + p[c - 1] + p[c], "b1" + p[c] + p[c + 1], "b-2" + p[c - 2] + p[c - 1], "b2" + p[c + 1] + p[c + 2],
                     "t" + p[c - 1] + p[c + 1],
                     "ds\(min(st[a], 5))", "de\(min(en[a], 5))", "di\(min(inside[a], 5))",
                     "dse\(min(st[a], 5))\(min(en[a], 5))", "c0ds" + p[c] + "\(min(st[a], 4))", "c0de" + p[c] + "\(min(en[a], 4))"]
            var e = zero
            for x in f { if let v = weights[x] { for t in 0..<4 { e[t] += v[t] } } }
            emit.append(e)
        }
        // tags B M E S; B and M continue a word, E and S end one
        let allowed: [[Bool]] = [[false, true, true, false], [false, true, true, false], [true, false, false, true], [true, false, false, true]]
        let tags = ["B", "M", "E", "S"]
        func tr(_ a: String, _ b: Int) -> Int { weights["tr:" + a]?[b] ?? 0 }
        let neg = Int.min / 4
        var v = [[Int]](repeating: [neg, neg, neg, neg], count: n), back = [[Int]](repeating: zero, count: n)
        for t in [0, 3] { v[0][t] = emit[0][t] + tr("^", t) }
        if n > 1 {
            for a in 1..<n {
                for t in 0..<4 {
                    var best = neg, bp = 0
                    for q in 0..<4 where allowed[q][t] && v[a - 1][q] > neg {
                        let x = v[a - 1][q] + tr(tags[q], t) + emit[a][t]
                        if x > best { best = x; bp = q }
                    }
                    v[a][t] = best; back[a][t] = bp
                }
            }
        }
        var t = v[n - 1][2] >= v[n - 1][3] ? 2 : 3
        var seq = [t]
        for a in stride(from: n - 1, to: 0, by: -1) { t = back[a][t]; seq.append(t) }
        seq.reverse()
        var lens: [Int] = [], cur = 0
        for t in seq { cur += 1; if t >= 2 { lens.append(cur); cur = 0 } }
        if cur > 0 { lens.append(cur) }
        return lens
    }
}
