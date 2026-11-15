import Foundation
import Translation

/// Whole-phrase translation with Apple's on-device Translation framework.
/// Separate from the sense chooser: this gives a fluent English line for a phrase.
enum Translator {
    private static let chinese = Locale.Language(identifier: "zh-Hans")
    private static let english = Locale.Language(identifier: "en")

    static func status() async -> String {
        switch await LanguageAvailability().status(from: chinese, to: english) {
        case .installed: return "installed"
        case .supported: return "language pack not downloaded"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    /// Needs macOS 26 (a session without SwiftUI); below that the local model translates.
    static func translate(_ text: String) async throws -> String {
        guard #available(macOS 26, *) else {
            throw NSError(domain: "LongyanReader", code: 8, userInfo: [NSLocalizedDescriptionKey: "Apple's translator needs macOS 26"])
        }
        let session = TranslationSession(installedSource: chinese, target: english)
        return try await session.translate(text).targetText
    }
}
