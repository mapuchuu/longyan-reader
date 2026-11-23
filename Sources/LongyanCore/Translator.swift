import Foundation

/// Whole-phrase translation by the system's own translator (`Platform.translator`, Apple's
/// on-device Translation framework on the Mac): the fallback when the reading model can't
/// translate, and what some sense checks compare against. Separate from the sense chooser:
/// this gives a fluent English line for a phrase.
package enum Translator {
    package static func translate(_ text: String) async throws -> String {
        guard let translator = Platform.translator else {
            throw NSError(domain: "LongyanReader", code: 8, userInfo: [NSLocalizedDescriptionKey: "download the reading model to translate"])
        }
        return try await translator.translate(text)
    }
}
