import AppKit
import os

let log = Logger(subsystem: "com.dhrlabs.pencilpad", category: "app")

/// Token, chosen screen and the Open at Login flag live in the com.dhrlabs.pencilpad defaults domain,
/// whether the app runs bundled (that is its own domain) or as a raw binary.
@MainActor
enum Settings {
    static let defaults: UserDefaults =
        Bundle.main.bundleIdentifier == "com.dhrlabs.pencilpad"
        ? .standard : UserDefaults(suiteName: "com.dhrlabs.pencilpad")!

    /// 128 random bits, base64url without padding. Made once so the iPad's Home Screen link keeps working.
    static let token: String = {
        if let saved = defaults.string(forKey: "token"), saved.count >= 16 { return saved }
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let made = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        defaults.set(made, forKey: "token")
        return made
    }()

    static var targetScreenID: String? {
        get { defaults.string(forKey: "targetScreen") }
        set { defaults.set(newValue, forKey: "targetScreen") }
    }

    /// Set once the Open at Login default has been applied (or the menu item has been used). After that the app never
    /// registers by itself again, so removing PencilPad from Login Items in System Settings stays removed.
    static var loginItemDecided: Bool {
        get { defaults.bool(forKey: "loginItemDecided") }
        set { defaults.set(newValue, forKey: "loginItemDecided") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// SIGTERM (pkill, logout), SIGINT (Ctrl-C) and SIGHUP (closed terminal) go through normal termination
// so a held button is released.
let quitSignals = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    return source
}

app.run()
