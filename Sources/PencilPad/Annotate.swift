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

/// Hears the overlay page's `paint` messages without the web view's configuration keeping the Annotation alive.
@MainActor
private final class PaintReports: NSObject, WKScriptMessageHandler {
    weak var owner: Annotation?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { owner?.paintFailed() }
}

/// A finished image carried to a detached task.
private struct ImageBox: @unchecked Sendable { let image: CGImage }

/// The marks themselves, kept compactly: a flat run of Floats (x, y, pressure) per mark, never the messages they came in.
/// The Mac is the only place they are kept. Every rule about which messages count lives here, so a live stroke and a rebuild
/// agree: a begin needs an id not yet held and a drawable first point, points and ends for a mark that is not open are
/// ignored, and nothing is ever cut short quietly: past the caps a begin is refused and a stroke is ended where the cap is.
private struct MarkStore: Sendable {
    struct Mark: Sendable {
        var color: String
        var size: Double
        var pts: [Float]  // x, y, p, x, y, p, ...
        var open: Bool
    }

    enum Refusal: Sendable {
        case cap, noPoint, duplicate
        var kind: String {
            switch self {
            case .cap: "cap"
            case .duplicate: "dup"  // the page keeps the stroke it already had; it must not erase it
            case .noPoint: "invalid"
            }
        }
        var why: String {
            switch self {
            case .cap: "Too many marks on this window. Clear them to keep drawing"
            case .noPoint: "That mark had no point to draw"
            case .duplicate: "That mark was already there"
            }
        }
    }

    enum Outcome {
        /// Kept; this is the op to show in the overlay.
        case accepted([String: Any])
        /// Kept up to the cap and ended there: the ops to show, and how many points the mark has.
        case cut(shown: [[String: Any]], id: Int, len: Int)
        case refused(id: Int, Refusal)
        /// Not for an open mark (or not a mark message at all).
        case ignored
    }

    /// What the Mac will hold per window.
    static let maxMarks = 500
    static let maxPoints = 100_000
    /// Points in one op sent to a page or the overlay (a frame stays well under 60 KB).
    static let chunk = 400

    private(set) var marks: [Int: Mark] = [:]
    private(set) var order: [Int] = []
    private var points = 0

    var count: Int { order.count }

    mutating func apply(_ msg: [String: Any]) -> Outcome {
        guard let op = msg["op"] as? String, let id = Self.id(msg["id"]) else { return .ignored }
        switch op {
        case "begin":
            if marks[id] != nil { return .refused(id: id, .duplicate) }
            let all = Self.points(msg["pts"], firstMustDraw: true)
            guard !all.isEmpty else { return .refused(id: id, .noPoint) }  // before the caps: a malformed first point is `invalid` even when full
            if order.count >= Self.maxMarks || points >= Self.maxPoints { return .refused(id: id, .cap) }
            let room = Self.maxPoints - points, have = all.count / 3
            let kept = have > room ? Array(all.prefix(room * 3)) : all
            let color = Self.color(msg["color"])
            let size = min(0.05, max(0.0005, Self.num(msg["size"]) ?? 0.0065))
            marks[id] = Mark(color: color, size: size, pts: kept, open: have <= room)
            order.append(id)
            points += kept.count / 3
            let begin: [String: Any] = ["op": "begin", "id": id, "tool": "pen", "color": color, "size": size, "pts": Self.json(kept)]
            return have > room ? .cut(shown: [begin, ["op": "end", "id": id]], id: id, len: room) : .accepted(begin)
        case "pts":
            guard let mark = marks[id], mark.open else { return .ignored }
            let all = Self.points(msg["pts"], firstMustDraw: false)
            guard !all.isEmpty else { return .ignored }
            let room = Self.maxPoints - points, have = all.count / 3
            guard room > 0 else {
                marks[id]?.open = false
                return .cut(shown: [["op": "end", "id": id]], id: id, len: mark.pts.count / 3)
            }
            let kept = have > room ? Array(all.prefix(room * 3)) : all
            marks[id]?.pts.append(contentsOf: kept)
            points += kept.count / 3
            let more: [String: Any] = ["op": "pts", "id": id, "pts": Self.json(kept)]
            guard have > room else { return .accepted(more) }
            marks[id]?.open = false
            return .cut(shown: [more, ["op": "end", "id": id]], id: id, len: mark.pts.count / 3 + room)
        case "end":
            guard marks[id]?.open == true else { return .ignored }
            marks[id]?.open = false
            return .accepted(["op": "end", "id": id])
        default:
            return .ignored
        }
    }

