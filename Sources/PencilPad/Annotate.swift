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

/// Mouse mode's Annotate: the Pencil's marks over the target window. The iPad owns what it draws and sends every op;
/// this keeps them (so a page that loads late, or again, gets all of them), shows them in an overlay window drawn by
/// the same board-core.js, and saves the window's picture with the marks on top. Unlike the region outline the overlay
/// is NOT kept out of shares and captures: it is there so the room sees the marks.
@MainActor
final class Annotation: NSObject {
    /// The marks went away because another window or a screen became the target (the page clears its copy too).
    var onReset: (() -> Void)?

    /// Marks on show (strokes begun since the last clear).
    private(set) var strokes = 0

    private let targets: Targets
    private var panel: AnnotPanel?
    private var webView: WKWebView?
    private var loaded = false
    /// Every begin, pts and end since the last clear, in order.
    private var ops: [[String: Any]] = []
    /// Ops waiting to be applied, drained one at a time so the page sees them in arrival order.
    private var pending: [[String: Any]] = []
    private var draining = false
    private var wasWindow = false

    private static let pageURL = URL(string: "\(BoardPages.scheme)://board/annot.html")!

    init(targets: Targets) {
        self.targets = targets
        super.init()
    }

    // MARK: Ops from the iPad

    /// begin, pts or end: kept, and drawn in the overlay. Only a window target can be marked.
    func apply(_ msg: [String: Any]) {
        guard targets.current.id == "window" else { return }
        let op = msg["op"] as? String
        guard op == "begin" || op == "pts" || op == "end" else { return }
        if op == "begin" { strokes += 1 }
        ops.append(msg)
        ensurePanel()
        place()
        panel?.orderFrontRegardless()
        enqueue(msg)
    }

    /// Every mark gone, here and on screen.
    func clear() {
        guard strokes > 0 || !ops.isEmpty else { return }
        ops.removeAll()
        strokes = 0
        pending.removeAll()
        if loaded { enqueue(["op": "clear"]) }
        panel?.orderOut(nil)
    }

    // MARK: Following the target

    /// The target moved or resized (the overlay follows it), or stopped being a window (the marks go).
    func retarget() {
        let isWindow = targets.current.id == "window"
        defer { wasWindow = isWindow }
        if wasWindow, !isWindow { reset(); return }
        if panel?.isVisible == true { place() }
    }

    /// Another window was made the target.
    func windowChosen() {
        reset()
    }

    private func reset() {
        clear()
        onReset?()
    }

    /// Exactly over the window: global top-left points to AppKit's bottom-left, flipped against the menu bar's screen.
    private func place() {
        guard let panel, let primary = NSScreen.screens.first else { return }
        let r = targets.current.rect
        let frame = NSRect(x: r.minX, y: primary.frame.height - r.maxY, width: r.width, height: r.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: Overlay window

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = AnnotPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false  // this app is never active
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

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

    private func loadPage() {
        loaded = false
        webView?.load(URLRequest(url: Self.pageURL))
    }

    /// The page is up: it is given every mark so far.
    fileprivate func pageLoaded() {
        loaded = true
        pending = ops
        Task { await drain() }
    }

    private func enqueue(_ msg: [String: Any]) {
        guard loaded else { return }  // pageLoaded hands over everything kept so far
        pending.append(msg)
        Task { await drain() }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty, let webView {
            let msg = pending.removeFirst()
            do {
                _ = try await webView.callAsyncJavaScript("PencilAnnot.apply(m)", arguments: ["m": msg], in: nil, contentWorld: .page)
            } catch {
                log.error("annotate: apply failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Save

    /// Saves the window's own picture (captured by itself, so a covered window is right) with the marks laid over it, at the
    /// window's full pixel size, as a PNG on the Desktop. Returns the file name, or a plain reason.
    func save() async -> (name: String?, why: String?) {
        guard targets.current.id == "window", let pid = targets.windowPID else { return (nil, "No window is the target") }
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, "Allow PencilPad under Screen Recording in System Settings, then tap Save again")
        }
        let rect = targets.current.rect
        let shot: CGImage
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = Projection.match(content.windows, pid: pid, rect: rect) else { return (nil, "That window can't be captured right now") }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((info.contentRect.width * scale).rounded()))
            config.height = max(1, Int((info.contentRect.height * scale).rounded()))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log.error("annotate: capture failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "Screen capture failed: \(String(error.localizedDescription.prefix(80)))")
        }
        var ink: CGImage?
        if strokes > 0 {
            guard let layer = await inkImage(width: shot.width, height: shot.height) else { return (nil, "The marks could not be drawn") }
            ink = layer
        }
        let base = ImageBox(image: shot), marks = ink.map(ImageBox.init)
        do {
            // Compositing, encoding and the write stay off the main actor: the first write to the Desktop can sit behind a prompt.
            let name = try await Task.detached {
                guard let png = Self.composite(base.image, marks?.image) else { throw SaveError.encode }
                return try SocketServer.saveToDesktop(png, kind: "Annotation")
            }.value
            log.notice("annotate: saved \(name, privacy: .public) \(shot.width)x\(shot.height), \(self.strokes) strokes")
            return (name, nil)
        } catch {
            log.error("annotate: save failed: \(error.localizedDescription, privacy: .public)")
            return (nil, "The file could not be written to the Desktop")
        }
    }

    private enum SaveError: Error { case encode }

    /// The marks alone, drawn by the overlay page at `width` x `height` pixels. Waits for ops still queued.
    private func inkImage(width: Int, height: Int) async -> CGImage? {
        for _ in 0..<600 where !loaded || draining || !pending.isEmpty {  // up to 3 s
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard loaded, let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return PencilAnnot.png(w, h)", arguments: ["w": width, "h": height], in: nil, contentWorld: .page)
            let prefix = "data:image/png;base64,"
            guard let url = result as? String, url.hasPrefix(prefix),
                  let data = Data(base64Encoded: String(url.dropFirst(prefix.count))),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        } catch {
            log.error("annotate: png() failed: \(error.localizedDescription, privacy: .public)")
            return nil
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

    /// macOS may end the page's process while nothing is showing: load it again; the marks are given back when it is up.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("annotate: page process ended; loading it again")
        loadPage()
    }
}
