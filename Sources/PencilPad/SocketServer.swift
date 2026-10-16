import Foundation
import Network

@MainActor
final class Client {
    let id: Int
    let conn: NWConnection
    var authed = false
    var denied = false
    var ended = false
    let opened = ProcessInfo.processInfo.systemUptime
    var lastFrame = ProcessInfo.processInfo.systemUptime

    init(id: Int, conn: NWConnection) {
        self.id = id
        self.conn = conn
    }
}

/// WebSocket on 8711. Speaks the AGENTS.md protocol; one authenticated client at a time, newest wins.
@MainActor
final class SocketServer {
    nonisolated static let port: NWEndpoint.Port = 8711
    static let silenceLimit: TimeInterval = 2
    static let helloLimit: TimeInterval = 10

    private let targets: Targets
    private let pen: Pen
    private var listener: NWListener?
    private var watchdog: DispatchSourceTimer?
    private var clients: [Int: Client] = [:]
    private var nextID = 1
    private(set) var active: Client?

    init(targets: Targets, pen: Pen) {
        self.targets = targets
        self.pen = pen
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
                if !c.ended && !c.denied { self.receive(c) }
            }
        }
    }

    /// The only way a client ends. If it is the active client, its held button is released first.
    private func end(_ c: Client, reason: String, closeFrame: Bool) {
        guard !c.ended else { return }
        c.ended = true
        clients[c.id] = nil
        if active === c {
            active = nil
            pen.release(reason: "client \(c.id) \(reason)")
        }
        log.notice("client \(c.id) closed: \(reason, privacy: .public)")
        let conn = c.conn
        conn.stateUpdateHandler = nil  // breaks the Client <-> handler cycle; the clients dictionary was the owner
        // A close frame only goes out on a finished WebSocket handshake; otherwise it would queue forever.
        guard closeFrame, case .ready = conn.state else {
            conn.cancel()
            return
        }
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
        for c in Array(clients.values) where !c.authed && now - c.opened >= Self.helloLimit {
            end(c, reason: "no valid hello within \(Int(Self.helloLimit)) s", closeFrame: true)
        }
        // Stuck-button watchdog: an active client silent for 2 s loses its held button.
        if let c = active, pen.held != nil, now - c.lastFrame >= Self.silenceLimit {
            pen.release(reason: "client \(c.id) silent for \(String(format: "%.2f", now - c.lastFrame)) s")
        }
    }

    // MARK: Protocol

    private func handle(_ c: Client, _ data: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = msg["t"] as? String
        else {
            log.error("client \(c.id): frame is not a protocol message")
            if !c.authed { deny(c, why: "first frame is not JSON") }
            return
        }

        guard c.authed else {
            if t == "hello", let token = msg["token"] as? String, token == Settings.token {
                authenticate(c)
            } else {
                deny(c, why: t == "hello" ? "wrong token" : "first frame was \(t), not hello")
            }
            return
        }
        guard c === active else { return }

        func num(_ key: String) -> Double? { (msg[key] as? NSNumber)?.doubleValue }
        func point() -> CGPoint? {
            guard let x = num("x"), let y = num("y") else { return nil }
            return targets.current.point(x: x, y: y)
        }
        let pressure = num("p") ?? 0
        let tilt = (num("tx") ?? 0, num("ty") ?? 0)

        switch t {
        case "hover":
            if let at = point() { pen.hover(at) }
        case "down":
            if let at = point() { pen.down(at, pressure: pressure, tilt: tilt, right: msg["b"] as? String == "right") }
        case "move":
            if let at = point() { pen.move(at, pressure: pressure, tilt: tilt) }
        case "up":
            if let at = point() { pen.up(at) } else { pen.release(reason: "up without coordinates") }
        case "target":
            if let id = msg["id"] as? String { targets.select(id) }
            send(c, ["t": "target", "target": targets.current.json])  // reply even when unchanged, so the page stays in sync
        case "key":
            if let name = msg["name"] as? String { pen.key(name) }
        case "ping", "hello":
            break
        default:
            log.debug("client \(c.id): unknown message \(t, privacy: .public)")
        }
    }

    private func authenticate(_ c: Client) {
        if let old = active, old !== c {
            end(old, reason: "replaced by newer client \(c.id)", closeFrame: true)
        }
        c.authed = true
        c.lastFrame = ProcessInfo.processInfo.systemUptime
        active = c
        log.notice("hello accepted: client \(c.id)")
        send(c, ["t": "hello", "screens": targets.screens.map(\.json), "target": targets.current.json])
    }

    private func deny(_ c: Client, why: String) {
        guard !c.denied else { return }
        c.denied = true
        log.notice("hello denied: client \(c.id) (\(why, privacy: .public))")
        send(c, ["t": "denied"]) { [weak self] in
            self?.end(c, reason: "denied", closeFrame: true)
        }
    }

    private func send(_ c: Client, _ msg: [String: Any], then: (@MainActor @Sendable () -> Void)? = nil) {
        guard !c.ended, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            MainActor.assumeIsolated {
                if let error { log.error("client \(c.id): send failed: \(error, privacy: .public)") }
                then?()
            }
        })
    }
}
