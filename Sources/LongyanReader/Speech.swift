import AVFoundation
import Foundation

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
