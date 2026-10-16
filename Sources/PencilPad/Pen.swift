import AppKit
import CoreGraphics

/// Turns Pencil messages into HID-level mouse/tablet events. Owns the one held button.
@MainActor
final class Pen {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var held: CGMouseButton?
    private var last = CGPoint.zero
    private var loggedFirstPost = false
    /// Click count for the current press (2 = double, 3 = triple); its drags and up carry the same value.
    private var clickState: Int64 = 1
    /// Previous press, in the page's 0...1 coordinates on its target, for double-click detection.
    private var lastDown: (time: TimeInterval, page: CGPoint, target: Target, button: CGMouseButton)?

    func hover(_ at: CGPoint) {
        // A move with no button down stays a plain move; a hover while held means the lift was lost.
        if held != nil { release(reason: "hover arrived while button held") }
        post(.mouseMoved, at: at, button: .left, pressure: 0, tilt: (0, 0))
    }

    func down(_ at: CGPoint, page: CGPoint, target: Target, pressure: Double, tilt: (Double, Double), right: Bool) {
        if held != nil { release(reason: "down arrived while button held") }
        let button: CGMouseButton = right ? .right : .left
        let now = ProcessInfo.processInfo.systemUptime
        if let prev = lastDown, prev.button == button, prev.target == target,
           now - prev.time <= NSEvent.doubleClickInterval,
           hypot(page.x - prev.page.x, page.y - prev.page.y) <= 0.004 {
            clickState += 1
        } else {
            clickState = 1
        }
        lastDown = (now, page, target, button)
        held = button
        post(right ? .rightMouseDown : .leftMouseDown, at: at, button: button, pressure: pressure, tilt: tilt)
    }

    func move(_ at: CGPoint, pressure: Double, tilt: (Double, Double)) {
        guard let button = held else {
            log.debug("move ignored: no button held")
            return
        }
        post(button == .right ? .rightMouseDragged : .leftMouseDragged, at: at, button: button, pressure: pressure, tilt: tilt)
    }

    func up(_ at: CGPoint) {
        guard let button = held else {
            log.debug("up ignored: no button held")
            return
        }
        held = nil
        post(button == .right ? .rightMouseUp : .leftMouseUp, at: at, button: button, pressure: 0, tilt: (0, 0))
    }

    /// Forced release at the last posted position. Every lost-stroke path ends here.
    func release(reason: String) {
        guard let button = held else {
            log.notice("release check (\(reason, privacy: .public)): button held: none")
            return
        }
        held = nil
        post(button == .right ? .rightMouseUp : .leftMouseUp, at: last, button: button, pressure: 0, tilt: (0, 0))
        log.notice("forced release \(button == .right ? "right" : "left", privacy: .public) at \(NSStringFromPoint(self.last), privacy: .public): \(reason, privacy: .public)")
    }

    func key(_ name: String) {
        let combo: (CGKeyCode, CGEventFlags)
        switch name {
        case "undo": combo = (6, .maskCommand)                  // kVK_ANSI_Z
        case "redo": combo = (6, [.maskCommand, .maskShift])
        case "escape": combo = (53, [])                         // kVK_Escape
        default:
            log.error("key: unknown name \(name, privacy: .public)")
            return
        }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.0, keyDown: isDown) else { continue }
            event.flags = combo.1
            event.post(tap: .cghidEventTap)
        }
        noteFirstPost("key \(name)")
        log.debug("key \(name, privacy: .public)")
    }

    private func post(_ type: CGEventType, at: CGPoint, button: CGMouseButton, pressure: Double, tilt: (Double, Double)) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button) else {
            log.error("could not create event type \(type.rawValue)")
            return
        }
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        let pressure = pressure.isFinite ? min(max(pressure, 0), 1) : 0
        event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: min(max(tilt.0 / 90, -1), 1))
        event.setDoubleValueField(.tabletEventTiltY, value: min(max(tilt.1 / 90, -1), 1))
        event.post(tap: .cghidEventTap)
        last = at
        noteFirstPost("mouse type \(type.rawValue)")
        log.debug("posted \(type.rawValue) at \(NSStringFromPoint(at), privacy: .public) p \(pressure) clicks \(type == .mouseMoved ? 0 : self.clickState)")
    }

    private func noteFirstPost(_ what: String) {
        guard !loggedFirstPost else { return }
        loggedFirstPost = true
        log.notice("first posted event: \(what, privacy: .public); post access preflight \(CGPreflightPostEventAccess())")
    }
}
