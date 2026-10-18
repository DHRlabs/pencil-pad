import AppKit
import UniformTypeIdentifiers
import WebKit

/// The Board window: a plain titled NSWindow whose WKWebView runs `web/board.html`, so you can share
/// just that window in a call. It only shows the drawing; the iPad page owns the board and replays it
/// whenever the window's page loads. Never activates the app, so the front app (Teams) keeps focus.
@MainActor
final class BoardWindow: NSObject {
    /// The page asked for a replay (it posts {"op":"replay"} once it is up).
    var onReplay: (() -> Void)?
    /// The window was hidden from its close button.
    var onHidden: (() -> Void)?

    /// The page has asked for its replay, so `PencilBoard` can be called. Only that message sets it: ink is
    /// dropped until then, because the page is about to ask for the whole board anyway.
    private(set) var loaded = false
    /// How many times the page has asked for a replay (once per page load). A connection that has been
    /// given the current count has the current board.
    private(set) var pageLoads = 0
    /// The iPad has begun answering the latest replay: an ink `reset` arrived after the page's last load.
    /// Until then the window shows an empty board, so an export would be wrong.
    private(set) var ready = false

    /// The window is up: on screen or minimized, not hidden by the close button or a close message.
    var isShown: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    private static let autosave = "PencilPadBoard"
    /// Matches the board's dark theme so nothing flashes white before the page paints.
    private static let backdrop = NSColor(calibratedWhite: 0.09, alpha: 1)

    private var window: NSWindow?
    private var webView: WKWebView?
    /// Ink and bg messages waiting to be applied. Drained one at a time so the page sees them in arrival order.
    private var pending: [[String: Any]] = []
    private var draining = false

    // MARK: Window

    /// Creates the window on first use and puts it on screen without activating the app.
    /// A window that is already up stays where it is unless `raise` asks to bring it forward.
    func show(raise: Bool = false) {
        ensureWindow()
        guard let window else { return }
        let hidden = !window.isVisible || window.isMiniaturized
        guard hidden || raise else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        if hidden { log.notice("board window shown") }
    }

    /// Hides the window. Returns whether it was up.
    @discardableResult
    func hide() -> Bool {
        guard let window, isShown else { return false }
        window.orderOut(nil)
        log.notice("board window hidden")
        return true
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "PencilPad Board"
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Self.backdrop
        window.delegate = self
        // A saved frame (AppKit keeps it under this name) wins; the very first time the window is centered on the main screen.
        let restored = UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.autosave)") != nil
        if !restored, let screen = NSScreen.screens.first ?? NSScreen.main {
            let area = screen.visibleFrame, size = window.frame.size
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
        window.setFrameAutosaveName(Self.autosave)

        let config = WKWebViewConfiguration()
        config.userContentController.add(PageMessages(self), name: "pencilpad")
        if let root = HTTPServer.webRoot() {
            config.setURLSchemeHandler(BoardPages(root: root), forURLScheme: BoardPages.scheme)
        } else {
            log.error("board: no web root (not bundled and PENCILPAD_WEB unset); the window stays empty")
        }
        let view = WKWebView(frame: window.contentView!.bounds, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.underPageBackgroundColor = Self.backdrop
        view.navigationDelegate = self
        view.unregisterDraggedTypes()  // a file dropped on the shared board must not do anything
        window.contentView?.addSubview(view)

        self.window = window
        webView = view
        loadPage()
    }

    private func loadPage() {
        loaded = false
        ready = false
        pending.removeAll()
        webView?.load(URLRequest(url: BoardPages.pageURL))
    }

    // MARK: Page bridge

    /// Applies one `ink` or `bg` message exactly as received. Dropped until the page is up; the replay
    /// the page asks for on load re-sends the whole board.
    func apply(_ msg: [String: Any]) {
        guard loaded else { return }
        if msg["t"] as? String == "ink", msg["op"] as? String == "reset" { ready = true }
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
                _ = try await webView.callAsyncJavaScript(
                    "PencilBoard.apply(m)", arguments: ["m": msg], in: nil, contentWorld: .page)
            } catch {
                log.error("board: apply failed: \(Self.describe(error), privacy: .public)")
            }
        }
    }

    /// The whole board as PNG data, drawn by the page itself at 3840x2160. Nil at once if the page is not up.
    func png() async -> Data? {
        guard loaded, let webView else { return nil }
        // Ink sent just before the export is still queued; the picture must include it.
        while draining || !pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await PencilBoard.png()", arguments: [:], in: nil, contentWorld: .page)
            let prefix = "data:image/png;base64,"
            guard let url = result as? String, url.hasPrefix(prefix),
                  let data = Data(base64Encoded: String(url.dropFirst(prefix.count)))
            else {
                log.error("board: png() did not return a PNG data URL")
                return nil
            }
            return data
        } catch {
            log.error("board: png() failed: \(Self.describe(error), privacy: .public)")
            return nil
        }
    }

    /// WebKit reports every page error as "A JavaScript exception occurred"; the page's own message is in userInfo.
    private static func describe(_ error: any Error) -> String {
        let info = (error as NSError).userInfo
        let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        return info["WKJavaScriptExceptionLineNumber"].map { "\(message) (line \($0))" } ?? message
    }

    fileprivate func pageMessage(_ body: Any) {
        log.debug("board page message: \(String(describing: body), privacy: .public)")
        guard let msg = body as? [String: Any], msg["op"] as? String == "replay" else { return }
        // The page posts this once PencilBoard exists. The iPad answers the replay at once, so the window
        // takes ink from this moment on, and not before.
        loaded = true
        ready = false
        pageLoads += 1
        log.notice("board: replay requested by page")
        onReplay?()
    }
}

