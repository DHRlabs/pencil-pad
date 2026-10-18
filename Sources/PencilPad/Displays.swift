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

/// The rect Pencil coordinates map into: a screen, or a window (which keeps following that window).
struct Target: Equatable {
    let id: String  // screen UUID or "window"
    let name: String
    let rect: CGRect
    /// A window target's app name, so the page can label its chip without taking `name` apart.
    var app: String? = nil

    var json: [String: Any] {
        var json: [String: Any] = ["id": id, "name": name, "w": rect.width, "h": rect.height]
        if let app { json["app"] = app }
        return json
    }

    /// x, y are 0...1 in the target, top-left origin. Clamped to the rect so the cursor never leaves it.
    func point(x: Double, y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        let px = rect.minX + cx * rect.width, py = rect.minY + cy * rect.height
        return CGPoint(x: min(max(px, rect.minX), rect.maxX - 1),
                       y: min(max(py, rect.minY), rect.maxY - 1))
    }
}

/// An Accessibility element carried between queues. The Accessibility API may be used from any thread.
struct AXBox: @unchecked Sendable { let element: AXUIElement }

/// Numbers requests so an older one can tell, from any thread, that a newer one has overtaken it.
final class LatestRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; latest += 1; return latest }
    func isCurrent(_ n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return n == latest }
}

/// A window from the Accessibility list, as the page's picker shows it and as a pick acts on it.
struct WindowInfo: @unchecked Sendable {
    let pid: pid_t
    let app: String
    let title: String
    let rect: CGRect
    let element: AXUIElement
    let front: Bool  // the frontmost app's focused window
}

@MainActor
final class Targets {
    private let pen: Pen
    private(set) var screens: [Screen]
    /// Every target change (page pick, menu pick, display fallback) lifts a held button first,
    /// so a stroke never continues into a different rect.
    private(set) var current: Target {
        didSet {
            if current != oldValue {
                pen.release(reason: "target changed to \(current.name)")
                onChange?()
            }
            if current.id != "window" { followed = nil }
        }
    }
    /// Told whenever the target changes: another target, or the same window moved or resized.
    var onChange: (@MainActor () -> Void)?
    /// The app that owns the window target.
    var windowPID: pid_t? { current.id == "window" ? followed?.pid : nil }
    /// Moves on each time a window is made the target, so "the same window" can be told from "another window".
    private(set) var windowSerial = 0
    /// The Accessibility element of the window target, kept so the target follows that window.
    private var followed: (element: AXUIElement, pid: pid_t)?
    /// Earliest time the followed window's frame is read again while only hovering.
    private var nextRead: TimeInterval = 0
    /// An app that did not answer is not asked again before this, not even for a Pencil down.
    private var retryAfter: TimeInterval = 0
    /// The window list the page last asked for. Pick ids index into it until the next list.
    private var listed: [Int: WindowInfo] = [:]
    /// Which list request is the newest; an older one that finishes later is dropped, not answered.
    private let listRequests = LatestRequest()
    /// Counts target choices (a screen, the front window, a window pick). A window choice takes a while when the app is slow
    /// to answer; it only takes effect if no newer choice arrived meanwhile.
    private let choices = LatestRequest()
    /// A follow read is out on the Accessibility queue; no second one goes until it is back.
    private var followInFlight = false
    /// Waiting for the read that is out (or about to go): told once its answer has been applied.
    private var followWaiters: [@MainActor () -> Void] = []
    /// Told when a window target's resize, or its disappearance, changed what the page shows.
    var onFollowChange: (@MainActor () -> Void)?

    init(pen: Pen) {
        self.pen = pen
        let screens = Screen.all()
        self.screens = screens
        current = Self.preferred(screens).map { Target(id: $0.id, name: $0.name, rect: $0.bounds) }
            ?? Target(id: "none", name: "No screen", rect: CGDisplayBounds(CGMainDisplayID()))
    }

