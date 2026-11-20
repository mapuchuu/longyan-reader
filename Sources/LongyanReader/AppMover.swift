import AppKit

/// Moves the app into /Applications and opens it from there. Run from Downloads, macOS opens a
/// read-only copy from a temporary folder (translocation), and Sparkle refuses to update it; the
/// reader only finds out weeks later, at the first update. So the app offers the move at launch.
/// Settings, history and the model live in ~/Library and stay put, and the Accessibility grant
/// follows the signing certificate, not the path.
@MainActor
enum AppMover {
    /// Asks at launch. A translocated copy asks every time (it can never update); a copy that
    /// is merely somewhere else asks once. Returns true when the app is moving and about to quit.
    @discardableResult
    static func offerAtLaunch() -> Bool {
        guard Updates.available, Onboarding.outsideApplications else { return false }
        let key = "mover.askedFor"
        if !Onboarding.translocated, UserDefaults.standard.string(forKey: key) == Bundle.main.bundlePath { return false }
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: key)
        return offer()
    }

    /// The Move to Applications question. Returns true when the app is moving and about to quit.
    @discardableResult
    static func offer() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Longyan Reader to Applications?"
        alert.informativeText = Onboarding.translocated
            ? "It's running from your Downloads folder, where it can't install updates. Your settings stay as they are."
            : "Updates install only into the Applications folder. Your settings stay as they are."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return move()
    }

    private static func move() -> Bool {
        let source = originalURL
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        do {
            // An older copy already there goes to the Trash, where it can be got back.
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.moveItem(at: source, to: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't move Longyan Reader"
            alert.informativeText = "\(error.localizedDescription)\n\nQuit it, then drag Longyan Reader into Applications in Finder and open it from there."
            alert.runModal()
            return false
        }
        // macOS already approved this app when it first opened. Without the quarantine flag it
        // runs from Applications itself, as after a Finder drag, instead of from another
        // temporary copy.
        clearQuarantine(dest)
        relaunch(dest)
        return true
    }

    /// The bundle on disk: for a translocated copy, the one in Downloads it was made from.
    static var originalURL: URL {
        let url = Bundle.main.bundleURL
        guard Onboarding.translocated,
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(sym, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }

    private static func clearQuarantine(_ app: URL) {
        let name = "com.apple.quarantine"
        removexattr(app.path, name, XATTR_NOFOLLOW)
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let f = files?.nextObject() as? URL { removexattr(f.path, name, XATTR_NOFOLLOW) }
    }

    /// Opens the moved copy once this one has quit (two copies would both hold ⌃⌥L).
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
