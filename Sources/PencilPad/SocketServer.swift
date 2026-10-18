import AppKit
import Foundation
import Network

@MainActor
final class Client {
    let id: Int
    let conn: NWConnection
    var authed = false
    var ended = false
    let opened = ProcessInfo.processInfo.systemUptime
    var lastFrame = ProcessInfo.processInfo.systemUptime
    /// The Board window's `pageLoads` when this connection was last asked to replay (-1: never).
    var boardReplayed = -1
    /// Input messages waiting, in order, for a fresh window frame before the first touch after a quiet spell (nil: none waiting).
    var held: [Data]?

    init(id: Int, conn: NWConnection) {
        self.id = id
        self.conn = conn
    }
}

/// WebSocket on 8711. Speaks the AGENTS.md protocol; one authenticated client at a time, newest wins.
@MainActor
final class SocketServer {
    nonisolated static let port: NWEndpoint.Port = NWEndpoint.Port(rawValue: HTTPServer.port.rawValue + 1)!
    /// Silence that releases a held button.
    static let silenceLimit: TimeInterval = 2
    /// Time allowed to send a valid hello, and silence that closes a logged-in client.
    static let idleLimit: TimeInterval = 10

    private let targets: Targets
    private let pen: Pen
    private var listener: NWListener?
    private var watchdog: DispatchSourceTimer?
    private var clients: [Int: Client] = [:]
    private var nextID = 1
    /// The Board window. Its replies (state, replay requests) go to the active client.
    private lazy var board = makeBoard()
    /// Shows where the iPad is zoomed to.
    private lazy var outline = RegionOutline(targets: targets)
    /// Streams the target area to the iPad while it asks for it.
    private lazy var projection = Projection(
        targets: targets, outline: outline,
        reply: { [weak self] owner, ok, why in
            guard let self, let c = active, c.id == owner else { return }
            send(c, why.map { ["t": "show", "ok": ok, "why": $0] } ?? ["t": "show", "ok": ok])
        },
        sendFrame: { [weak self] owner, data in
            guard let self, let c = active, c.id == owner else { return }
            sendBinary(c, data)
        })
    /// When the Pencil last reached the Mac (a hover, touch, move or lift, or a zoom change).
    private var lastContact = ProcessInfo.processInfo.systemUptime
    /// The Pencil has reached the Mac in the last few seconds: only then is a window target's frame read in the background.
    private var pencilActive = false
    private static let quietAfter: TimeInterval = 5
    /// The one authenticated client. While there is one, App Nap is held off so input never lags.
    private(set) var active: Client? {
        didSet {
            if active != nil, appNapHold == nil {
                appNapHold = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "PencilPad iPad connected")
                log.notice("activity begun: App Nap held off while client \(self.active?.id ?? 0) is connected")
            } else if active == nil, let hold = appNapHold {
                ProcessInfo.processInfo.endActivity(hold)
                appNapHold = nil
                log.notice("activity ended: no client connected")
            }
        }
    }
    private var appNapHold: NSObjectProtocol?

    init(targets: Targets, pen: Pen) {
        self.targets = targets
        self.pen = pen
        targets.onChange = { [weak self] in self?.projection.retarget() }  // a moved or resized window, another target
        targets.onFollowChange = { [weak self] in self?.pushTarget() }  // the window was resized, or went away
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        do {
            let listener = try NWListener(using: params, on: Self.port)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: log.notice("socket listening on port \(Self.port.rawValue)")
                case .failed(let error): log.error("socket listener failed: \(error, privacy: .public)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.error("socket listener could not start: \(error, privacy: .public)")
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        watchdog = timer
    }

    func pushScreens() {
        guard let c = active else { return }
        send(c, ["t": "screens", "screens": targets.screens.map(\.json)])
    }

    func pushTarget() {
        guard let c = active else { return }
        send(c, ["t": "target", "target": targets.current.json])
    }

    // MARK: Board

    private func makeBoard() -> BoardWindow {
        let board = BoardWindow()
        board.onReplay = { [weak self] in
            guard let self, let c = active else { return }
            askReplay(c)
        }
        board.onHidden = { [weak self] in
            guard let self, let c = active else { return }
            send(c, ["t": "board", "op": "state", "open": false])
        }
        return board
    }

    /// Asks the iPad page to send the whole board again, and remembers that this connection has it.
    private func askReplay(_ c: Client) {
        c.boardReplayed = board.pageLoads
        send(c, ["t": "board", "op": "replay"])
    }

    /// Tells a connection where the window stands, and brings its board up to date: whenever the window is
    /// showing with its page loaded and this connection has not replayed into that page load, it is asked to.
    /// The one place that decides; login, the open message and the menu all end here.
    private func reportBoard(to c: Client) {
        send(c, ["t": "board", "op": "state", "open": board.isShown])
        if board.isShown, board.loaded, c.boardReplayed != board.pageLoads { askReplay(c) }
    }

    /// Shows the window and reports it to the active connection. Shared by the open message and the menu.
    private func presentBoard(raise: Bool = false) {
        board.show(raise: raise)
        if let c = active { reportBoard(to: c) }
    }

    /// Menu bar: show the Board window, in front.
    func showBoard() {
        presentBoard(raise: true)
    }

    private func handleBoard(_ c: Client, _ msg: [String: Any]) {
        switch msg["op"] as? String {
        case "open":
            presentBoard()
        case "close":
            board.hide()
            send(c, ["t": "board", "op": "state", "open": false])
        case "bg":
            board.apply(msg)
        case "copy":
            exportBoard(c, what: "copy")
        case "save":
            exportBoard(c, what: "save")
        case "paste":
            pasteImage(c)
        default:
            log.debug("client \(c.id): unknown board op \(msg["op"] as? String ?? "", privacy: .public)")
        }
    }

    /// Stores the image on the Mac clipboard and tells the iPad its id and size, or why there is none.
    /// The page then places it with an `image` op; the file is served to both boards by id.
    private func pasteImage(_ c: Client) {
        let sources = BoardImages.clipboard()  // read here; decoding a big screenshot happens off the main actor
        Task {
            let result = await Task.detached { BoardImages.store(sources) }.value
            switch result {
            case .success(let image):
                log.notice("board paste: stored \(image.k, privacy: .public) \(image.w)x\(image.h)")
                send(c, ["t": "board", "op": "pasted", "ok": true, "img": image.k, "w": image.w, "h": image.h])
            case .failure(let failure):
                log.notice("board paste: \(failure.why, privacy: .public)")
                send(c, ["t": "board", "op": "pasted", "ok": false, "why": failure.why])
            }
        }
    }

    /// Every ink message goes to the window unchanged; it applies exactly what the iPad applied.
    private func forwardInk(_ msg: [String: Any]) {
        log.debug("board: forwarding ink \(msg["op"] as? String ?? "", privacy: .public)")
        board.apply(msg)
    }

    /// Renders the board and copies it or saves it, then reports done to the iPad. A window page that is
    /// not up, or has not had its reset since it loaded, fails at once; the iPad page opens the window and
    /// answers the replay before exporting.
    private func exportBoard(_ c: Client, what: String) {
        guard board.loaded, board.ready else {
            let why = board.loaded ? "the window page has not had its reset yet" : "the window page is not loaded"
            log.notice("board \(what, privacy: .public): failed, \(why, privacy: .public)")
            send(c, ["t": "board", "op": "done", "what": what, "ok": false, "name": ""])
            return
        }
        Task {
            var ok = false
            var name = ""
            var bytes = 0
            if let data = await board.png() {
                bytes = data.count
                if what == "save" {
                    do {
                        // Off the main thread: the first write to the Desktop can sit behind a permission prompt.
                        name = try await Task.detached { try Self.saveToDesktop(data) }.value
                        ok = true
                    } catch {
                        log.error("board: save failed: \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    NSPasteboard.general.clearContents()
                    ok = NSPasteboard.general.setData(data, forType: .png)
                }
            }
            log.notice("board \(what, privacy: .public): \(ok ? "ok" : "failed", privacy: .public), \(bytes) bytes")
            send(c, ["t": "board", "op": "done", "what": what, "ok": ok, "name": name])
        }
    }

    /// Writes the PNG to the Desktop as "PencilPad Board <yyyy-MM-dd at HH.mm.ss>.png" in local time and
    /// returns the file name. A name that is taken (two saves in one second) gets " 2", " 3" before the
    /// extension; the write itself refuses to overwrite, so concurrent saves cannot collide.
    private nonisolated static func saveToDesktop(_ data: Data) throws -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")  // the format is part of the name, not the locale
        clock.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "PencilPad Board \(clock.string(from: Date()))"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        var n = 1
        while true {
            let name = n == 1 ? "\(stem).png" : "\(stem) \(n).png"
            do {
                try data.write(to: desktop.appendingPathComponent(name), options: .withoutOverwriting)
                return name
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                n += 1
            }
        }
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let c = Client(id: nextID, conn: conn)
        nextID += 1
        clients[c.id] = c
        log.notice("client \(c.id) connected from \(String(describing: conn.endpoint), privacy: .public)")
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error): self?.end(c, reason: "failed: \(error)", closeFrame: false)
                case .cancelled: self?.end(c, reason: "cancelled", closeFrame: false)
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(c)
    }

    private func receive(_ c: Client) {
        c.conn.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !c.ended else { return }
                if let error {
                    self.end(c, reason: "receive error: \(error)", closeFrame: false)
                    return
                }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                guard let meta else {
                    self.end(c, reason: "connection closed by peer", closeFrame: false)
                    return
                }
                c.lastFrame = ProcessInfo.processInfo.systemUptime  // every frame counts, pings included
                switch meta.opcode {
                case .close:
                    self.end(c, reason: "close frame from peer", closeFrame: false)
                    return
                case .text, .binary:
                    self.handle(c, data ?? Data())
                default:
                    break
                }
                if !c.ended { self.receive(c) }
            }
        }
    }

    /// The only way a client ends. If it is the active client, its held button is released first.
    /// `farewell` ("denied", "replaced") is sent as {"t": farewell} just before the close frame.
    private func end(_ c: Client, reason: String, farewell: String? = nil, closeFrame: Bool) {
        guard !c.ended else { return }
        c.ended = true
        clients[c.id] = nil
        if active === c {
            active = nil
            pen.release(reason: "client \(c.id) \(reason)")
            outline.reset()
            projection.hide()
        }
        log.notice("client \(c.id) closed: \(reason, privacy: .public)")
        let conn = c.conn
        conn.stateUpdateHandler = nil  // breaks the Client <-> handler cycle; the clients dictionary was the owner
        // Frames only go out on a finished WebSocket handshake; otherwise they would queue forever.
        guard closeFrame, case .ready = conn.state else {
            conn.cancel()
            return
        }
        if let farewell { write(conn, ["t": farewell]) }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        conn.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // A connection that has not proven the token within 10 s is closed.
        for c in Array(clients.values) where !c.authed && now - c.opened >= Self.idleLimit {
            end(c, reason: "no valid hello within \(Int(Self.idleLimit)) s", closeFrame: true)
        }
        guard let c = active else { return }
        if pencilActive, pen.held == nil, now - lastContact >= Self.quietAfter {
            pencilActive = false
            if targets.current.id == "window" { log.notice("follow: Pencil quiet for \(Int(Self.quietAfter)) s; background window reads paused") }
        }
        if pencilActive { targets.followWindow() }  // keeps a window target's frame fresh while the Pencil is in use
        let silent = now - c.lastFrame
        if silent >= Self.idleLimit {
            // A logged-in client silent for 10 s is gone; end() releases any held button first.
            end(c, reason: "silent for \(String(format: "%.2f", silent)) s", closeFrame: true)
        } else if pen.held != nil, silent >= Self.silenceLimit {
            // Stuck-button watchdog: silent for 2 s mid-stroke loses the held button.
            pen.release(reason: "client \(c.id) silent for \(String(format: "%.2f", silent)) s")
        }
    }

    // MARK: Protocol

    private func handle(_ c: Client, _ data: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = msg["t"] as? String
        else {
            log.error("client \(c.id): frame is not a protocol message")
            if !c.authed { deny(c, why: "first frame is not a protocol message") }
            return
        }

        guard c.authed else {
            if t == "hello", let token = msg["token"] as? String, token == Settings.token {
                authenticate(c)
            } else {
                deny(c, why: t == "hello" ? "wrong token" : "first frame was not hello")
            }
            return
        }
        guard c === active else { return }

        // The first touch after a quiet spell waits for a fresh read of a window target's frame (a window may have moved
        // while nothing was reading it), and input behind it waits in order. Pings and everything else go on as usual.
        if c.held != nil, t != "ping" { c.held?.append(data); return }
        if t == "down", !pencilActive, targets.current.id == "window" {
            c.held = [data]
            log.notice("follow: first touch after a quiet spell; reading the window's frame before it")
            targets.refreshFrame { [weak self] in self?.releaseHeld(c) }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))  // never wait longer than this for a slow app
                self?.releaseHeld(c)
            }
            return
        }

        /// Wire numbers; anything missing or non-finite counts as absent.
        func num(_ key: String) -> Double? {
            guard let value = (msg[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        // A window target follows its window. Its frame is read in the background (never on this thread) and applied
        // when the answer comes back; the periodic tick keeps it fresh even with no hover.
        if t == "hover" { targets.followWindow() }
        // The Pencil coming back after 10 s away, while zoomed, shows where the iPad is looking.
        if t == "hover" || t == "down" || t == "move" || t == "up" {
            let now = ProcessInfo.processInfo.systemUptime
            if t == "hover" || t == "down", now - lastContact > 10 { outline.flash() }
            lastContact = now
            if !pencilActive {
                pencilActive = true
                if targets.current.id == "window" { log.notice("follow: Pencil active again; background window reads resumed") }
            }
        }
        let x = num("x"), y = num("y")
        let at = x.flatMap { x in y.map { y in targets.current.point(x: x, y: y) } }
        let pressure = num("p") ?? 0
        let tilt = (num("tx") ?? 0, num("ty") ?? 0)

        switch t {
        case "hover":
            if let at { pen.hover(at) }
        case "down":
            if let at, let x, let y {
                pen.down(at, page: CGPoint(x: x, y: y), target: targets.current, region: outline.region ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                         pressure: pressure, tilt: tilt, right: msg["b"] as? String == "right")
            }
        case "move":
            if let at { pen.move(at, pressure: pressure, tilt: tilt) }
        case "up":
            if let at { pen.up(at) } else { pen.release(reason: "up without coordinates") }
        case "target":
            targets.followWindow(force: true)  // a fresh read is on its way; a resize is pushed when it lands
            // Every request is answered with the target, even when nothing changed, so the page stays in sync.
            // Choosing a window talks to other apps, so its answer comes when that is done; the rest answer now.
            if let id = msg["id"] as? String, id == "window" {
                if msg["pick"] != nil {
                    // A pick that is not a whole number cannot name a listed window: nothing changes.
                    if let n = num("pick").flatMap({ Int(exactly: $0) }) {
                        targets.pick(window: n) { [weak self] _ in self?.replyTarget(c) }
                    } else {
                        log.error("client \(c.id): window pick is not a whole number")
                        replyTarget(c)
                    }
                } else {
                    targets.selectFrontWindow { [weak self] _ in self?.replyTarget(c) }
                }
            } else {
                if let id = msg["id"] as? String { targets.select(id) }
                replyTarget(c)
            }
        case "windows":
            // Built on the Accessibility queue; pings, hover and down keep flowing meanwhile, and if a newer request
            // overtakes this one only the newer is answered.
            targets.requestWindowList { [weak self] list in
                guard let self, !c.ended, c === active else { return }
                send(c, ["t": "windows", "list": list])
            }
        case "region":
            // The part of the target the iPad is zoomed to. Pencil coordinates already arrive mapped into it;
            // the Mac only draws it for a moment.
            if let rx = x, let ry = y, let rw = num("w"), let rh = num("h") {
                let w = min(max(rw, 0.01), 1), h = min(max(rh, 0.01), 1)
                outline.set(CGRect(x: min(max(rx, 0), 1 - w), y: min(max(ry, 0), 1 - h), width: w, height: h))
                projection.retarget()
                lastContact = ProcessInfo.processInfo.systemUptime  // the outline was just on show
            }
        case "show":
            // Project the target area onto the iPad as w x h pixel frames, or stop.
            if msg["on"] as? Bool == true {
                if let w = num("w").flatMap({ Int(exactly: $0.rounded()) }), let h = num("h").flatMap({ Int(exactly: $0.rounded()) }) {
                    projection.show(owner: c.id, w: w, h: h)
                }
            } else {
                projection.hide()
            }
        case "frame":
            if let n = num("ack"), n >= 0, n <= Double(UInt32.max) { projection.ack(UInt32(n)) }
        case "key":
            if let name = msg["name"] as? String { pen.key(name) }
        case "ping":
            send(c, ["t": "pong"])
        case "board":
            handleBoard(c, msg)
        case "ink":
            forwardInk(msg)
        case "hello":
            break
        default:
            log.debug("client \(c.id): unknown message \(t, privacy: .public)")
        }
    }

    /// The fresh frame is in (or the wait ran out): the touch that waited, and what came behind it, go through in order.
    private func releaseHeld(_ c: Client) {
        guard let held = c.held else { return }
        c.held = nil
        pencilActive = true
        for data in held where !c.ended { handle(c, data) }
    }

    private func replyTarget(_ c: Client) {
        guard !c.ended else { return }
        send(c, ["t": "target", "target": targets.current.json])
    }

    private func authenticate(_ c: Client) {
        if let old = active, old !== c {
            end(old, reason: "replaced by newer client \(c.id)", farewell: "replaced", closeFrame: true)
        }
        c.authed = true
        c.lastFrame = ProcessInfo.processInfo.systemUptime
        active = c
        log.notice("hello accepted: client \(c.id)")
        send(c, ["t": "hello", "screens": targets.screens.map(\.json), "target": targets.current.json])
        reportBoard(to: c)  // the page never relies on a remembered window state
    }

    private func deny(_ c: Client, why: String) {
        log.notice("hello denied: client \(c.id) (\(why, privacy: .public))")
        end(c, reason: "denied", farewell: "denied", closeFrame: true)
    }

    private func send(_ c: Client, _ msg: [String: Any]) {
        guard !c.ended else { return }
        write(c.conn, msg)
    }

    /// One projection frame: a 4-byte big-endian number, then the JPEG.
    private func sendBinary(_ c: Client, _ data: Data) {
        guard !c.ended else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        c.conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { log.error("frame send failed: \(error, privacy: .public)") }
        })
    }

    private func write(_ conn: NWConnection, _ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { log.error("send failed: \(error, privacy: .public)") }
        })
    }
}