    /// The saved screen when it is connected, else main for now. Never writes the saved choice:
    /// only an explicit pick in select() does, so a screen that drops out is picked back up when it returns.
    private static func preferred(_ screens: [Screen]) -> Screen? {
        let savedID = Settings.targetScreenID
        if let saved = screens.first(where: { $0.id == savedID }) { return saved }
        if let savedID {
            log.notice("target: saved screen \(savedID, privacy: .public) is not connected; using main for now, saved choice kept")
        }
        return screens.first { $0.main } ?? screens.first
    }

    /// Pick a screen by UUID (persisted). Returns false if nothing changed. A window is chosen with
    /// `selectFrontWindow` or `pick(window:)`, which talk to other apps and so never run on the main thread.
    @discardableResult
    func select(_ id: String) -> Bool {
        _ = choices.next()
        guard let screen = screens.first(where: { $0.id == id }) else {
            log.error("target: unknown screen id \(id, privacy: .public); keeping \(self.current.name, privacy: .public)")
            return false
        }
        current = Target(id: screen.id, name: screen.name, rect: screen.bounds)
        Settings.targetScreenID = screen.id
        log.notice("target: \(self.current.name, privacy: .public) \(self.current.id, privacy: .public) rect \(NSStringFromRect(self.current.rect), privacy: .public)")
        return true
    }

    /// Re-read displays. Returns which parts changed so the caller can push them to the page.
    func refresh() -> (screens: Bool, target: Bool) {
        let fresh = Screen.all()
        let screensChanged = fresh != screens
        screens = fresh
        // A window target stays put; a screen target follows the saved choice (back to it when it returns).
        guard current.id != "window", let want = Self.preferred(fresh) else { return (screensChanged, false) }
        let old = current
        current = Target(id: want.id, name: want.name, rect: want.bounds)  // didSet releases a held button on change
        if current != old {
            log.notice("target: now \(self.current.name, privacy: .public) rect \(NSStringFromRect(self.current.rect), privacy: .public)")
        }
        return (screensChanged, current != old)
    }

    // MARK: Windows (Accessibility API; global top-left points, the same space as CGDisplayBounds)
    //
    // Every Accessibility call is made on one background queue (AXWindows.queue). An app that stops answering costs its
    // 0.5 s timeout there and never on the main thread, so pings, hover and down keep flowing. The main actor only stores
    // what comes back, and it alone changes the target.

