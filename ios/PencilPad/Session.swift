import CryptoKit
import Network
import Observation
import SwiftUI
import UIKit

/// Everything the iPad app knows and does: the Mac connection, the targets, the zoom camera, Show, and the Pencil.
/// It is web/app.js's Mouse mode, written natively; the numbers and the order of things follow the page.
@MainActor
@Observable
final class Session {
    enum Phase: Equatable {
        case needsPairing, choosing, searching, connecting, live, retrying, denied, replaced
    }

    // MARK: What the screen shows

    private(set) var phase: Phase = .searching
    private(set) var found: [FoundMac] = []
    private(set) var macName = ""
    private(set) var screens: [ScreenInfo] = []
    private(set) var target: TargetInfo?
    private(set) var windows: [WindowItem] = []
    private(set) var windowsOpen = false
    private(set) var windowsLoaded = false
    private(set) var pendingChip: String?
    private(set) var rightArmed = false
    private(set) var zoomArmed = false
    private(set) var showOn = false
    private(set) var projLive = false
    private(set) var aim: AimMode = .soft
    private(set) var zoomLevel = 1.0
    private(set) var fps = 0
    private(set) var toast: String?
    private(set) var pencilDown = false
    private(set) var safeTop: CGFloat = 0
    private(set) var pairingNote: String?
    private(set) var searchBlocked = false
    private(set) var pageURL: URL?

    // MARK: Wiring (not shown)

    @ObservationIgnored weak var surface: PencilSurfaceView?
    @ObservationIgnored private let finder = Finder()
    @ObservationIgnored private lazy var frames = FramePipe(session: self)
    @ObservationIgnored private var pairing: Pairing?
    @ObservationIgnored private var wantMac: String?
    @ObservationIgnored private var link: Link?
    @ObservationIgnored private(set) var linkGen = 0
    @ObservationIgnored private var halted: Phase?
    @ObservationIgnored private var retrying = false
    @ObservationIgnored private var retryItem: DispatchWorkItem?
    @ObservationIgnored private var backoff = Tuning.backoffStart
    @ObservationIgnored private var pingTimer: DispatchSourceTimer?
    @ObservationIgnored private var statsTimer: DispatchSourceTimer?
    @ObservationIgnored private var connectStart = 0.0
    @ObservationIgnored private var lastRx = 0.0
    /// When the window list was asked for, until it arrives. The Mac builds it on its main thread, through Accessibility,
    /// and that can take about 3 s, so the silence limit is longer meanwhile.
    @ObservationIgnored private var listAskedAt: Double?
    @ObservationIgnored private var openedAt = 0.0     // when this connection opened
    @ObservationIgnored private var answered = false   // this connection has answered the Mac's challenge
    // The screen stays on while connected, until a Pencil has been idle for Tuning.idleSleep.
    @ObservationIgnored private var lastPencilAt = 0.0
    @ObservationIgnored private var awake = false
    @ObservationIgnored private let idleSleep = Debug.idleSeconds ?? Tuning.idleSleep
    @ObservationIgnored private var ready = false      // the Mac accepted our hello on this connection
    @ObservationIgnored private var active = true      // the app is in the foreground
    @ObservationIgnored private var started = false
    @ObservationIgnored private var toastItem: DispatchWorkItem?

    // Geometry
    @ObservationIgnored private(set) var viewSize = CGSize.zero
    @ObservationIgnored private var insets = UIEdgeInsets.zero
    @ObservationIgnored private(set) var scale: CGFloat = 2
    /// The active area in view points; the Pencil's coordinates are normalized against it.
    @ObservationIgnored private(set) var area = CGRect.zero
    /// The part of the target the active area shows, 0 to 1 of the target.
    @ObservationIgnored private(set) var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @ObservationIgnored private var cam = Camera()
    @ObservationIgnored private var regionQueued = false
    @ObservationIgnored private var regionSent = ""
    @ObservationIgnored private var regionSaved = ""

    // Zoom
    private struct ZoomFrom { var z: Double, cx: Double, cy: Double, mx: Double, my: Double, d: Double }
    @ObservationIgnored private var zoomPtrs: [ObjectIdentifier: CGPoint] = [:]
    @ObservationIgnored private var zoomFrom: ZoomFrom?

    // Show
    @ObservationIgnored private var showKey = ""
    @ObservationIgnored private var drawnAt = 0.0
    @ObservationIgnored private var shown = 0

