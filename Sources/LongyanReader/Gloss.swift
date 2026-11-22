import Foundation

/// CC-CEDICT definitions are written for dictionary users: 幹活|干活[gan4 huo2], "sb", "sth",
/// "(bound form)". These turn them into something to read on a card. `Sense.gloss` itself
/// stays as the dictionary has it: notes and examples are keyed on it, and the model reads it.
enum Gloss {
    private static let reference = try! NSRegularExpression(pattern: #"(?:\p{Han}+\|)?(\p{Han}+)(?:\[[A-Za-z0-9 :,·\-]+\])?"#)
    private static let alsoWritten = try! NSRegularExpression(pattern: #"also written (\p{Han}+)\|(\p{Han}+)(?:\[[A-Za-z0-9 :,·\-]+\])?"#)
    private static let stray = try! NSRegularExpression(pattern: #"\[[A-Za-z]+[1-5:]?[A-Za-z0-9 :,·\-]*\]"#)
    private static let words: [(String, String)] = [
        (#"\bsb's\b"#, "someone's"), (#"\bsth's\b"#, "something's"), (#"\bsb\b"#, "someone"), (#"\bsth\b"#, "something"),
        (#"\besp\."#, "especially"), (#"\bfig\."#, "figuratively"), (#"\blit\."#, "literally"), (#"\babbr\. for\b"#, "short for"),
        (#"\babbr\."#, "short for"), (#"\bcolloquial\."#, "colloquial"), (#"\bcf\."#, "compare"), (#"\be\.g\. see\b"#, "as in"), (#"\be\.g\."#, "for example"),
        (#"\bi\.e\."#, "that is"), (#"\betc\.?(?=\W|$)"#, "and so on"),
        (#"\busu\."#, "usually"), (#"\bapprox\."#, "about"),
    ]

    /// Cards redraw on every streamed word and each row asks for its meaning again, while the
    /// clean-up below runs about twenty regular expressions: worked out once per definition.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func value(_ key: String, _ make: (String) -> String) -> String {
            lock.lock(); let hit = values[key]; lock.unlock()
            if let hit { return hit }
            let made = make(key)
            lock.lock()
            if values.count > 20_000 { values.removeAll(keepingCapacity: true) }   // a CLI eval's worth
            values[key] = made
            lock.unlock()
            return made
        }
    }
    private static let readableMemo = Memo(), shortMemo = Memo()

    /// The whole definition, without dictionary markup. Used in the lists of meanings.
    static func readable(_ raw: String) -> String { readableMemo.value(raw, makeReadable) }

    private static func makeReadable(_ raw: String) -> String {
        var text = raw
        // "also written 裏|里" is about the other script, so both forms stay: on 里 itself
        // "also written 里" says nothing.
        text = alsoWritten.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: "also written $2 (traditional $1)")
        // "opposite: passive 被動|被动" names the opposite word; it isn't a meaning of this one.
        text = text.replacingOccurrences(of: #"^opposite: ([^\p{Han}]+?) ?((?:\p{Han}+\|)?\p{Han}+(?:\[[^\]]*\])?)$"#,
                                         with: "not $1 (opposite of $2)", options: .regularExpression)
        let range = NSRange(text.startIndex..., in: text)
        text = reference.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        text = spellingPronunciations(text)
        text = stray.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        for (pattern, plain) in words {
            text = text.replacingOccurrences(of: pattern, with: plain, options: .regularExpression)
        }
        // Not when it's all there is (态): an empty meaning says less than "(bound form)".
        let unbound = text.replacingOccurrences(of: #"^\(bound form\)\s*"#, with: "", options: .regularExpression)
        if !unbound.trimmingCharacters(in: .whitespaces).isEmpty { text = unbound }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A definition for a list of meanings: whole unless it would run past two lines or so.
    static func listed(_ raw: String) -> String {
        let text = readable(raw)
        return text.count > 80 ? short(raw) : text
    }

    /// "also pr. [di4] or [di5] in poetry": here the pinyin is the point, so it stays, with tone marks.
    private static func spellingPronunciations(_ text: String) -> String {
        guard text.range(of: #"\bpr\. ?\["#, options: .regularExpression) != nil else { return text }
        var out = text
        for match in stray.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: Pinyin.marked(String(out[range].dropFirst().dropLast())))
        }
        return out.replacingOccurrences(of: #"\bpr\."#, with: "pronounced", options: .regularExpression)
    }

    /// One short meaning, for a row or a headline. Never cut mid-word or mid-bracket.
    static func short(_ raw: String) -> String { shortMemo.value(raw, makeShort) }

    private static func makeShort(_ raw: String) -> String {
        if let plain = plainWording[raw] { return plain }
        var text = firstClause(readable(raw))
        // Leading and trailing asides go: "(bound form) up", "benefit (provided by an employer)".
        // A "(not)" stays: "(not) at all" is a meaning of 并, "at all" its opposite.
        while text.hasPrefix("("), let close = matchingClose(in: text) {
            let aside = String(text[...close])
            let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || isNegation(aside) { break }
            // "(to say the) least": the aside is the start of the phrase, not a note on it.
            if !rest.contains(" "), let last = aside.dropLast().split(separator: " ").last, joiningWords.contains(String(last)) {
                text = String(aside.dropFirst().dropLast()) + " " + rest
                break
            }
            text = rest
        }
        while text.hasSuffix(")"), let open = matchingOpen(in: text), open > text.startIndex,
              !isNegation(String(text[open...])) {
            let rest = text[..<open].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { break }
            text = rest
        }
        // A bare wrapping bracket: "(completed action marker)".
        if text.hasPrefix("("), text.hasSuffix(")") { text = String(text.dropFirst().dropLast()) }
        text = text.replacingOccurrences(of: #"\bclassifier\b"#, with: "measure word", options: .regularExpression)
        text = text.replacingOccurrences(of: #",? and so on$"#, with: "", options: .regularExpression)
        return shortened(text).trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
    }

    /// Long definitions stop at their first comma if that leaves a meaning; failing that, at a word.
    private static func shortened(_ text: String) -> String {
        guard text.count > 44 else { return text }
        // The first comma outside brackets and quotes ("A, B, C" is one thing).
        if let comma = topLevelComma(in: text), text.distance(from: text.startIndex, to: comma) >= 12,
           text.distance(from: text.startIndex, to: comma) <= 56 {
            return String(text[..<comma])
        }
        guard text.count > 56 else { return text }
        var cut = String(text.prefix(54))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;"))
        // Don't leave a bracket or quote open: stop before it, or if that leaves too little,
        // close it after the ellipsis.
        if let open = unclosed(in: cut) {
            let before = cut[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,:;"))
            if before.count >= 12 {
                // Nothing is lost if the bracket is all that was left out: 红楼梦's
                // "A Dream of Red Mansions (first completed edition 1791) by Cao Xueqin".
                let tail = String(text[text.index(text.startIndex, offsetBy: cut.distance(from: cut.startIndex, to: open))...])
                if tail.hasPrefix("("), let close = matchingClose(in: tail) {
                    let after = tail[tail.index(after: close)...]
                    if after.isEmpty || after.hasPrefix(",") || after.hasPrefix(" by ") { return before }
                }
                return before + "…"
            }
            return cut + "…" + (cut[open] == "(" ? ")" : "\"")
        }
        return cut + "…"
    }

    /// Up to the first semicolon that isn't inside brackets or quotes.
    private static func firstClause(_ text: String) -> String {
        var depth = 0, quoted = false
        for i in text.indices {
            switch text[i] {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case "\"": quoted.toggle()
            case ";" where depth == 0 && !quoted: return String(text[..<i]).trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return text
    }

    /// "(not)", "(not ...)", "(not only ...)": CC-CEDICT's way of saying "used with a negative".
    private static func isNegation(_ aside: String) -> Bool {
        aside.range(of: #"^\(not( only)?( ?\.\.\.)?\)$"#, options: .regularExpression) != nil
    }

    /// An aside ending in one of these runs on into the word after it: "(to say the) least".
    private static let joiningWords: Set<String> = ["the", "a", "an", "to", "be", "one's", "someone's", "something's"]

    /// The bracket that the final ")" closes, nesting counted: "person(s) spoken to)" isn't it.
    private static func matchingOpen(in text: String) -> String.Index? {
        var depth = 0
        for i in text.indices.reversed() {
            if text[i] == ")" { depth += 1 }
            if text[i] == "(" { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    private static func topLevelComma(in text: String) -> String.Index? {
        var depth = 0, quoted = false
        for i in text.indices {
            switch text[i] {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case "\"": quoted.toggle()
            case "," where depth == 0 && !quoted: return i
            default: break
            }
        }
        return nil
    }

    /// The first bracket or quote still open at the end of `text`, if any.
    private static func unclosed(in text: String) -> String.Index? {
        var opens: [String.Index] = [], quote: String.Index?
        for i in text.indices {
            switch text[i] {
            case "(": opens.append(i)
            case ")": _ = opens.popLast()
            case "\"": quote = quote == nil ? i : nil
            default: break
            }
        }
        return [opens.first, quote].compactMap { $0 }.min()
    }

    private static func matchingClose(in text: String) -> String.Index? {
        var depth = 0
        for i in text.indices {
            if text[i] == "(" { depth += 1 }
            if text[i] == ")" { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    /// Definitions no clean-up can make readable (grammar terms, mostly), by their dictionary text.
    static let plainWording: [String: String] = [
        "(classifier used before a noun that has no specific classifier)":
            "general measure word",
        "(neologism, c. 2020) to arrange an intensive schedule of activities for one's child to maximize achievement":
            "to push a child hard (pushy parenting)",
        "a residential property located within the designated catchment area of a desirable school, often sought after by parents to secure school admission for their children":
            "a home in a good school district",
        "(completed action marker)":
            "action finished",
        "(modal particle indicating change of state, situation now)":
            "now changed; a new situation",
        "(modal particle intensifying preceding clause)":
            "adds emphasis",
        "(used with 得[de2] or 不[bu4] after a verb to express (im)possibility, as in 忘不了[wang4 bu5 liao3] \"cannot forget\")":
            "can / can't (after a verb)",
        "of; ~'s (possessive particle)":
            "'s; of",
        "(used after an attribute when it modifies a noun)":
            "links a description to a noun",
        "(used at the end of a declarative sentence for emphasis)":
            "adds emphasis at the end",
        "(used after a noun, verb or adjective to form a nominal expression, as in 皮革的[pi2 ge2 de5] \"one made of leather\" or 跑堂兒的|跑堂儿的[pao3 tang2 r5 de5] \"a waiter (literally, one who runs back and forth in a restaurant)\" or 新的[xin1 de5] \"new one\")":
            "the one that… (新的 = the new one)",
        "(in many expressions) a semantically light transitive verb used with various objects to form expressions with a wide range of meanings, e.g. 打傘|打伞[da3 san3] \"to hold an umbrella\", 打電話|打电话[da3 dian4 hua4] \"to make a phone call\", 打針|打针[da3 zhen1] \"to get an injection\"":
            "do (general verb: 打电话 = make a call)",
        "(of sb or sth) to be (located) at":
            "to be at",
        "(used before a verb to indicate an action in progress)":
            "in the middle of doing",
        "(also, often used before an adjective without intensifying its meaning, i.e. as a meaningless syntactic element)":
            "links to an adjective (not \"very\" here)",
        "(result complement indicating firmness or a stable achieved state)":
            "firmly; holding in place (after a verb)",
        "(modal particle indicating suggestion or surmise)":
            "suggestion or guess: …right?",
        "(after a verb, indicates coming out, completion of an action, or ability to discern or detect)":
            "out; comes out (after a verb)",
        "structural particle: used after a verb (or adjective as main verb), linking it to following phrase indicating effect, degree, possibility etc":
            "links a verb to how or how well",
        "used to indicate passive voice (placed before the doer of the action like \"by\" in English passive-voice sentences, or, if the doer is not mentioned, before the verb)":
            "by (passive)",
        "(since c. 2009) (sarcastic or jocular) used to indicate that the following word should be regarded as being in air quotes (as in 被旅遊|被旅游[bei4 lu : 3 you2] to \"go on a trip\")":
            "\"so-called\" (sarcastic)",
        "(verb complement indicating arriving at a place or reaching a point)":
            "reached; managed to (after a verb)",
        "(past tense marker used before verb or clause)":
            "once; in the past",
        "(used to end an enumeration)":
            "and so on",
        "(literary) (plural suffix attached to a personal pronoun or noun)":
            "plural ending (literary)",
        "structural particle: used before a verb or adjective, linking it to preceding modifying adverbial adjunct":
            "-ly; turns a phrase into an adverb",
        "particle introducing a relative clause or passive":
            "that which (literary)",
        "sentence-final interrogative particle":
            "question ending (literary)",
        "aspect particle indicating action in progress or ongoing state":
            "ongoing: is …ing",
        "(after a verb of motion indicates movement away from the speaker)":
            "away (after a verb of motion)",
        "(used after certain verbs to indicate detachment or separation)":
            "away; off (after a verb)",
        "no matter how ... (followed by an adjective or verb, and then (usually) 也[ye3] or 都[dou1] for emphasis)":
            "no matter how",
        "(used to introduce additional information, as in 再則|再则[zai4 ze2], 再就是[zai4 jiu4 shi4] etc)":
            "what's more",
        "(experienced action marker)":
            "has done before",
        "(grammatical equivalent of 被)":
            "by (same as 被)",
        "(grammatical equivalent of 把)":
            "moves the object forward (same as 把)",
        "(literary) particle having functions similar to 啊[a5]":
            "like 啊 (literary)",
        "measure word to show the frequency of an action":
            "a time; a go (counts actions)",
        "prefix used before the surname of a person or a numeral indicating the order of birth of the children in a family or to indicate affection or familiarity":
            "familiar title before a surname",
        "(verb complement indicating completion)":
            "done properly (after a verb)",
        "(sentence-final particle) used in questions to link back to prior discourse or context (\"what about...?\", \"and...?\")":
            "and you? what about…?",
        "(sentence-final particle) indicating that a state or situation still holds":
            "still; ongoing",
        "(discourse particle) used to mark a slight pause or emphasis in speech":
            "a pause or emphasis",
        "it is only (someone) who ... (as in 只有男性才有此需要[zhi3 you3 nan2 xing4 cai2 you3 ci3 xu1 yao4] \"only men would have such a requirement\")":
            "only",
        "(used to put the object before the verb: 把[ba3] + {noun} + {verb})":
            "moves the object before the verb",
        "(coll.) (used to express disapproval, annoyance etc)":
            "honestly! (annoyed)",
        "(used as a substitute for a more specific verb)":
            "do (stands in for a verb)",
        "(used after 得[de2] to indicate possibility, as in 談得來|谈得来[tan2 de5 lai2], or after 不[bu4] to indicate impossibility, as in 吃不來|吃不来[chi1 bu5 lai2])":
            "can / can't (after a verb)",
        "(prefix indicating ordinal number, as in 第六[di4 liu4] \"sixth\")":
            "-th (makes ordinal numbers)",
        "verb suffix, to start":
            "starting (after a verb)",
        "verb complement indicating thoroughness or completion":
            "through; thoroughly (after a verb)",
        "(question particle for \"yes-no\" questions)":
            "question marker (yes/no)",
        "(used after a verb to indicate an outward direction or a positive result)":
            "out (after a verb)",
        "(indicates continuing motion or action)":
            "straight on; keeps going",
        "(passive marker)":
            "by (passive)",
        "plural marker for pronouns, and nouns referring to individuals":
            "plural (people)",
        "(verb suffix)":
            "over; past (after a verb)",
        "classifier for enumerated events: time":
            "time; occurrence",
        "suffix of a noun of locality":
            "side (ending for place words)",
        "to be sb's turn to do sth":
            "to be someone's turn",
        "\"one\" radical in Chinese characters (Kangxi radical 1)":
            "\"one\" radical",
    ]
}