    /// Builds the list of windows a person can point the Pencil at (front to back) on the Accessibility queue, then
    /// stores it for `pick(window:)` and hands it to `done`. Ids are 1...n and last until the next list. If a newer
    /// request overtakes this one, this one is dropped and never answered.
    func requestWindowList(_ done: @escaping @MainActor ([[String: Any]]) -> Void) {
        let mine = listRequests.next(), requests = listRequests
        let me = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .map { AXWindows.App(pid: $0.processIdentifier, name: $0.localizedName ?? "App") }
        AXWindows.queue.async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            guard let found = AXWindows.list(apps: apps, frontPID: frontPID, isCurrent: { requests.isCurrent(mine) }) else {
                log.notice("window list: request \(mine) was overtaken by a newer one; dropped")
                return
            }
            log.notice("window list: \(found.count) windows from \(apps.count) apps built in \(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6, format: .fixed(precision: 1)) ms, off the main thread")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishList(found, request: mine, done) } }
        }
    }

    private func finishList(_ found: [WindowInfo], request: Int, _ done: @MainActor ([[String: Any]]) -> Void) {
        guard listRequests.isCurrent(request) else { return }
        listed = [:]
        done(found.enumerated().map { n, info in
            listed[n + 1] = info
            let isCurrent = current.id == "window" && followed.map { CFEqual($0.element, info.element) } == true
            return ["id": n + 1, "app": info.app, "title": info.title, "w": Int(info.rect.width.rounded()),
                    "h": Int(info.rect.height.rounded()), "front": info.front, "current": isCurrent]
        })
    }

    /// Makes the front app's focused window the target (read now, not persisted). `done` is told whether it worked.
    func selectFrontWindow(_ done: @escaping @MainActor (Bool) -> Void) {
        let mine = choices.next(), choices = choices
        guard let front = NSWorkspace.shared.frontmostApplication else {
            log.error("target window: no frontmost app; keeping previous target")
            done(false)
            return
        }
        let pid = front.processIdentifier, name = front.localizedName ?? "App"
        AXWindows.queue.async { [weak self] in
            // A newer choice that is already in makes this one pointless: skip the Accessibility calls altogether.
            let stale = !choices.isCurrent(mine)
            let box = stale ? nil : AXWindows.focusedWindow(pid: pid, name: name)
            let target = box.flatMap { AXWindows.windowTarget($0.element, app: name) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { done(false); return }
                    guard choices.isCurrent(mine) else {  // a newer choice came in while this one waited on the app
                        log.notice("target: front window choice overtaken by a newer choice; not applied")
                        done(false)
                        return
                    }
                    guard let box, let target else { done(false); return }
                    self.current = target
                    self.follow(box.element, pid)
                    log.notice("target: \(self.current.name, privacy: .public) \(self.current.id, privacy: .public) rect \(NSStringFromRect(self.current.rect), privacy: .public)")
                    done(true)
                }
            }
        }
    }

    /// Makes window `n` of the latest list the target and brings it to the front: restore it if minimized,
    /// activate its app, raise it, make it the app's main window. `done` is told false (target unchanged) for an
    /// unknown id or a window that can no longer be read.
    func pick(window n: Int, _ done: @escaping @MainActor (Bool) -> Void) {
        let mine = choices.next(), choices = choices
        guard let info = listed[n] else {
            log.error("target: unknown window id \(n); keeping \(self.current.name, privacy: .public)")
            done(false)
            return
        }
        let running = NSRunningApplication(processIdentifier: info.pid)
        if running?.isHidden == true { running?.unhide() }
        AXWindows.queue.async { [weak self] in
            // Between its Accessibility steps a pick checks that it is still the newest choice, and stops if not: an
            // overtaken pick neither raises its window nor keeps the queue busy behind a slow app.
            let codes = AXWindows.raise(info, isCurrent: { choices.isCurrent(mine) })
            let target = choices.isCurrent(mine) ? AXWindows.windowTarget(info.element, app: info.app) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { done(false); return }
                    guard choices.isCurrent(mine) else {  // a newer choice came in while this one waited on the app
                        log.notice("target: window pick \(n) overtaken by a newer choice; not applied")
                        done(false)
                        return
                    }
                    let activated = NSRunningApplication(processIdentifier: info.pid)?.activate() ?? false
                    log.notice("pick \(n): \(info.app, privacy: .public) frontmost \(codes.frontmost.rawValue) raise \(codes.raised.rawValue) main \(codes.main.rawValue) activate \(activated)")
                    guard let target else { done(false); return }
                    self.current = target
                    self.follow(info.element, info.pid)
                    log.notice("target: \(self.current.name, privacy: .public) picked from the window list, rect \(NSStringFromRect(self.current.rect), privacy: .public)")
                    done(true)
                }
            }
        }
    }

    /// Starts following a window: its frame is read fresh, and no earlier timeout counts against it.
    private func follow(_ element: AXUIElement, _ pid: pid_t) {
        followed = (element, pid)
        windowSerial += 1
        nextRead = 0
        retryAfter = 0
    }

    /// A window target follows its window. Its frame is read on the Accessibility queue, at most every 250 ms (`force`
    /// skips that wait), and the answer is applied here when it comes back; nothing on the main thread waits for it.
    /// Never while a button is held, so a window that moves mid-drag cannot release it. Only a definite answer ends the
    /// target: a window or app that no longer exists drops it to the main screen, the same fallback a vanished display
    /// takes. A busy app that does not answer keeps the last frame and is not asked again for a second.
    func followWindow(force: Bool = false) {
        guard current.id == "window", let followed, pen.held == nil, !followInFlight else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAfter, force || now >= nextRead else { return }
        nextRead = now + 0.25
        followInFlight = true
        let serial = windowSerial, box = AXBox(element: followed.element), pid = followed.pid
        AXWindows.queue.async { [weak self] in
            let read = AXWindows.frame(of: box.element)
            let rect = read.rect, error = read.error
            let running = NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyFollow(rect, error, appRunning: running, serial: serial) } }
        }
    }

    /// A fresh read of the window target's frame, for the first touch after a quiet spell. `done` runs once its answer has
    /// been applied, or at once if there is nothing to read (not a window, a button held, an app that is not answering).
    func refreshFrame(_ done: @escaping @MainActor () -> Void) {
        followWaiters.append(done)
        if followInFlight { return }  // the read already out will call it
        followWindow(force: true)
        if !followInFlight { flushFollowWaiters() }
    }

    private func flushFollowWaiters() {
        let waiting = followWaiters
        followWaiters = []
        for done in waiting { done() }
    }

    private func applyFollow(_ rect: CGRect?, _ error: AXError, appRunning: Bool, serial: Int) {
        followInFlight = false
        defer { flushFollowWaiters() }
        // Another window by now, or a button is held: this answer is dropped and the next read will do.
        guard serial == windowSerial, current.id == "window", pen.held == nil else { return }
        if let rect, rect.width >= 1, rect.height >= 1 {
            guard rect != current.rect else { return }
            let resized = rect.size != current.rect.size
            current = Target(id: current.id, name: current.name, rect: rect, app: current.app)
            if resized { onFollowChange?() }
            return
        }
        guard error == .invalidUIElement || !appRunning else {
            retryAfter = ProcessInfo.processInfo.systemUptime + 1
            log.error("target window: no answer for \(self.current.name, privacy: .public) (AXError \(error.rawValue)); keeping its last frame")
            return
        }
        guard let main = screens.first(where: \.main) ?? screens.first else { return }
        log.notice("target: window \(self.current.name, privacy: .public) is gone; back to \(main.name, privacy: .public)")
        current = Target(id: main.id, name: main.name, rect: main.bounds)  // didSet releases a held button and drops the window
        onFollowChange?()
    }
}

