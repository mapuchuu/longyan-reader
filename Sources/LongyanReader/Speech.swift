import AVFoundation
import Foundation

/// What a card's Listen button says, and its tooltip.
struct SpeechPlan: Equatable {
    let text: String
    let help: String
}

/// Reads Chinese aloud with the best Mandarin voice installed (Tingting ships with macOS;
/// an Enhanced or Premium voice downloaded in System Settings is preferred). Nothing to
/// bundle, nothing sent anywhere. Only ever on a click, and it stops when the card goes.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// The text being read, while it's being read.
    @Published private(set) var speaking: String?
    /// 0 for the usage simulation, which presses Listen without making a sound.
    var volume: Float = 1
    private let synth = AVSpeechSynthesizer()

    /// Picked on first use, so a voice downloaded meanwhile is found next launch.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let mandarin = voices.filter { $0.language == "zh-CN" }
        let pool = mandarin.isEmpty ? voices.filter { $0.language.hasPrefix("zh") && $0.language != "zh-HK" } : mandarin
        // Among equal quality, the system's own (Tingting) over the novelty voices.
        return pool.max { a, b in
            a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue < b.quality.rawValue
                                                     : (a.name != "Tingting" && b.name == "Tingting")
        }
    }()

    var available: Bool { voice != nil }

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Reads `text`, or stops if it's the text already being read.
    func toggle(_ text: String) {
        if speaking == text { stop(); return }
        stop()
        guard let voice else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.volume = volume
        // A touch slower than conversation: these are words someone is learning.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speaking = text
        synth.speak(utterance)
    }

    func stop() {
        guard speaking != nil || synth.isSpeaking else { return }
        synth.stopSpeaking(at: .immediate)
        speaking = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in if self.speaking == text { self.speaking = nil } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in if self.speaking == text { self.speaking = nil } }
    }
}

enum Reading {
    /// Whether two numbered readings sound the same: same syllables, same tones, a neutral
    /// tone matching any (关系 guan1 xi5 and guan1 xi4 are one word).
    static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: " "), y = b.lowercased().split(separator: " ")
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { s, t in
            let (sb, st) = split(s), (tb, tt) = split(t)
            return sb == tb && (st == tt || st == 5 || tt == 5)
        }
    }

    private static func split(_ syllable: Substring) -> (String, Int) {
        guard let last = syllable.last, let tone = last.wholeNumberValue else { return (String(syllable), 5) }
        return (String(syllable.dropLast()), tone)
    }
}

extension LookupState {
    /// The word alone when the voice will say it the way this card reads it: a word with one
    /// reading, or this card's reading being its everyday one (the first, in the hand-set
    /// order). A rarer reading (好 as hào) is read in context instead, which the voice gets
    /// right: the word it's part of here (好学), else the clause around it.
    var speech: SpeechPlan {
        let word = context.word
        let common = senses.filter { !$0.rare }
        var readings: [String] = []
        for s in common where !readings.contains(where: { Reading.same($0, s.pinyin) }) { readings.append(s.pinyin) }
        let here = headerPinyin
        if readings.count <= 1 || here.isEmpty || Reading.same(here, common.first?.pinyin ?? here) {
            return SpeechPlan(text: word, help: "Listen to “\(word)”")
        }
        if let part = partOf {
            return SpeechPlan(text: part.word, help: "Listen to “\(part.word)” (\(word) alone has another reading)")
        }
        return SpeechPlan(text: clause, help: "Listen in context (\(word) alone has another reading)")
    }

    /// The clause around the word, up to its punctuation, within about 20 characters each way.
    private var clause: String {
        let stops: Set<Character> = ["。", "！", "？", "；", "，", "、", "：", "!", "?", ";", ",", ":", "\n", "“", "”", "「", "」"]
        let p = context.passage, r = context.wordRange
        var lo = r.lowerBound, hi = r.upperBound
        while lo > 0, !stops.contains(p[lo - 1]), r.lowerBound - lo < 20 { lo -= 1 }
        while hi < p.count, !stops.contains(p[hi]), hi - r.upperBound < 20 { hi += 1 }
        return String(p[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
