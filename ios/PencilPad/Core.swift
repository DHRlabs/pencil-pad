import Foundation
import os
import UIKit

let log = Logger(subsystem: "com.dhrlabs.pencilpad.ipad", category: "app")
let wire = Logger(subsystem: "com.dhrlabs.pencilpad.ipad", category: "wire")

/// Numbers that come straight from web/app.js, so the iPad app and the page behave alike.
enum Tuning {
    static let pingEvery = 0.5         // seconds between pings
    static let deadAfter = 3.0         // no frame from the Mac this long while connected: reconnect
    static let listLimit = 8.0         // the same, while the Mac builds its window list (it closes a client silent for 10 s)
    static let connectLimit = 6.0      // a connection that has not opened by now is dropped and retried
    static let helloLimit = 6.0        // an open connection whose Mac sent no challenge by now is dropped and retried
    static let idleSleep = 600.0       // the iPad may sleep again after this long without a Pencil touch
    static let closeLimit = 1.0        // a close frame that has not gone out by now: the connection is cancelled
    static let pad: CGFloat = 14       // gap between the active area and the screen edges
    static let gap: CGFloat = 12       // gap between the toolbar and the active area
    static let palm: CGFloat = 30      // a contact wider than this (points across) is a palm
    static let zoomMinW: CGFloat = 1.0 / 8   // the most zoomed in: the region is this fraction of the target's width
    static let zoomHold = 0.6          // press and hold Zoom this long to show the whole target again
    static let projMax: CGFloat = 2048 // longest side asked for, in device pixels
    static let projPenSeconds = 0.1    // while the Pencil is down a picture is shown at most this often
    static let barHeight: CGFloat = 52
    static let barInset: CGFloat = 8
    static let backoffStart = 500, backoffCap = 5000
}

/// Aim (the Wacom tip threshold): a touch lighter than this moves the cursor without clicking.
enum AimMode: String, CaseIterable, Sendable {
    case off, soft, firm

    var threshold: Double {
        switch self {
        case .off: 0
        case .soft: 0.12
        case .firm: 0.25
        }
    }

    var name: String {
        switch self {
        case .off: "Off"
        case .soft: "Soft"
        case .firm: "Firm"
        }
    }

    var next: AimMode {
        let all = AimMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct ScreenInfo: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let w: Double
    let h: Double
    let main: Bool

    /// "Laptop" for the built-in display, else the display's own name.
    var short: String {
        name.range(of: "built-?in|color lcd", options: [.regularExpression, .caseInsensitive]) != nil ? "Laptop" : (name.isEmpty ? "Screen" : name)
    }
}

struct TargetInfo: Equatable, Sendable {
    let id: String
    let name: String
    let w: Double
    let h: Double
    let app: String?

    /// Each screen keeps its own region; every window target is just "window", so those are kept per app.
    var regionKey: String { id == "window" && !(app ?? "").isEmpty ? "window:" + app! : id }
    var kind: String { id == "window" ? "window" : "screen" }
}

struct WindowItem: Identifiable, Equatable, Sendable {
    let id: Int
    let app: String
    let title: String
    let w: Int
    let h: Int
    let current: Bool
}

struct ChipItem: Identifiable, Equatable {
    let id: String
    let label: String
    let active: Bool
    let pending: Bool
    let isWindow: Bool
    let hint: String
}

/// Launch arguments for testing a build in the Simulator, where there is no Apple Pencil. Debug builds only; a release
/// build has none of this. Read straight from the process arguments (UserDefaults would swallow a flag that has no value).
enum Debug {
    #if DEBUG
    private static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.lastIndex(of: flag), i + 1 < args.count else { return nil }  // the last one given wins
        return args[i + 1]
    }
    /// -debugFingerAsPencil: a finger drives the Mac like the Pencil does (hover never does).
    static let fingerAsPencil = ProcessInfo.processInfo.arguments.contains("-debugFingerAsPencil")
    /// -debugOnlyApp <name>: nothing that moves or clicks the Mac's cursor, presses its keys, or is projected leaves the
    /// iPad unless the Mac's target is a window of that app. Finger-as-Pencil without it sends nothing at all.
    static let onlyApp = value("-debugOnlyApp")
    /// -debugHost <host:port>: connect straight to that WebSocket instead of browsing Bonjour.
    static let host = value("-debugHost")
    /// -debugPressure <0...1>: the pressure a finger-as-Pencil touch reports.
    static let pressure: Double? = value("-debugPressure").flatMap(Double.init)
    /// -debugPressureRamp: a finger-as-Pencil touch starts at 0.05, rises to 0.35 over 1.2 s, then drops to 0.02 (to try
    /// Aim crossing the threshold, then the hysteresis after it).
    static let pressureRamp = ProcessInfo.processInfo.arguments.contains("-debugPressureRamp")
    /// -debugIdleSeconds <n>: the idle-sleep cutoff, so a test does not wait 10 minutes.
    static let idleSeconds: Double? = value("-debugIdleSeconds").flatMap(Double.init)
    /// -debugTouchRadius <points>: every finger touch counts as this big (the Simulator gives every touch 37 pt).
    static let touchRadius: CGFloat? = value("-debugTouchRadius").flatMap(Double.init).map { CGFloat($0) }
    #else
    static let fingerAsPencil = false
    static let onlyApp: String? = nil
    static let host: String? = nil
    static let pressure: Double? = nil
    static let pressureRamp = false
    static let idleSeconds: Double? = nil
    static let touchRadius: CGFloat? = nil
    #endif
}

/// How big a touch is, as the palm rule sees it (a debug run can set it).
@MainActor func contactRadius(_ t: UITouch) -> CGFloat { Debug.touchRadius ?? t.majorRadius }

@inline(__always) func r5(_ v: Double) -> Double { (v * 1e5).rounded() / 1e5 }
@inline(__always) func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }
