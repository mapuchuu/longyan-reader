import AppKit
import SwiftUI

/// Dev only: `--show … --script "<plan>"` (CardShow.swift) works the card from inside the app,
/// for filming without a hand on the mouse. The card's buttons read the pointer state here as
/// well as their own, so a scripted hover or press looks just as a real one does, and a
/// scripted release runs the button's own action. Nothing sets it in normal use: every
/// button then reads nil here and behaves as before.
///
/// A plan is steps "t,action[,target]" separated by ";", t in seconds after the card's reveal
/// has finished (0.5 s after it starts): hover T, unhover, press T, release, click T (press,
/// release 70 ms later), esc, close (a click elsewhere), reopen. Targets: row1… (meanings, in
/// the order shown; in a phrase card, the open row's), phrase-row1…, pin, copy, listen, anki,
/// note, back, showall, partof, badge.
@MainActor
final class CardScript: ObservableObject {
    static let shared = CardScript()
    /// Set by --script: buttons then register their actions under their target names.
    var enabled = false
    @Published var hovered: String?
    @Published var pressed: String?
    @Published var cardHovered = false
    /// Each target's action, as its button runs it on a click.
    var actions: [String: () -> Void] = [:]

    struct Step { let t: Double; let action: String; let target: String? }

    static let actionNames: Set<String> = ["hover", "unhover", "press", "release", "click", "esc", "close", "reopen"]
    static let fixedTargets: Set<String> = ["pin", "copy", "listen", "anki", "note", "back", "showall", "partof", "badge"]

    /// The plan's steps in time order, or why it can't be read.
    static func parse(_ plan: String) -> (steps: [Step], error: String?) {
        var steps: [Step] = []
        for part in plan.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let f = part.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 2, let t = Double(f[0]), actionNames.contains(f[1]) else { return ([], "can't read step \"\(part)\"") }
            let target = f.count > 2 ? f[2] : nil
            if ["hover", "press", "click"].contains(f[1]) {
                guard let target, fixedTargets.contains(target) || target.range(of: #"^(phrase-)?row[1-9][0-9]*$"#, options: .regularExpression) != nil
                else { return ([], "step \"\(part)\" needs a target: row1…, phrase-row1…, " + fixedTargets.sorted().joined(separator: ", ")) }
            }
            steps.append(Step(t: t, action: f[1], target: target))
        }
        return (steps.sorted { $0.t < $1.t }, nil)
    }

    /// One line on stderr per step, with the time since boot (monotonic) to line films up.
    static func log(_ text: String) {
        FileHandle.standardError.write(Data(String(format: "script mono=%.3f %@\n", ProcessInfo.processInfo.systemUptime, text).utf8))
    }
}

private struct ScriptTargetKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The script's name for the button inside (CardScript).
    var scriptTarget: String? {
        get { self[ScriptTargetKey.self] }
        set { self[ScriptTargetKey.self] = newValue }
    }
}

extension View {
    /// Names this button for a script, and gives the script its action (CardScript).
    func scriptTarget(_ name: String, action: @escaping () -> Void) -> some View {
        environment(\.scriptTarget, name).background(ScriptRegistration(name: name, action: action))
    }
}

private struct ScriptRegistration: View {
    let name: String
    let action: () -> Void
    var body: some View {
        if CardScript.shared.enabled, !name.isEmpty { CardScript.shared.actions[name] = action }
        return Color.clear.allowsHitTesting(false)
    }
}