// MARK: WKNavigationDelegate

extension BoardWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.notice("board: page loaded")
    }

    /// The shared window shows the board page and nothing else: a link, a script redirect or a dropped file
    /// must not replace it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.request.url == BoardPages.pageURL else {
            log.notice("board: blocked navigation to \(navigationAction.request.url?.scheme ?? "?", privacy: .public):")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        log.error("board: page failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        log.error("board: page failed to start: \(error.localizedDescription, privacy: .public)")
    }

    /// macOS may end the page's process while the window is hidden. Load it again; the load asks the iPad for a replay.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("board: page process ended; loading it again")
        loadPage()
    }
}

// MARK: NSWindowDelegate

extension BoardWindow: NSWindowDelegate {
    /// The red button hides the window (it is reused, not destroyed) and tells the iPad.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hide() { onHidden?() }
        return false
    }
}

/// Holds the page's message handler weakly: the web view keeps its handlers alive, and a strong
/// reference to the window would make a cycle.
@MainActor
private final class PageMessages: NSObject, WKScriptMessageHandler {
    weak var board: BoardWindow?
    init(_ board: BoardWindow) { self.board = board }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        board?.pageMessage(message.body)
    }
}

/// Serves the web folder to the Board window under its own scheme, so the page gets a real origin and
/// correct content types instead of the opaque origin a file: page has. (The page uses classic scripts;
/// ES modules between file: URLs would not run at all.)
@MainActor
private final class BoardPages: NSObject, WKURLSchemeHandler {
    static let scheme = "pencilpad-board"
    /// A host is needed so the page and its modules share one origin.
    static let pageURL = URL(string: "\(scheme)://board/board.html")!

    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url ?? Self.pageURL
        // Pasted images (subresources of the page, not navigations) come from their own store by id.
        if url.path.hasPrefix("/img/") {
            if let data = BoardImages.data(String(url.path.dropFirst(5))) {
                reply(urlSchemeTask, url: url, status: 200, type: "image/png", body: data, cache: BoardImages.cacheControl)
            } else {
                log.error("board: no such image \(url.path, privacy: .public)")
                reply(urlSchemeTask, url: url, status: 404, type: "text/plain", body: Data())
            }
            return
        }
        let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            log.error("board: no such page file \(url.path, privacy: .public)")
            reply(urlSchemeTask, url: url, status: 404, type: "text/plain", body: Data())
            return
        }
        reply(urlSchemeTask, url: url, status: 200, type: Self.mimeType(file), body: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func reply(_ task: any WKURLSchemeTask, url: URL, status: Int, type: String, body: Data, cache: String = "no-store") {
        let headers = ["Content-Type": type, "Content-Length": String(body.count), "Cache-Control": cache]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    /// The page types are spelled out so scripts always get a JavaScript type.
    private static func mimeType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        default: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