    /// Every open mark is finished (the Pencil that was drawing them is gone); returns their ids.
    mutating func closeAll() -> [Int] {
        let open = order.filter { marks[$0]?.open == true }
        for id in open { marks[id]?.open = false }
        return open
    }

    /// The ops that rebuild exactly these marks in an empty page.
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

    /// A finite JSON number. A Boolean is not one (it would read as 0 or 1).
    private static func num(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static func id(_ any: Any?) -> Int? {
        guard let value = num(any), abs(value) < 1e9, value == value.rounded() else { return nil }
        return Int(value)
    }

    private static func color(_ any: Any?) -> String {
        guard let s = any as? String, s.count == 7, s.hasPrefix("#"), s.dropFirst().allSatisfy(\.isHexDigit) else { return "#ff453a" }
        return s.lowercased()
    }

    /// Clamped to 0...1 and rounded to five places, as the page keeps them.
    private static func r5(_ v: Double) -> Float { Float((min(max(v, 0), 1) * 1e5).rounded() / 1e5) }

    /// Every drawable point in the list (a finite x and y), flat. With `firstMustDraw` (a begin) the very first one has to be
    /// drawable, else nothing is kept: a later point is not made the start of a mark the page never drew that way.
    private static func points(_ any: Any?, firstMustDraw: Bool) -> [Float] {
        guard let list = any as? [Any] else { return [] }
        var out: [Float] = []
        out.reserveCapacity(list.count * 3)
        for (i, item) in list.enumerated() {
            guard let p = item as? [Any], p.count > 1, let x = num(p[0]), let y = num(p[1]) else {
                if i == 0, firstMustDraw { return [] }
                continue
            }
            out.append(r5(x))
            out.append(r5(y))
            out.append(r5(p.count > 2 ? (num(p[2]) ?? 0.5) : 0.5))
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
/// Everything it keeps belongs to its queue; each tracking run has a number, and a report from an earlier run is dropped by the caller.
private final class PresenceReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pencilpad.annot.presence", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var window = CGWindowID(0), panel = 0, track = 0
    private var last: Presence?
    private var still = 0, goneRuns = 0, slow = false
    private let report: @Sendable (Presence, Int) -> Void

    init(report: @escaping @Sendable (Presence, Int) -> Void) { self.report = report }

    func start(window: CGWindowID, track: Int) {
        queue.async { [self] in
            self.window = window; self.track = track; panel = 0; last = nil; still = 0; goneRuns = 0; slow = false
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.setEventHandler { [weak self] in self?.tick() }
                timer = t
                t.resume()
            }
            timer?.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(5))
        }
    }

    func setPanel(_ number: Int, track: Int) { queue.async { [self] in if self.track == track { panel = number } } }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            last = nil
        }
    }

    private func tick() {
        guard timer != nil else { return }
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
        report(now, track)
    }

    private static func read(window: CGWindowID, panel: Int) -> Presence {
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
        // Directly over the window: the very next one in front of it. Any window in between, one of PencilPad's own too (the
        // Board window), would be under the ink, so the overlay is put back right over the target and that window covers it.
        let above = over.map { $0 + 1 == target } ?? false
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

    /// The marks alone, transparent, as a PNG data URL `width` x `height` pixels; nil when the page did not come up or draw. The marks
    /// arrive as one JSON string, so the hand-off to WebKit (which happens on the main actor) is a single string; the page parses it.
    func png(of strokes: String, width: Int, height: Int) async -> String? {
        let up = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuation = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finish(false)
            }
        }
        guard up else { return nil }
        do {
            let result = try await view.callAsyncJavaScript("PencilAnnot.loadStrokes(JSON.parse(list)); return PencilAnnot.png(w, h)",
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

/// Mouse mode's Annotate: the Pencil's marks over the target window. The Mac is the only place the marks are kept: the iPad
/// draws its own stroke at once for feel and sends it, and is sent the Mac's marks whole after every hello, window choice and
/// Clear. They are shown in an overlay window drawn by the same board-core.js, and saved over the window's picture. Unlike the
/// region outline the overlay is NOT kept out of shares and captures: it is there so the room sees the marks.
///
/// The overlay, its web view and the reads of the window server exist only while marks do (the first mark makes them, the
/// last one's going releases them). It sits directly above the target window in the window order (so any window in front of
/// the target, PencilPad's Board window too, covers the ink), disappears with a hidden, minimized or other-Space target, and
/// follows the window by what the window server reports, whoever is connected.
@MainActor
final class Annotation: NSObject {
    /// The target window is gone from the window server: the caller should ask the app (a read the Accessibility API confirms).
    var onTargetGone: (() -> Void)?
    /// The window server's reading of the target window's frame, for the caller to adopt if the window was resized.
    var onFrame: ((CGRect, CGWindowID) -> Void)?

    /// Marks on show.
    var strokes: Int { store.count }

    private let targets: Targets
    private var store = MarkStore()
    private var panel: AnnotPanel?
    private var webView: WKWebView?
    private var loaded = false
    /// Ops waiting to be applied, in order, once the page is up and idle.
    private var pending: [[String: Any]] = []
    /// The overlay page must be rebuilt from the store before anything else (one flag, however many messages come meanwhile).
    private var rebuild = false
    private var draining = false
    private var failures = 0
    /// The window the marks are over (the window server's number), fixed when the first one was made.
    private var markedWindow: CGWindowID?
    /// Numbers each run of the reader, so a read from an earlier run (an earlier window) is ignored.
    private var track = 0
    /// Made by the first mark, released with the last (nil: nothing is being read).
    private var reader: PresenceReader?

    private static let pageURL = URL(string: "\(BoardPages.scheme)://board/annot.html")!
    /// More than this waiting and the queue is dropped for a rebuild from the store.
    private static let maxPending = 2_000
    /// Ops in one call to the overlay page.
    private static let perCall = 20

    init(targets: Targets) {
        self.targets = targets
        super.init()
    }

    // MARK: Ops from the iPad

    /// Why Annotate cannot start on this target, or nil. It needs the window server's number for the window: no guessing by frame.
    var refusal: String? {
        guard targets.current.id == "window" else { return "Only a window can be marked" }
        guard targets.windowID != nil else { return "Annotate can't tell this window from the others on this Mac, so it can't mark it" }
        return nil
    }

    /// begin, pts or end (the caller has checked the generation): kept, and drawn in the overlay. Returns what the iPad is to be
    /// told, if anything: a `drop` naming a begin that was refused, or a `cut` where a stroke was ended at the cap.
    func apply(_ msg: [String: Any]) -> [String: Any]? {
        if msg["op"] as? String == "begin", let why = refusal, let id = MarkStore.id(msg["id"]) {
            return ["op": "drop", "id": id, "kind": "window", "why": why]
        }
        let before = store.count
        switch store.apply(msg) {
        case .accepted(let op):
            started(before)
            enqueue(op)
        case .cut(let shown, let id, let len):
            started(before)
            shown.forEach(enqueue)
            return ["op": "cut", "id": id, "len": len, "why": "Too many points on this window. The mark ended here"]
        case .refused(let id, let reason):
            return ["op": "drop", "id": id, "kind": reason.kind, "why": reason.why]
        case .ignored:
            break
        }
        return nil
    }

    /// The first mark makes the overlay.
    private func started(_ before: Int) {
        guard before == 0, store.count > 0 else { return }
        markedWindow = targets.windowID
        showOverlay()
    }

    /// Every mark gone, here and on screen.
    func clear() {
        guard store.count > 0 || panel != nil else { return }
        store = MarkStore()
        teardown()
    }

    /// A target choice: whatever was marked belongs to the window before it.
    func targetChosen() { clear() }

    /// The Pencil that was drawing is gone (the connection ended): its open marks are finished where they stand.
    func closeOpen() {
        for id in store.closeAll() { enqueue(["op": "end", "id": id]) }
    }

    /// What a page is sent to show exactly these marks.
    func syncOps() -> [[String: Any]] { store.ops() }

    // MARK: Overlay window

    private func showOverlay() {
        guard store.count > 0, let markedWindow, panel == nil else { return }
        ensurePanel()
        track += 1
        let reader = PresenceReader { [weak self] presence, track in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(presence, track: track) } }
        }
        self.reader = reader
        reader.start(window: markedWindow, track: track)
    }

    private func ensurePanel() {
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
        let reports = PaintReports()
        reports.owner = self
        config.userContentController.add(reports, name: "paint")
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
        reader?.stop()  // cancels its timer on its own queue; nothing keeps the reader or the queue alive after that
        reader = nil
        track += 1
        pending.removeAll()
        rebuild = false
        loaded = false
        markedWindow = nil
        failures = 0
        panel?.orderOut(nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "paint")
        panel?.contentView = nil
        webView = nil
        panel = nil
    }

    /// Follows the target: where it is, whether it is shown, and that the overlay is directly above it.
    private func present(_ presence: Presence, track mine: Int) {
        guard mine == track, let panel, let markedWindow else { return }
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
                reader?.setPanel(panel.windowNumber, track: mine)
            }
            onFrame?(frame, markedWindow)
        }
    }

    private func loadPage() {
        loaded = false
        webView?.load(URLRequest(url: Self.pageURL))
    }

    /// The page is up (again): its failures are forgotten and it is rebuilt, once, from the marks held.
    fileprivate func pageLoaded() {
        loaded = true
        failures = 0
        rebuild = true
        Task { await drain() }
    }

    /// The overlay page could not paint on its own (a resize, a timer): what it shows may be missing ink, so it is rebuilt once from
    /// the store, the same recovery a failed batch gets.
    fileprivate func paintFailed() {
        guard loaded, webView != nil else { return }
        failures += 1
        log.error("annotate: overlay page reported a failed paint; rebuilding")
        rebuild = true
        pending = []
        Task { await drain() }
    }

    /// A mark change for the overlay. While a rebuild is due it reads the store itself, so there is nothing to queue.
    private func enqueue(_ op: [String: Any]) {
        guard loaded, !rebuild else { return }  // pageLoaded hands over everything kept so far
        pending.append(op)
        if pending.count > Self.maxPending { pending = []; rebuild = true }  // a page that cannot keep up gets one rebuild
        Task { await drain() }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while loaded, let webView, failures < 3, rebuild || !pending.isEmpty {
            var batch: [[String: Any]]
            if rebuild {
                rebuild = false
                pending = []
                batch = [["op": "clear"]] + store.ops()  // read once, here: later changes queue behind it
            } else {
                batch = pending
                pending = []
            }
            while !batch.isEmpty {
                let part = Array(batch.prefix(Self.perCall))
                batch.removeFirst(part.count)
                do {
                    _ = try await webView.callAsyncJavaScript("return PencilAnnot.applyAll(list)", arguments: ["list": part], in: nil, contentWorld: .page)
                } catch {
                    failures += 1
                    log.error("annotate: apply failed: \(error.localizedDescription, privacy: .public)")
                    rebuild = true  // what was lost is put back from the store, not patched
                    pending = []
                    batch = []
                }
            }
        }
        if failures >= 3, loaded {  // the page is not drawing: a fresh one is loaded, and its load rebuilds everything
            loaded = false
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.loadPage()
            }
        }
    }

    // MARK: Save

    private enum SaveError: Error { case encode }

    /// Fixes, now, what a save is of: the window (its server number), the target choice (`gen`) and a value copy of the marks.
    /// Whatever changes after this changes nothing in the file. The returned closure does the rest (capture, drawing,
    /// compositing, the write) and answers with the file name, or a plain reason; the frozen `gen` is what the reply is stamped with.
    func beginSave() -> (gen: Int, run: () async -> (name: String?, why: String?)) {
        let gen = targets.generation
        guard targets.current.id == "window", let pid = targets.windowPID else { return (gen, { (nil, "No window is the target") }) }
        guard let windowID = targets.windowID else { return (gen, { (nil, "That window can't be told apart from the others on this Mac, so it was not saved") }) }
        let marks = store
        return (gen, { [self] in await write(windowID: windowID, pid: pid, marks: marks) })
    }

    /// Captures window `windowID` by itself with ScreenCaptureKit (a covered window saves right, no cursor, no shadow, a window
    /// partly past a screen's edge whole) at its full pixel size, lays the frozen marks over it, and writes the PNG to the Desktop.
    private func write(windowID: CGWindowID, pid: pid_t, marks: MarkStore) async -> (name: String?, why: String?) {
        let captured = await Self.capture(windowID: windowID, pid: pid)  // all of ScreenCaptureKit's setup and capture run off the input actor
        guard let shot = captured.image?.image else { return (nil, captured.why ?? "Screen capture failed") }
        var inkURL: String?
        if marks.count > 0 {
            // Expanded and serialized off the input actor: a full store is hundreds of thousands of numbers.
            let strokes = await Task.detached { () -> String? in
                (try? JSONSerialization.data(withJSONObject: marks.snapshot())).flatMap { String(data: $0, encoding: .utf8) }
            }.value
            guard let strokes, let url = await inkPNG(of: strokes, width: shot.width, height: shot.height) else {
                return (nil, "The marks could not be drawn")
            }
            inkURL = url
        }
        let base = ImageBox(image: shot), count = marks.count, ink = inkURL
        do {
            // Decoding, compositing, encoding and the write all stay off the main actor: the first write to the Desktop can sit behind a prompt.
            let name = try await Task.detached {
                var overlay: CGImage?
                if let ink {
                    let prefix = "data:image/png;base64,"
                    guard ink.hasPrefix(prefix), let data = Data(base64Encoded: String(ink.dropFirst(prefix.count))),
                          let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { throw SaveError.encode }
                    overlay = image
                }
                guard let png = Self.composite(base.image, overlay) else { throw SaveError.encode }
                return try SocketServer.saveToDesktop(png, kind: "Annotation")
            }.value
            log.notice("annotate saved \(name, privacy: .public) \(shot.width)x\(shot.height), \(count) strokes")
            return (name, nil)
        } catch {
            log.error("annotate: save failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "The file could not be written to the Desktop")
        }
    }

    /// The window `windowID` of `pid`, captured by itself at its full pixel size; or a plain reason. Runs off the main actor.
    private nonisolated static func capture(windowID: CGWindowID, pid: pid_t) async -> (image: ImageBox?, why: String?) {
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, "Allow PencilPad under Screen Recording in System Settings, then tap Save again")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }) else {
                return (nil, "That window can't be captured right now")
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
            return (ImageBox(image: try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)), nil)
        } catch {
            log.error("annotate: capture failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "Screen capture failed: \(String(error.localizedDescription.prefix(80)))")
        }
    }

    /// The frozen marks drawn alone, as a PNG data URL. While marks exist the overlay's own page does it (on a board of its own, so
    /// nothing live is touched and nothing has to be created on the main actor); after a Clear it is a page made for the purpose.
    private func inkPNG(of strokes: String, width: Int, height: Int) async -> String? {
        if loaded, let view = webView {
            do {
                let result = try await view.callAsyncJavaScript("return PencilAnnot.pngOf(JSON.parse(list), w, h)",
                                                                arguments: ["list": strokes, "w": width, "h": height], in: nil, contentWorld: .page)
                if let url = result as? String { return url }
            } catch {
                log.error("annotate: overlay could not draw the save: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let exporter = InkExporter(pageURL: Self.pageURL) else { return nil }
        return await exporter.png(of: strokes, width: width, height: height)
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

    /// A load that fails is tried again shortly: the overlay is not left blank for good.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("annotate: overlay page failed to load: \(error.localizedDescription, privacy: .public)")
        guard store.count > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.loaded == false { self?.loadPage() }
        }
    }
}
