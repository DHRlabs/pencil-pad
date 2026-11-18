import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit
@preconcurrency import ScreenCaptureKit

/// A transparent, click-through window that lies exactly over the window target and only shows the marks.
private final class AnnotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Never nudged back under the menu bar or onto another screen: it sits exactly where the window is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A finished image carried to a detached task.
private struct ImageBox: @unchecked Sendable { let image: CGImage }

/// The marks themselves, kept compactly: a flat run of Floats (x, y, pressure) per mark, never the messages they came in.
/// Every rule about which messages count lives here, so a live stroke, a staged replay and a rebuild all agree: a begin
/// for an id already kept is dropped (not merged), points and ends for a mark that is not open are dropped, and the
/// count is of unique marks.
private struct MarkStore: Sendable {
    struct Mark: Sendable {
        var color: String
        var size: Double
        var pts: [Float]  // x, y, p, x, y, p, ...
        var open: Bool
    }

    /// What the Mac will hold: past this a begin or more points are refused (about 5 MB of points).
    static let maxPoints = 400_000
    static let maxMarks = 5_000
    /// The page splits at 1000 points; a frame is under 60 KB.
    static let maxPerMessage = 2_000
    /// Points in one op of a rebuild.
    static let chunk = 512

    private(set) var marks: [Int: Mark] = [:]
    private(set) var order: [Int] = []
    private var points = 0

    var count: Int { order.count }

    /// Applies one begin, pts or end. Returns the op to show in the overlay (as accepted), or nil when it was dropped.
    mutating func apply(_ msg: [String: Any]) -> [String: Any]? {
        guard let op = msg["op"] as? String, let id = Self.id(msg["id"]) else { return nil }
        switch op {
        case "begin":
            guard marks[id] == nil, order.count < Self.maxMarks, points < Self.maxPoints else { return nil }
            let color = Self.color(msg["color"])
            let size = min(0.05, max(0.0005, Self.num(msg["size"]) ?? 0.0065))
            let pts = Self.points(msg["pts"], room: Self.maxPoints - points)
            marks[id] = Mark(color: color, size: size, pts: pts, open: true)
            order.append(id)
            points += pts.count / 3
            return ["op": "begin", "id": id, "tool": "pen", "color": color, "size": size, "pts": Self.json(pts)]
        case "pts":
            guard var mark = marks[id], mark.open, points < Self.maxPoints else { return nil }
            let pts = Self.points(msg["pts"], room: Self.maxPoints - points)
            guard !pts.isEmpty else { return nil }
            mark.pts += pts
            marks[id] = mark
            points += pts.count / 3
            return ["op": "pts", "id": id, "pts": Self.json(pts)]
        case "end":
            guard var mark = marks[id], mark.open else { return nil }
            mark.open = false
            marks[id] = mark
            return ["op": "end", "id": id]
        default:
            return nil
        }
    }

    /// Every open mark is finished (a replay ends them all).
    mutating func closeAll() {
        for id in order where marks[id]?.open == true { marks[id]?.open = false }
    }