    // Pencil
    struct Sample {
        var x: CGFloat, y: CGFloat   // view points
        var p: Double                // pressure 0 to 1
        var tx: Double, ty: Double   // tilt in degrees
    }
    @ObservationIgnored private var penActive = false
    @ObservationIgnored private var stroke = false
    @ObservationIgnored private var lastX = 0.0       // last point sent, 0 to 1 of the target
    @ObservationIgnored private var lastY = 0.0
    @ObservationIgnored private var lastSX: CGFloat = 0   // the same on the iPad, for the ink
    @ObservationIgnored private var lastSY: CGFloat = 0
    @ObservationIgnored private var aiming = false
    @ObservationIgnored private var aimX: CGFloat = 0
    @ObservationIgnored private var aimY: CGFloat = 0
    @ObservationIgnored private var aimP = 0.0
    @ObservationIgnored private var aimPending = false
    @ObservationIgnored private var tx = 0.0
    @ObservationIgnored private var ty = 0.0
    /// A Pencil without pressure hardware reports 0 forever and could never cross a threshold, so Aim acts as Off until
    /// this device has shown a Pencil pressure above 0 (remembered).
    @ObservationIgnored private var pressureSeen = false
    @ObservationIgnored private var wireCount = 0

    /// A palm-sized contact or a second finger is down (set when a touch begins): the toolbar press that follows is ignored.
    @ObservationIgnored var palmPress = false

    /// Runs a toolbar or window-list action unless the touch behind it was a palm.
    func press(_ action: () -> Void) {
        guard !palmPress else {
            #if DEBUG
            log.notice("press ignored: palm-sized contact or a second finger")
            #endif
            return
        }
        action()
    }

    var isPenActive: Bool { penActive }
    var isLive: Bool { phase == .live }

    // MARK: Start