/// All the Accessibility reads and actions on other apps' windows. Nothing here touches the Targets' state, so it all
/// runs on `queue`, one call after another; the 0.5 s messaging timeout bounds what a stuck app can cost.
private enum AXWindows {
    static let queue = DispatchQueue(label: "pencilpad.ax", qos: .userInitiated)

    struct App: Sendable {
        let pid: pid_t
        let name: String
    }

    /// The window list, front to back, or nil if `isCurrent` says a newer request has overtaken this one. Minimized and
    /// tiny (under 80 x 80 points) windows are left out, and an app that stops answering is skipped after its first timeout.
    static func list(apps: [App], frontPID: pid_t?, isCurrent: () -> Bool) -> [WindowInfo]? {
        // On-screen windows, front to back. Owner pid and bounds need no Screen Recording permission; names would.
        let stack: [(pid: pid_t, rect: CGRect)] =
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { entry in
                guard (entry[kCGWindowLayer as String] as? Int) == 0,
                      let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { return nil }
                return (pid, rect)
            }
        var taken = Set<Int>()
        var found: [(info: WindowInfo, place: Int)] = []
        for app in apps {
            if !isCurrent() { return nil }
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)  // one stuck app costs at most half a second
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement]
            else { continue }
            var focusedRef: CFTypeRef?
            if app.pid == frontPID { _ = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.5)
                let role = attribute(window, kAXRoleAttribute), minimized = attribute(window, kAXMinimizedAttribute)
                let frame = frame(of: window)
                // An app that stopped answering would cost half a second per read: leave the rest of its windows.
                if [role.error, minimized.error, frame.error].contains(.cannotComplete) {
                    log.error("window list: \(app.name, privacy: .public) stopped answering; skipping its other windows")
                    break
                }
                // Finder's desktop is listed among its windows but is a scroll area, not a window.
                guard (role.value as? String) == kAXWindowRole, (minimized.value as? Bool) != true,
                      let rect = frame.rect, rect.width >= 80, rect.height >= 80 else { continue }
                // The first unclaimed on-screen window of this app with the same bounds is this one's place in the stack.
                let place = stack.indices.first { i in
                    !taken.contains(i) && stack[i].pid == app.pid
                        && abs(stack[i].rect.minX - rect.minX) < 2 && abs(stack[i].rect.minY - rect.minY) < 2
                        && abs(stack[i].rect.width - rect.width) < 2 && abs(stack[i].rect.height - rect.height) < 2
                }
                if let place { taken.insert(place) }
                found.append((WindowInfo(pid: app.pid, app: app.name, title: windowTitle(window), rect: rect, element: window,
                                         front: focusedRef.map { CFEqual($0, window) } ?? false),
                              place ?? Int.max))  // not on this Space or hidden: after the ones on screen
            }
        }
        let order = found.indices.sorted { a, b in
            let (x, y) = (found[a], found[b])
            if x.info.front != y.info.front { return x.info.front }
            return x.place != y.place ? x.place < y.place : a < b
        }
        return order.map { found[$0].info }
    }

    /// The window the app is focused on.
    static func focusedWindow(pid: pid_t, name: String) -> AXBox? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard err == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            log.error("target window: cannot read focused window of \(name, privacy: .public) (AXError \(err.rawValue), trusted \(AXIsProcessTrusted())); keeping previous target")
            return nil
        }
        return AXBox(element: windowRef as! AXUIElement)
    }

    /// A window as a target: named "<App>: <title>" (the title cut to 40 characters), frame read now.
    static func windowTarget(_ window: AXUIElement, app: String) -> Target? {
        AXUIElementSetMessagingTimeout(window, 0.5)
        guard let rect = frame(of: window).rect, rect.width >= 1, rect.height >= 1 else {
            log.error("target window: cannot read position/size of \(app, privacy: .public) window; keeping previous target")
            return nil
        }
        let title = String(windowTitle(window).prefix(40)).trimmingCharacters(in: .whitespaces)
        return Target(id: "window", name: title.isEmpty ? app : "\(app): \(title)", rect: rect, app: app)
    }

    /// Restores the window if minimized, then makes its app frontmost, raises it and makes it the app's main window.
    /// `isCurrent` is asked between the steps; once it says no (a newer choice came in) the rest are skipped.
    static func raise(_ info: WindowInfo, isCurrent: () -> Bool) -> (frontmost: AXError, raised: AXError, main: AXError) {
        let skipped = AXError.cannotComplete
        guard isCurrent() else { return (skipped, skipped, skipped) }
        if isMinimized(info.element) {
            AXUIElementSetAttributeValue(info.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let axApp = AXUIElementCreateApplication(info.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard isCurrent() else { return (skipped, skipped, skipped) }
        // The app's own Frontmost attribute is what a background (accessory) app can rely on to activate another app.
        let frontmost = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard isCurrent() else { return (frontmost, skipped, skipped) }
        let raised = AXUIElementPerformAction(info.element, kAXRaiseAction as CFString)
        guard isCurrent() else { return (frontmost, raised, skipped) }
        let main = AXUIElementSetAttributeValue(info.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        return (frontmost, raised, main)
    }

    /// The window's frame, or the AX error that stopped the read.
    static func frame(of window: AXUIElement) -> (rect: CGRect?, error: AXError) {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        if err == .success { err = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) }
        var origin = CGPoint.zero, size = CGSize.zero
        guard err == .success, let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return (nil, err == .success ? .failure : err) }
        return (CGRect(origin: origin, size: size), .success)
    }

    /// One attribute: its value, or the AX error that stopped the read (`.cannotComplete` is an app that stopped answering).
    static func attribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &ref)
        return (error == .success ? ref : nil, error)
    }

    /// The one place a window title is cleaned (em dashes out, ends trimmed), so the list and the target name agree.
    static func windowTitle(_ window: AXUIElement) -> String {
        guard let title = attribute(window, kAXTitleAttribute).value as? String else { return "" }
        return title.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        (attribute(window, kAXMinimizedAttribute).value as? Bool) == true
    }
}
