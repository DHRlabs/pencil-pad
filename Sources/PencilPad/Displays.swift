import AppKit
import ApplicationServices
import CoreGraphics

/// One display. All geometry is CGDisplayBounds: global space, top-left origin, points.
struct Screen: Equatable {
    let id: String  // display UUID
    let name: String
    let bounds: CGRect
    let main: Bool

    var json: [String: Any] {
        ["id": id, "name": name, "w": bounds.width, "h": bounds.height, "main": main]
    }

    static func all() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuid) as String?
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return Screen(id: uuidString, name: screen.localizedName,
                          bounds: CGDisplayBounds(displayID), main: CGDisplayIsMain(displayID) != 0)
        }
    }
}

/// The rect Pencil coordinates map into: a screen, or the front window captured at pick time.
struct Target: Equatable {
    let id: String  // screen UUID or "window"
    let name: String
    let rect: CGRect

    var json: [String: Any] { ["id": id, "name": name, "w": rect.width, "h": rect.height] }

    /// x, y are 0...1 in the target, top-left origin. Clamped to the rect so the cursor never leaves it.
    func point(x: Double, y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        let px = rect.minX + cx * rect.width, py = rect.minY + cy * rect.height
        return CGPoint(x: min(max(px, rect.minX), rect.maxX - 1),
                       y: min(max(py, rect.minY), rect.maxY - 1))
    }
}

@MainActor
final class Targets {
    private(set) var screens: [Screen]
    private(set) var current: Target

    init() {
        let screens = Screen.all()
        self.screens = screens
        let saved = screens.first { $0.id == Settings.targetScreenID }
        let pick = saved ?? screens.first { $0.main } ?? screens.first
        current = pick.map { Target(id: $0.id, name: $0.name, rect: $0.bounds) }
            ?? Target(id: "none", name: "No screen", rect: CGDisplayBounds(CGMainDisplayID()))
    }

    /// Pick a screen by UUID (persisted) or "window" (read now, not persisted). Returns false if nothing changed.
    @discardableResult
    func select(_ id: String) -> Bool {
        if id == "window" {
            guard let window = Self.frontWindow() else { return false }
            current = window
        } else {
            guard let screen = screens.first(where: { $0.id == id }) else {
                log.error("target: unknown screen id \(id, privacy: .public); keeping \(self.current.name, privacy: .public)")
                return false
            }
            current = Target(id: screen.id, name: screen.name, rect: screen.bounds)
            Settings.targetScreenID = screen.id
        }
        log.notice("target: \(self.current.name, privacy: .public) \(self.current.id, privacy: .public) rect \(NSStringFromRect(self.current.rect), privacy: .public)")
        return true
    }

    /// Re-read displays. Returns which parts changed so the caller can push them to the page.
    func refresh() -> (screens: Bool, target: Bool) {
        let fresh = Screen.all()
        let screensChanged = fresh != screens
        screens = fresh
        guard current.id != "window" else { return (screensChanged, false) }
        let old = current
        if let same = fresh.first(where: { $0.id == current.id }) {
            current = Target(id: same.id, name: same.name, rect: same.bounds)
        } else if let main = fresh.first(where: { $0.main }) ?? fresh.first {
            log.notice("target: screen \(old.id, privacy: .public) is gone; falling back to main \(main.name, privacy: .public)")
            current = Target(id: main.id, name: main.name, rect: main.bounds)
            Settings.targetScreenID = main.id
        }
        if current != old {
            log.notice("target: now \(self.current.name, privacy: .public) rect \(NSStringFromRect(self.current.rect), privacy: .public)")
        }
        return (screensChanged, current != old)
    }

    /// Frontmost app's focused window through Accessibility, in the same global top-left space.
    static func frontWindow() -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            log.error("target window: no frontmost app; keeping previous target")
            return nil
        }
        let appName = front.localizedName ?? "App"
        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard err == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            log.error("target window: cannot read focused window of \(appName, privacy: .public) (AXError \(err.rawValue), trusted \(AXIsProcessTrusted())); keeping previous target")
            return nil
        }
        let window = windowRef as! AXUIElement
        var origin = CGPoint.zero, size = CGSize.zero
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width >= 1, size.height >= 1
        else {
            log.error("target window: cannot read position/size of \(appName, privacy: .public) window; keeping previous target")
            return nil
        }
        return Target(id: "window", name: "\(appName) window", rect: CGRect(origin: origin, size: size))
    }
}