    init() {
        let d = UserDefaults.standard
        aim = AimMode(rawValue: d.string(forKey: "pencilpad.aim") ?? "") ?? .soft
        pressureSeen = d.string(forKey: "pencilpad.pressureSeen") == "1"
        pairing = Vault.load()
        pageURL = pairing?.page
        wantMac = d.string(forKey: "pencilpad.lastMac")
        macName = wantMac ?? ""
        if pairing == nil { phase = .needsPairing }
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        log.notice("debug run: fingerAsPencil \(Debug.fingerAsPencil), onlyApp \(Debug.onlyApp ?? "none", privacy: .public), host \(Debug.host ?? "none", privacy: .public)")
        #endif
        finder.onChange = { [weak self] macs in
            self?.found = macs
            self?.ensureConnected()
        }
        finder.onBlocked = { [weak self] why in self?.searchBlocked = why != nil }
        if Debug.host == nil { finder.start() }
        let stats = DispatchSource.makeTimerSource(queue: .main)
        stats.schedule(deadline: .now() + 1, repeating: 1)
        stats.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.second() } }
        stats.resume()
        statsTimer = stats
        ensureConnected()
    }

    private func second() {
        if awake, ProcessInfo.processInfo.systemUptime - lastPencilAt > idleSleep { keepAwake(false) }  // the next Pencil touch re-arms it
        if fps != shown { fps = shown }
        #if DEBUG
        if shown > 0 { log.notice("show: \(self.shown) frames in the last second") }
        #endif
        shown = 0
    }

    private func keepAwake(_ on: Bool) {
        guard awake != on else { return }
        awake = on
        UIApplication.shared.isIdleTimerDisabled = on
        log.notice("screen kept awake: \(on)")
    }

    /// A Pencil touched or hovered: the screen stays on (again) for another idle period.
    private func notePencil() {
        lastPencilAt = ProcessInfo.processInfo.systemUptime
        if ready && active { keepAwake(true) }
    }

    // MARK: Store

    private func stored(_ key: String) -> String? { UserDefaults.standard.string(forKey: "pencilpad." + key) }
    private func store(_ key: String, _ value: String) { UserDefaults.standard.set(value, forKey: "pencilpad." + key) }

    // MARK: Pairing and choosing a Mac

    func pair(with text: String) {
        guard let p = Pairing.parse(text) else {
            pairingNote = "That is not a PencilPad link. On the Mac choose Copy iPad link in the PencilPad menu, then tap Paste again."
            return
        }
        Vault.save(text)
        pairing = p
        pageURL = p.page
        pairingNote = nil
        halted = nil
        showToast("Paired")
        resetConnection()
    }

    /// Asks for a new link (the Mac refused the old one, or the user wants to pair with another Mac).
    func pairAgain() {
        pairingNote = nil
        halted = nil
        pairing = nil  // the old link stays in the Keychain until a new one is pasted, but nothing reconnects with it meanwhile
        retryItem?.cancel()
        retryItem = nil
        dropLink()
        phase = .needsPairing
    }

    func choose(_ mac: FoundMac) {
        wantMac = mac.name
        macName = mac.name
        UserDefaults.standard.set(mac.name, forKey: "pencilpad.lastMac")
        resetConnection()
    }

    private func resetConnection() {
        retryItem?.cancel()
        retryItem = nil
        backoff = Tuning.backoffStart
        retrying = false
        releaseStroke()
        dropLink()
        ensureConnected()
    }

    // MARK: Connection

    /// The one place that decides what to do about the connection.
    private func ensureConnected() {
        guard active, halted == nil else { return }
        guard pairing != nil else { phase = .needsPairing; return }
        guard link == nil, retryItem == nil else { return }  // connecting, live, or waiting out a backoff
        if let host = Debug.host {
            let parts = host.split(separator: ":")
            if parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) {
                macName = "Direct " + host
                connect(to: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port))
            }
            return
        }
        guard let want = wantMac else { phase = .choosing; return }
        guard let mac = found.first(where: { $0.name == want }) else { phase = .searching; return }
        macName = mac.name
        connect(to: mac.endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        releaseStroke()  // sends up while the old connection can still carry it
        dropLink()
        phase = retrying ? .retrying : .connecting
        let gen = linkGen
        let l = Link(endpoint: endpoint)
        link = l
        connectStart = ProcessInfo.processInfo.systemUptime
        lastRx = connectStart
        answered = false
        l.onEvent = { [weak self] event in self?.linkEvent(event, gen: gen) }
        l.start()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Tuning.pingEvery, repeating: Tuning.pingEvery)
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick(gen) } }
        t.resume()
        pingTimer = t
        log.notice("connecting to \(String(describing: endpoint), privacy: .public)")
    }

    private func linkEvent(_ event: Link.Event, gen: Int) {
        guard gen == linkGen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .open:
            lastRx = now
            openedAt = now  // the Mac speaks first: its challenge comes next, and only a proof of the token goes back
        case .text(let text):
            lastRx = now
            handle(text)
        case .binary(let data):
            lastRx = now
            frames.push(data, gen: gen)
        case .closed(let why):
            retry(why)
        }
    }

    /// Ping every 500 ms; a Mac silent for 3 s while connected, or a connection that never opened, is dropped and retried.
    private func tick(_ gen: Int) {
        guard gen == linkGen, let l = link else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard l.isOpen else {
            if now - connectStart > Tuning.connectLimit { retry("did not open in \(Int(Tuning.connectLimit)) s") }
            return
        }
        if !ready, now - openedAt > Tuning.helloLimit {
            retry("the Mac sent no challenge (an older PencilPad?)")
            return
        }
        var limit = Tuning.deadAfter
        if let asked = listAskedAt {
            if now - asked > Tuning.listLimit { listAskedAt = nil } else { limit = Tuning.listLimit }
        }
        if now - lastRx > limit {
            retry("no frame for \(Int(limit)) s")
            return
        }
        if answered { l.send(#"{"t":"ping"}"#) }  // the Mac takes a hello as the first frame; nothing goes ahead of it
    }

    private func retry(_ why: String) {
        log.notice("retry: \(why, privacy: .public)")
        releaseStroke()
        dropLink()
        guard halted == nil, active, pairing != nil else { return }
        retrying = true
        phase = .retrying
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.retryItem = nil
                self?.ensureConnected()
            }
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(backoff) / 1000, execute: item)
        backoff = min(Tuning.backoffCap, Int((Double(backoff) * 1.7).rounded()))
    }

    private func dropLink() {
        pingTimer?.cancel()
        pingTimer = nil
        link?.close()
        link = nil
        linkGen += 1  // anything still in flight for the old connection is dropped
        ready = false
        macLost()
        keepAwake(false)
    }

    /// The Mac is no longer there: nothing it said still holds.
    private func macLost() {
        listAskedAt = nil
        windowsOpen = false
        windows = []
        pendingChip = nil
        projLive = false
        showKey = ""
        regionSent = ""
        fps = 0
        shown = 0
        surface?.clearProjection()
    }

    /// Denied (wrong link) and replaced (another page took over) both stop retrying.
    private func halt(_ kind: Phase) {
        halted = kind
        ready = false
        releaseStroke()
        retryItem?.cancel()
        retryItem = nil
        dropLink()
        phase = kind
        if kind == .denied { pairingNote = "The Mac did not accept that link. Choose Copy iPad link in the PencilPad menu on the Mac, then paste it here." }
    }

    /// Replaced: tap to take the Mac back. The newest one wins.
    func takeOver() {
        halted = nil
        resetConnection()
    }

    func sceneChanged(_ phase: ScenePhase) {
        let now = phase == .active
        guard now != active else {
            if phase == .background { backgrounded() }
            return
        }
        active = now
        releaseStroke()
        if now {
            finder.start()
            backoff = Tuning.backoffStart
            if ready { notePencil() }
            ensureConnected()
        } else {
            armZoom(false)
        }
        syncShow()
        if phase == .background { backgrounded() }
    }

    /// In the background the connection is closed on purpose: the Mac lets go of any held button at once, and the page
    /// (or another iPad) can take over without a "replaced".
    private func backgrounded() {
        releaseStroke()
        retryItem?.cancel()
        retryItem = nil
        dropLink()
        if Debug.host == nil { finder.stop() }
    }

    // MARK: Messages from the Mac

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = m["t"] as? String else { return }
        switch t {
        case "challenge":
            answerChallenge(m["nonce"] as? String)
        case "hello":
            ready = true
            retrying = false
            backoff = Tuning.backoffStart
            regionSent = ""
            showKey = ""
            screens = Self.parseScreens(m["screens"])
            phase = .live
            notePencil()  // a fresh idle period starts when the connection does
            if !macName.isEmpty, Debug.host == nil { UserDefaults.standard.set(macName, forKey: "pencilpad.lastMac") }
            setTarget(Self.parseTarget(m["target"]) ?? screens.first(where: \.main).map { TargetInfo(id: $0.id, name: $0.name, w: $0.w, h: $0.h, app: nil) })
        case "screens":
            screens = Self.parseScreens(m["screens"])
        case "target":
            setTarget(Self.parseTarget(m["target"]))
        case "windows":
            showWindows(m["list"])
        case "show":
            onShow(m)
        case "denied":
            halt(.denied)
        case "replaced":
            halt(.replaced)
        default:
            break  // pong, and Board messages (Board stays in the web page)
        }
    }

    /// The Mac's challenge: HMAC-SHA256 with the token's UTF-8 bytes as the key and the nonce as the message. The token itself
    /// is never sent, so a Mac that is not the real one (a look-alike on the direct link) learns nothing it can use.
    private func answerChallenge(_ nonce: String?) {
        guard !answered, !ready, let token = pairing?.token,
              let bytes = nonce.flatMap({ Data(base64Encoded: $0) }), bytes.count >= 16 else { return }
        answered = true  // one hello per connection
        let proof = HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(token.utf8)))
        send(#"{"t":"hello","proof":"\#(Data(proof).base64EncodedString())"}"#)
    }

    private static func parseScreens(_ any: Any?) -> [ScreenInfo] {
        ((any as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return ScreenInfo(id: id, name: d["name"] as? String ?? "", w: (d["w"] as? NSNumber)?.doubleValue ?? 0,
                              h: (d["h"] as? NSNumber)?.doubleValue ?? 0, main: d["main"] as? Bool ?? false)
        }
    }

    private static func parseTarget(_ any: Any?) -> TargetInfo? {
        guard let d = any as? [String: Any], let id = d["id"] as? String else { return nil }
        return TargetInfo(id: id, name: d["name"] as? String ?? "", w: (d["w"] as? NSNumber)?.doubleValue ?? 0,
                          h: (d["h"] as? NSNumber)?.doubleValue ?? 0, app: d["app"] as? String)
    }

    // MARK: Targets

    var activeTargetID: String? {
        guard let target else { return nil }
        return screens.contains(where: { $0.id == target.id }) ? target.id : "window"
    }

    var chips: [ChipItem] {
        var seen: [String: Int] = [:]
        var out: [ChipItem] = []
        let active = activeTargetID
        func add(_ label: String, _ id: String, _ hint: String) {
            seen[label, default: 0] += 1
            let n = seen[label]!
            let isWindow = id == "window"
            let shownLabel = isWindow && active == "window" ? (target?.app ?? "Window") : (n > 1 ? "\(label) \(n)" : label)
            out.append(ChipItem(id: id, label: shownLabel, active: id == active, pending: pendingChip == id && id != active, isWindow: isWindow, hint: hint))
        }
        for s in screens { add(s.short, s.id, "\(s.name) \(Int(s.w)) by \(Int(s.h))") }
        add("Window", "window", "The Mac's front window")
        return out
    }

    private func setTarget(_ t: TargetInfo?) {
        guard let t else { return }
        let changed = target == nil || target!.regionKey != t.regionKey
        let kindChanged = target == nil || target!.kind != t.kind
        target = t
        pendingChip = nil
        if t.w > 0 && t.h > 0 { store("aspect", String(t.w / t.h)) }
        if changed {
            loadRegion(t)
            regionSent = ""  // that target's own zoom, and the Mac hears it once
        }
        if kindChanged {
            showOn = showPref(t.kind)  // a window starts showing by itself
            if !showOn { clearProj() }
        }
        if activeTargetID != "window" { closeWindows() }
        fit()
    }

    func tapChip(_ id: String) {
        guard ready else { return }
        if id == "window", activeTargetID == "window" {
            toggleWindows()  // second tap: which window?
            return
        }
        closeWindows()
        send(#"{"t":"target","id":\#(jsonString(id))}"#)
        if id != activeTargetID { pendingChip = id }
    }

    func toggleWindows() {
        if windowsOpen {
            closeWindows()
            return
        }
        windowsOpen = true
        windowsLoaded = false
        windows = []
        listAskedAt = ProcessInfo.processInfo.systemUptime
        send(#"{"t":"windows"}"#)
    }

    func closeWindows() {
        guard windowsOpen else { return }
        windowsOpen = false
        windows = []
    }

    private func showWindows(_ any: Any?) {
        listAskedAt = nil
        guard windowsOpen else { return }  // closed before the Mac answered
        windowsLoaded = true
        windows = ((any as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = (d["id"] as? NSNumber)?.intValue else { return nil }
            return WindowItem(id: id, app: d["app"] as? String ?? "", title: d["title"] as? String ?? "",
                              w: (d["w"] as? NSNumber)?.intValue ?? 0, h: (d["h"] as? NSNumber)?.intValue ?? 0,
                              current: d["current"] as? Bool ?? false)
        }
    }

    func pick(window id: Int) {
        guard ready else { return }
        send(#"{"t":"target","id":"window","pick":\#(id)}"#)
        pendingChip = "window"  // until the Mac answers with the target
        closeWindows()
    }

    // MARK: Layout, zoom and the region

    /// What is left of the screen below the toolbar, inside the margins and safe areas.
    private func drawRect() -> (left: CGFloat, top: CGFloat, aw: CGFloat, ah: CGFloat) {
        let barBottom = max(insets.top, 0) + Tuning.barInset + Tuning.barHeight
        let top = max(barBottom, insets.top) + Tuning.gap
        let left = insets.left + Tuning.pad
        let right = viewSize.width - insets.right - Tuning.pad
        let bottom = viewSize.height - insets.bottom - Tuning.pad
        return (left, top, max(1, right - left), max(1, bottom - top))
    }

    func layout(size: CGSize, insets: UIEdgeInsets, scale: CGFloat) {
        let top = max(insets.top, 0)
        if safeTop != top { safeTop = top }
        guard size != viewSize || insets != self.insets || scale != self.scale else { return }
        viewSize = size
        self.insets = insets
        self.scale = scale
        fit()
    }

    private func cachedAspect() -> Double {
        let a = Double(stored("aspect") ?? "") ?? 0
        return a > 0 ? a : 16.0 / 10.0
    }

    private func fit() {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let r = drawRect()
        let tw = (target?.w ?? 0) > 0 ? target!.w : cachedAspect()
        let th = (target?.h ?? 0) > 0 ? target!.h : 1
        let v = cam.clamp(aw: Double(r.aw), ah: Double(r.ah), tw: tw, th: th)
        let rx = max(0, cam.cx - v.cw / 2), ry = max(0, cam.cy - v.ch / 2)
        let rw = min(1, v.cw), rh = min(1, v.ch)
        region = CGRect(x: rx, y: ry, width: rw, height: rh)
        let w = rw * v.tw * v.s, h = rh * v.th * v.s
        let ax = Double(r.left) + Double(r.aw) / 2 + (rx - cam.cx) * v.tw * v.s
        let ay = Double(r.top) + Double(r.ah) / 2 + (ry - cam.cy) * v.th * v.s
        area = CGRect(x: ax, y: ay, width: w, height: h)
        if zoomLevel != cam.z { zoomLevel = cam.z }
        surface?.areaChanged()
        queueRegion()
    }

    /// That target's saved region becomes the camera (the whole target when there is none).
    private func loadRegion(_ t: TargetInfo) {
        cam = Camera()
        let raw = stored("region." + t.regionKey) ?? ""
        regionSaved = t.regionKey + "=" + raw
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && $0!.isFinite }) else { return }
        let x = parts[0]!, y = parts[1]!, w = parts[2]!, h = parts[3]!
        let r = drawRect()
        let tw = t.w > 0 ? t.w : 1, th = t.h > 0 ? t.h : 1
        let base = min(Double(r.aw) / tw, Double(r.ah) / th)
        // A region that spans the whole of one axis says nothing about the camera on it; the other axis does.
        if w > 0 && w < 0.999 { cam.z = (Double(r.aw) / (base * tw)) / w }
        else if h > 0 && h < 0.999 { cam.z = (Double(r.ah) / (base * th)) / h }
        cam.cx = x + w / 2
        cam.cy = y + h / 2
    }

    /// One region message per turn of the run loop, and only when it changed.
    private func queueRegion() {
        guard !regionQueued else { return }
        regionQueued = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.flushRegion() } }
    }

    private func flushRegion() {
        regionQueued = false
        guard let target else { syncShow(); return }
        let v = [region.minX, region.minY, region.width, region.height].map { r5(Double($0)) }
        let s = v.map { String($0) }.joined(separator: ",")
        let saved = target.regionKey + "=" + s
        if saved != regionSaved && zoomPtrs.isEmpty {  // once, when the fingers lift
            regionSaved = saved
            store("region." + target.regionKey, s)
        }
        if ready && s != regionSent {
            regionSent = s
            send(#"{"t":"region","x":\#(v[0]),"y":\#(v[1]),"w":\#(v[2]),"h":\#(v[3])}"#)
        }
        syncShow()
    }

    // Zoom: tapping Zoom arms ONE finger gesture on the drawing surface (fingers otherwise only press buttons): two fingers
    // pinch around their midpoint and drag, one finger drags. When the fingers lift the gesture ends and Zoom disarms.

    func toggleZoom() {
        armZoom(!zoomArmed)
        if zoomArmed { showToast("Pinch or drag on the screen to zoom") }
    }

    func armZoom(_ on: Bool) {
        zoomArmed = on
        if !on {
            zoomPtrs.removeAll()
            zoomFrom = nil
        }
    }

    func resetZoom() {
        armZoom(false)
        cam = Camera()
        fit()
    }

    private func zoomRebase() {
        let f = Fingers(Array(zoomPtrs.values))
        zoomFrom = ZoomFrom(z: cam.z, cx: cam.cx, cy: cam.cy, mx: f.mx, my: f.my, d: f.d)
    }

    func zoomBegan(_ id: ObjectIdentifier, at p: CGPoint) -> Bool {
        guard zoomArmed, !penActive, zoomPtrs.count < 2 else { return false }
        zoomPtrs[id] = p
        zoomRebase()
        return true
    }

    /// The target point that was under the fingers' midpoint when the gesture began stays under it.
    func zoomMoved(_ id: ObjectIdentifier, to p: CGPoint) {
        guard zoomPtrs[id] != nil else { return }
        zoomPtrs[id] = p
        guard let from = zoomFrom else { return }
        let f = Fingers(Array(zoomPtrs.values))
        let r = drawRect()
        let tw = (target?.w ?? 0) > 0 ? target!.w : cachedAspect()
        let th = (target?.h ?? 0) > 0 ? target!.h : 1
        let v = cam.clamp(aw: Double(r.aw), ah: Double(r.ah), tw: tw, th: th)
        let z = min(max(from.z * (from.d > 0 && f.d > 0 ? f.d / from.d : 1), 1), v.zMax)
        let s0 = from.z * v.base, s1 = z * v.base
        let mx = Double(r.left) + Double(r.aw) / 2, my = Double(r.top) + Double(r.ah) / 2
        let ux = from.cx + (from.mx - mx) / (v.tw * s0), uy = from.cy + (from.my - my) / (v.th * s0)
        cam.z = z
        cam.cx = ux - (f.mx - mx) / (v.tw * s1)
        cam.cy = uy - (f.my - my) / (v.th * s1)
        fit()
    }

    func zoomEnded(_ id: ObjectIdentifier) {
        guard zoomPtrs.removeValue(forKey: id) != nil else { return }
        if !zoomPtrs.isEmpty {
            zoomRebase()
            return
        }
        armZoom(false)  // the fingers are up: the gesture is over
        fit()
    }

    // MARK: Show (projection)

    private func showPref(_ kind: String) -> Bool {
        let v = stored("show." + kind)
        return v == nil ? kind == "window" : v == "1"  // windows start on, screens off until tapped
    }

    func toggleShow() { setShow(!showOn, remember: true) }

    private func setShow(_ on: Bool, remember: Bool) {
        showOn = on
        if remember, let target { store("show." + target.kind, on ? "1" : "0") }
        if !on { clearProj() }
        syncShow()
    }

    /// The active area in device pixels, longest side capped.
    private func projSize() -> (Int, Int) {
        let k = min(1, Tuning.projMax / max(area.width * scale, area.height * scale, 1))
        return (max(1, Int((area.width * scale * k).rounded())), max(1, Int((area.height * scale * k).rounded())))
    }

    /// Tells the Mac to start, resize or stop: on a resize, a target change or a region change, once each. An app that is
    /// not in the foreground gets no picture.
    private func syncShow() {
        let want = showOn && ready && target != nil && active && area.width > 0 && inputAllowed
        var key = "off"
        if want, let t = target {
            let (w, h) = projSize()
            key = "\(w)x\(h) \(t.regionKey) \(t.w)x\(t.h) \(region.minX),\(region.minY),\(region.width),\(region.height)"
        }
        if key == showKey || (key == "off" && showKey == "") { return }
        showKey = key
        if want {
            let (w, h) = projSize()
            send(#"{"t":"show","on":true,"w":\#(w),"h":\#(h)}"#)
        } else {
            send(#"{"t":"show","on":false}"#)
        }
    }

    private func clearProj() {
        surface?.clearProjection()
        projLive = false
        shown = 0
        fps = 0
    }

    /// The Mac's answer: frames are coming, or why not (the stream is already stopped).
    private func onShow(_ m: [String: Any]) {
        if m["ok"] as? Bool == true {
            projLive = true
            return
        }
        showOn = false
        showKey = "off"
        clearProj()
        showToast((m["why"] as? String) ?? "The Mac could not show it")
    }

    // Frames come from FramePipe, which decodes off the main thread and asks these three.

    /// While the Pencil is down a picture is shown at most every 100 ms, and its ack waits with it: the Mac's two-frame
    /// limit holds it back, so the rate falls by itself, and returns to full the moment the Pencil lifts.
    func holdBeforeDrawing() -> Double {
        guard penActive else { return 0 }
        return max(0, Tuning.projPenSeconds - (ProcessInfo.processInfo.systemUptime - drawnAt))
    }

    func wantsFrame(_ gen: Int) -> Bool { gen == linkGen && showOn && ready && active }

    func present(_ image: UIImage?, n: UInt32, gen: Int) {
        guard gen == linkGen else { return }
        if let image, let cg = image.cgImage, wantsFrame(gen) {
            surface?.display(cg)
            drawnAt = ProcessInfo.processInfo.systemUptime
            shown += 1
        }
        send(#"{"t":"frame","ack":\#(n)}"#)  // the Mac holds the next frames back until it hears this, always
    }

    // MARK: Buttons

    func sendKey(_ name: String) {
        guard ready, inputAllowed else { return }
        send(#"{"t":"key","name":"\#(name)"}"#)
    }

    func toggleRight() { setRight(!rightArmed) }

    private func setRight(_ on: Bool) { if rightArmed != on { rightArmed = on } }

    /// Pencil double-tap or squeeze: the next touch right-clicks.
    func armRightFromPencil() {
        setRight(true)
        showToast("Right-click armed")
    }

    func cycleAim() {
        aim = aim.next
        store("aim", aim.rawValue)
    }

    var aimNote: String {
        if aim == .off { return "Every touch clicks" }
        return pressureSeen ? "A light touch aims, press to click" : "Waiting for Pencil pressure"
    }

    func showToast(_ text: String) {
        toast = text
        toastItem?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.toast = nil } }
        toastItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: item)
    }

    func openBoard() {
        guard let pageURL else { return }
        UIApplication.shared.open(pageURL)
    }

    private func setPencilDown(_ on: Bool) { if pencilDown != on { pencilDown = on } }

    // MARK: Pencil (the page's onDown, contactPoint, movePoint and onUp)

    private var aimAt: Double { pressureSeen ? aim.threshold : 0 }

    /// Nothing that moves, clicks or types on the Mac leaves the iPad, and nothing is projected, in a test run unless the
    /// Mac's target is the scratch window the run is allowed to touch (debug builds with -debugOnlyApp only).
    private var inputAllowed: Bool {
        #if DEBUG
        if let only = Debug.onlyApp { return target?.id == "window" && target?.app == only }
        if Debug.fingerAsPencil { return false }  // a test run that did not say which window it may touch touches none
        #endif
        return true
    }

    private func notePressure(_ p: Double) {
        guard !pressureSeen, p > 0 else { return }
        pressureSeen = true
        store("pressureSeen", "1")
    }

    private func normX(_ x: CGFloat) -> Double { r5(clamp01(Double((x - area.minX) / area.width))) }
    private func normY(_ y: CGFloat) -> Double { r5(clamp01(Double((y - area.minY) / area.height))) }
    private func toTargetX(_ n: Double) -> Double { r5(clamp01(Double(region.minX) + n * Double(region.width))) }
    private func toTargetY(_ n: Double) -> Double { r5(clamp01(Double(region.minY) + n * Double(region.height))) }
    private func inArea(_ x: CGFloat, _ y: CGFloat) -> Bool { x >= area.minX && x <= area.maxX && y >= area.minY && y <= area.maxY }
    private func onScreen(_ n: (Double, Double)) -> CGPoint {
        CGPoint(x: area.minX + CGFloat(n.0) * area.width, y: area.minY + CGFloat(n.1) * area.height)
    }

    /// The Pencil touched down. False: the touch is not the Pencil's to use (outside the area, a zoom in progress, or it
    /// only closed the window list).
    func penDown(_ s: Sample) -> Bool {
        if windowsOpen {  // a Pencil down that only dismisses the list never clicks on the Mac
            closeWindows()
            return false
        }
        guard !penActive, zoomPtrs.isEmpty, inArea(s.x, s.y) else { return false }
        notePencil()
        penActive = true
        setPencilDown(true)
        notePressure(s.p)
        tx = s.tx
        ty = s.ty
        if s.p >= aimAt {
            pressAt(s)
        } else {
            aiming = true
            aimX = s.x
            aimY = s.y
            aimP = s.p
            aimPending = true
            flushAim()
        }
        return true
    }

    func penMoved(_ samples: [Sample]) {
        guard penActive else { return }
        notePencil()
        for s in samples { contactPoint(s) }
        flushAim()
        surface?.inkFlush()  // the trail's path is set once per touch event, not once per coalesced sample
    }

    private func contactPoint(_ s: Sample) {
        if aiming {
            tx = s.tx
            ty = s.ty
            if s.p >= aimAt && inArea(s.x, s.y) {  // clicks start inside the area
                pressAt(s)
                return
            }
            aimX = s.x
            aimY = s.y
            aimP = s.p
            aimPending = true
            return
        }
        movePoint(s)
    }

    /// The tip crossed the threshold (or Aim is off): click here with the real pressure.
    private func pressAt(_ s: Sample) {
        let X = normX(s.x), Y = normY(s.y)
        aiming = false
        aimPending = false
        let right = rightArmed
        if ready { sendDown(toTargetX(X), toTargetY(Y), s.p) }
        let at = onScreen((X, Y))
        lastSX = at.x
        lastSY = at.y
        surface?.hideReticle()
        surface?.inkBegin(at: at, right: right)
    }

    private func sendDown(_ X: Double, _ Y: Double, _ p: Double) {
        guard inputAllowed else { return }
        let b = rightArmed ? "right" : "left"
        send(#"{"t":"down","x":\#(X),"y":\#(Y),"p":\#(p),"tx":\#(tx),"ty":\#(ty),"b":"\#(b)"}"#)
        stroke = true
        lastX = X
        lastY = Y
        if rightArmed { setRight(false) }  // only a real down uses up the right-click
    }

    private func movePoint(_ s: Sample) {
        let X = normX(s.x), Y = normY(s.y)
        notePressure(s.p)
        tx = s.tx
        ty = s.ty
        if stroke {
            lastX = toTargetX(X)
            lastY = toTargetY(Y)
            send(#"{"t":"move","x":\#(lastX),"y":\#(lastY),"p":\#(s.p),"tx":\#(tx),"ty":\#(ty)}"#)
        }
        let at = onScreen((X, Y))
        lastSX = at.x
        lastSY = at.y
        surface?.inkAppend(to: at)
    }

    /// Below the threshold: the cursor follows, one hover per event.
    private func flushAim() {
        guard aimPending else { return }
        aimPending = false
        let X = normX(aimX), Y = normY(aimY)
        if ready && inArea(aimX, aimY) && inputAllowed {  // outside the area only the reticle follows
            send(#"{"t":"hover","x":\#(toTargetX(X)),"y":\#(toTargetY(Y))}"#)
        }
        let at = onScreen((X, Y))
        surface?.reticle(at: at, progress: aimAt > 0 ? min(1, aimP / aimAt) : 1)
    }

    /// The Pencil lifted at `s`. An aim-only touch sends nothing on lift.
    func penUp(_ s: Sample) {
        guard penActive else { return }
        lastX = toTargetX(normX(s.x))
        lastY = toTargetY(normY(s.y))
        if stroke { send(#"{"t":"up","x":\#(lastX),"y":\#(lastY)}"#) }
        endPen()
    }

    /// Closes any open stroke: cancelled touch, app inactive, socket teardown. Safe to call at any time.
    func releaseStroke() {
        if stroke { send(#"{"t":"up","x":\#(lastX),"y":\#(lastY)}"#) }
        if penActive { endPen() }
        stroke = false
    }

    private func endPen() {
        stroke = false
        penActive = false
        aiming = false
        aimPending = false
        surface?.inkEnd()
        surface?.hideReticle()
        setPencilDown(false)
    }

    /// Hardware hover: the Pencil above the glass moves the cursor.
    func hover(_ x: CGFloat, _ y: CGFloat) {
        guard !penActive, ready, zoomPtrs.isEmpty, inArea(x, y), inputAllowed else { return }
        notePencil()
        let X = normX(x), Y = normY(y)
        send(#"{"t":"hover","x":\#(toTargetX(X)),"y":\#(toTargetY(Y))}"#)
        surface?.reticle(at: onScreen((X, Y)), progress: 0)
    }

    func hoverLeft() {
        guard !penActive else { return }
        surface?.hideReticle()
    }

    // MARK: Sending

    private func send(_ text: String) {
        #if DEBUG
        logWire(text)
        #endif
        link?.send(text)
    }

    #if DEBUG
    private func logWire(_ text: String) {
        if text.contains(#""t":"ping""#) || text.contains(#""t":"frame""#) || text.contains(#""t":"hello""#) { return }  // never the token
        if text.contains(#""t":"move""#) || text.contains(#""t":"hover""#) {
            wireCount += 1
            if wireCount % 25 != 1 { return }
        }
        wire.notice("-> \(text, privacy: .public)")
    }
    #endif

    private func jsonString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let out = String(data: data, encoding: .utf8) else { return "\"\"" }
        return out
    }
}