    /// The ops that rebuild exactly these marks in an empty overlay page.
    func ops() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for id in order {
            guard let mark = marks[id] else { continue }
            let step = Self.chunk * 3
            var i = 0
            repeat {
                let part = Array(mark.pts[i..<min(i + step, mark.pts.count)])
                if i == 0 {
                    out.append(["op": "begin", "id": id, "tool": "pen", "color": mark.color, "size": mark.size, "pts": Self.json(part)])
                } else {
                    out.append(["op": "pts", "id": id, "pts": Self.json(part)])
                }
                i += step
            } while i < mark.pts.count
            if !mark.open { out.append(["op": "end", "id": id]) }
        }
        return out
    }

    /// The marks as plain values for a page that draws them once (Save): flat points, one entry per mark.
    func snapshot() -> [[String: Any]] {
        order.compactMap { id in
            marks[id].map { ["id": id, "color": $0.color, "size": $0.size, "flat": $0.pts.map(Double.init)] }
        }
    }

    // MARK: Parsing

    private static func num(_ any: Any?) -> Double? {
        guard let value = (any as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    private static func id(_ any: Any?) -> Int? {
        guard let value = num(any), abs(value) < 1e9, value == value.rounded() else { return nil }
        return Int(value)
    }

    private static func color(_ any: Any?) -> String {
        guard let s = any as? String, s.count == 7, s.hasPrefix("#"), s.dropFirst().allSatisfy(\.isHexDigit) else { return "#ff453a" }
        return s.lowercased()
    }

    private static func points(_ any: Any?, room: Int) -> [Float] {
        guard let list = any as? [Any] else { return [] }
        var out: [Float] = []
        out.reserveCapacity(min(list.count, min(maxPerMessage, room)) * 3)
        for item in list.prefix(min(maxPerMessage, max(0, room))) {
            guard let p = item as? [Any], let x = num(p.first), p.count > 1, let y = num(p[1]) else { continue }
            let pressure = p.count > 2 ? (num(p[2]) ?? 0.5) : 0.5
            out.append(Float(min(max(x, 0), 1)))
            out.append(Float(min(max(y, 0), 1)))
            out.append(Float(min(max(pressure, 0), 1)))
        }
        return out
    }

    private static func json(_ flat: [Float]) -> [[Double]] {
        stride(from: 0, to: flat.count - 2, by: 3).map { [Double(flat[$0]), Double(flat[$0 + 1]), Double(flat[$0 + 2])] }
    }
}

/// Where the target window is on screen, as the window server reports it (no Accessibility call, so a hung app cannot
/// stall it), and where the overlay stands relative to it.
private enum Presence: Equatable, Sendable {
    /// On screen at `frame` (global top-left points) on window layer `layer`; `above`: the overlay is directly over it.
    case onScreen(frame: CGRect, layer: Int, above: Bool)
    /// Not on screen now: minimized, its app hidden, on another Space.
    case hidden
    /// The window server no longer has it.
    case gone
}

/// Reads the target window's place from the window server on its own queue, only while marks are up, and says so on
/// the main actor when it changes. Fast while things move, slow once they have been still for a couple of seconds.
private final class PresenceReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pencilpad.annot.presence", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var window = CGWindowID(0), panel = 0
    private var last: Presence?
    private var still = 0, goneRuns = 0, slow = false
    private let report: @Sendable (Presence) -> Void

    init(report: @escaping @Sendable (Presence) -> Void) { self.report = report }

    func start(window: CGWindowID) {
        lock.lock(); self.window = window; panel = 0; last = nil; still = 0; goneRuns = 0; slow = false; lock.unlock()
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func setPanel(_ number: Int) { lock.lock(); panel = number; lock.unlock() }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        lock.lock(); let window = window, panel = panel; lock.unlock()
        var now = Self.read(window: window, panel: panel)
        if now == .gone {  // told only once it has stayed gone a few reads
            goneRuns += 1
            if goneRuns < 3 { now = .hidden }
        } else { goneRuns = 0 }
        if now == last {
            still += 1
            if still >= 50, !slow { slow = true; timer?.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(30)) }
            // A panel that is not where it should be is told again until it is.
            if case .onScreen(_, _, false) = now {} else { return }
        } else {
            still = 0
            if slow { slow = false; timer?.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(5)) }
        }
        last = now
        report(now)
    }

    private static func read(window: CGWindowID, panel: Int) -> Presence {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var target: Int?, over: Int?
        for (i, e) in list.enumerated() {
            let n = (e[kCGWindowNumber as String] as? NSNumber)?.intValue
            if n == Int(window) { target = i } else if n == panel, panel > 0 { over = i }
        }
        guard let target else {
            let own = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]] ?? []
            return own.isEmpty ? .gone : .hidden
        }
        let entry = list[target]
        guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return .hidden }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        // Directly over the window: the overlay is in front of it with nothing but PencilPad's own windows between.
        var above = false
        if let over, over < target {
            above = list[(over + 1)..<target].allSatisfy { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == me }
        }
        return .onScreen(frame: frame, layer: layer, above: above)
    }
}

/// Reads the page `annot.html` in a web view that is never shown, to draw a set of marks once.
@MainActor
private final class InkExporter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let view: WKWebView

    init?(pageURL: URL) {
        guard let root = HTTPServer.webRoot() else { return nil }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BoardPages(root: root), forURLScheme: BoardPages.scheme)
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: config)
        super.init()
        view.navigationDelegate = self
        view.load(URLRequest(url: pageURL))
    }

    /// The marks alone, transparent, as a PNG data URL `width` x `height` pixels; nil when the page did not come up or draw.
    func png(of strokes: [[String: Any]], width: Int, height: Int) async -> String? {
        let up = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuation = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finish(false)
            }
        }
        guard up else { return nil }
        do {
            let result = try await view.callAsyncJavaScript("PencilAnnot.loadStrokes(list); return PencilAnnot.png(w, h)",
                                                            arguments: ["list": strokes, "w": width, "h": height], in: nil, contentWorld: .page)
            return result as? String
        } catch {
            log.error("annotate: export page failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}

/// Mouse mode's Annotate: the Pencil's marks over the target window. The iPad owns what it draws and sends every op;
/// this keeps them (so a page that loads late, or again, gets all of them), shows them in an overlay window drawn by
/// the same board-core.js, and saves the window's picture with the marks on top. Unlike the region outline the overlay
/// is NOT kept out of shares and captures: it is there so the room sees the marks.
///
/// The overlay exists only while marks do (the web view is released on Clear), sits directly above the target window
/// in the window order (so a window in front of the target covers the ink too), disappears with a hidden, minimized or
/// other-Space target, and follows the window by what the window server reports, whoever is connected.
@MainActor
final class Annotation: NSObject {
    /// A target choice took the marks away (the page clears its copy too).
    var onReset: (() -> Void)?
    /// The target window is gone from the window server: the caller should ask the app (a read the Accessibility API confirms).
    var onTargetGone: (() -> Void)?

    /// Marks on show: unique strokes begun since the last clear.
    var strokes: Int { store.count }

    private let targets: Targets
    private var store = MarkStore()
    /// A replay on its way (one connection's, for one generation); swapped in whole by `commit`, dropped if the connection ends.
    private var staged: (client: Int, gen: Int, store: MarkStore)?
    private var panel: AnnotPanel?
    private var webView: WKWebView?
    private var loaded = false
    /// Ops waiting to be applied, sent in batches so the page sees them in arrival order.
    private var pending: [[String: Any]] = []
    private var draining = false
    private var failures = 0
    /// The window the marks are over (the window server's number), fixed when they began.
    private var markedWindow: CGWindowID?
    private lazy var reader = PresenceReader { [weak self] presence in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(presence) } }
    }

    private static let pageURL = URL(string: "\(BoardPages.scheme)://board/annot.html")!
    /// More than this waiting and the queue is replaced by a rebuild from the compact marks.
    private static let maxPending = 2_000

    init(targets: Targets) {
        self.targets = targets
        super.init()
    }

    // MARK: Ops from the iPad

    /// begin, pts or end (the caller has checked the generation): kept, and drawn in the overlay. Only a window target can be marked.
    func apply(_ msg: [String: Any]) {
        guard targets.current.id == "window" else { return }
        let before = store.count
        guard let op = store.apply(msg) else { return }
        if before == 0, store.count > 0 { markedWindow = targets.windowID }
        showOverlay()
        enqueue(op)
    }

    /// Every mark gone, here and on screen.
    func clear() {
        guard store.count > 0 || panel != nil else { return }
        store = MarkStore()
        teardown()
    }

    /// A target choice: whatever was marked belongs to the window before it.
    func targetChosen() {
        staged = nil
        clear()
        onReset?()
    }

    // MARK: Replay (the page's marks become the Mac's, whole or not at all)

    func beginStage(client: Int, gen: Int) {
        staged = (client, gen, MarkStore())
    }

    func stage(client: Int, gen: Int, _ msg: [String: Any]) {
        guard staged?.client == client, staged?.gen == gen else { return }
        _ = staged?.store.apply(msg)
    }

    /// The whole replay has arrived: swap it in, if it is complete (`count` marks) and for the target as it still is.
    func commit(client: Int, gen: Int, count: Int) {
        defer { staged = nil }
        guard var next = staged?.store, staged?.client == client, staged?.gen == gen, gen == targets.generation,
              targets.current.id == "window", next.count == count, count > 0 else {
            log.error("annotate: replay not applied (incomplete or for another target)")
            return
        }
        next.closeAll()
        let before = store.count
        store = next
        if before == 0 { markedWindow = targets.windowID }
        showOverlay()
        resync()
        log.notice("annotate: replay applied, \(count) marks")
    }

    /// The connection that was replaying is gone: what it had sent is dropped and the Mac's own marks stay.
    func dropStage(client: Int) {
        if staged?.client == client { staged = nil }
    }

    // MARK: Overlay window

    private func showOverlay() {
        guard store.count > 0, let markedWindow else { return }
        let fresh = panel == nil
        ensurePanel()
        if fresh { reader.start(window: markedWindow) }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = AnnotPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false  // this app is never active
        panel.isReleasedWhenClosed = false
        // Not floating, not on every Space, not fixed in Mission Control: it is one more layer of the target's own window
        // order, put directly over that window, so what covers the window covers the marks.
        panel.level = .normal
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]

        let config = WKWebViewConfiguration()
        if let root = HTTPServer.webRoot() {
            config.setURLSchemeHandler(BoardPages(root: root), forURLScheme: BoardPages.scheme)
        } else {
            log.error("annotate: no web root (not bundled and PENCILPAD_WEB unset); the overlay stays empty")
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.setValue(false, forKey: "drawsBackground")  // see-through
        view.navigationDelegate = self
        view.unregisterDraggedTypes()
        panel.contentView = view

        self.panel = panel
        webView = view
        loadPage()
    }

    /// Nothing is marked: the window, the web view behind it and the reads of the window server all go.
    private func teardown() {
        reader.stop()
        pending.removeAll()
        loaded = false
        markedWindow = nil
        failures = 0
        panel?.orderOut(nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        panel?.contentView = nil
        webView = nil
        panel = nil
    }

    /// Follows the target: where it is, whether it is shown, and that the overlay is directly above it.
    private func present(_ presence: Presence) {
        guard let panel, let markedWindow else { return }
        switch presence {
        case .gone:
            panel.orderOut(nil)
            onTargetGone?()
        case .hidden:
            if panel.isVisible { panel.orderOut(nil) }
        case .onScreen(let frame, let layer, let above):
            guard let primary = NSScreen.screens.first else { return }
            // Global top-left points to AppKit's bottom-left, flipped against the menu bar's screen.
            let rect = NSRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
            if panel.frame != rect { panel.setFrame(rect, display: false) }
            if panel.level.rawValue != layer { panel.level = NSWindow.Level(rawValue: layer) }
            if !panel.isVisible || !above {
                panel.order(.above, relativeTo: Int(markedWindow))
                reader.setPanel(panel.windowNumber)
            }
        }
    }

    private func loadPage() {
        loaded = false
        webView?.load(URLRequest(url: Self.pageURL))
    }

    /// The page is up: it is given every mark so far.
    fileprivate func pageLoaded() {
        loaded = true
        resync()
    }

    /// The overlay page is made to show exactly the marks held: a clear, then every mark.
    private func resync() {
        guard loaded else { return }
        pending = [["op": "clear"]] + store.ops()
        Task { await drain() }
    }

    private func enqueue(_ op: [String: Any]) {
        guard loaded else { return }  // pageLoaded hands over everything kept so far
        pending.append(op)
        if pending.count > Self.maxPending { pending = [["op": "clear"]] + store.ops() }  // a page that cannot keep up gets a rebuild
        Task { await drain() }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty, let webView, failures < 3 {
            let batch = pending
            pending = []
            do {
                _ = try await webView.callAsyncJavaScript("PencilAnnot.applyAll(list)", arguments: ["list": batch], in: nil, contentWorld: .page)
                failures = 0
            } catch {
                failures += 1
                log.error("annotate: apply failed: \(error.localizedDescription, privacy: .public)")
                if failures < 3 { pending = [["op": "clear"]] + store.ops() }
            }
        }
    }

    // MARK: Save

    private enum SaveError: Error { case encode }

    /// Saves the window's own picture (captured by itself, so a covered window is right) with the marks laid over it, at the
    /// window's full pixel size, as a PNG on the Desktop. Which window, which target generation and which marks are all
    /// fixed here, when the request arrives: whatever changes while the capture runs changes nothing in the file. Returns
    /// the file name, or a plain reason.
    func save(gen: Int?) async -> (name: String?, why: String?) {
        guard targets.current.id == "window", let pid = targets.windowPID else { return (nil, "No window is the target") }
        guard gen == targets.generation else { return (nil, "The window changed before the save; nothing was saved") }
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, "Allow PencilPad under Screen Recording in System Settings, then tap Save again")
        }
        let windowID = targets.windowID, rect = targets.current.rect
        let strokes = store.snapshot()
        let shot: CGImage
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = Projection.match(content.windows, id: windowID, pid: pid, rect: rect) else {
                return (nil, windowID == nil ? "That window can't be told apart from another one right now" : "That window can't be captured right now")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((info.contentRect.width * scale).rounded()))
            config.height = max(1, Int((info.contentRect.height * scale).rounded()))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true  // a window partly past the screen's edge is captured whole
            shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log.error("annotate: capture failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "Screen capture failed: \(String(error.localizedDescription.prefix(80)))")
        }
        var inkURL: String?
        if !strokes.isEmpty {
            guard let exporter = InkExporter(pageURL: Self.pageURL), let url = await exporter.png(of: strokes, width: shot.width, height: shot.height) else {
                return (nil, "The marks could not be drawn")
            }
            inkURL = url
        }
        let base = ImageBox(image: shot), count = strokes.count, ink = inkURL
        do {
            // Decoding, compositing, encoding and the write all stay off the main actor: the first write to the Desktop can sit behind a prompt.
            let name = try await Task.detached {
                var marks: CGImage?
                if let ink {
                    let prefix = "data:image/png;base64,"
                    guard ink.hasPrefix(prefix), let data = Data(base64Encoded: String(ink.dropFirst(prefix.count))),
                          let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { throw SaveError.encode }
                    marks = image
                }
                guard let png = Self.composite(base.image, marks) else { throw SaveError.encode }
                return try SocketServer.saveToDesktop(png, kind: "Annotation")
            }.value
            log.notice("annotate saved \(name, privacy: .public) \(shot.width)x\(shot.height), \(count) strokes")
            return (name, nil)
        } catch {
            log.error("annotate: save failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "The file could not be written to the Desktop")
        }
    }

    private nonisolated static func composite(_ base: CGImage, _ marks: CGImage?) -> Data? {
        let rect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let spaces = [base.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        guard let ctx = spaces.lazy.compactMap({ CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: info) }).first
        else { return nil }
        ctx.draw(base, in: rect)
        if let marks { ctx.draw(marks, in: rect) }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}

extension Annotation: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.notice("annotate: overlay page loaded")
        pageLoaded()
    }

    /// The overlay shows its own page and nothing else.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url == Self.pageURL ? .allow : .cancel
    }

    /// macOS may end the page's process: load it again while there are marks to show, else let it go.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard store.count > 0 else { teardown(); return }
        log.error("annotate: page process ended; loading it again")
        loadPage()
    }
}
