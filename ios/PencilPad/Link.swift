import Foundation
import Network

/// One WebSocket to the Mac, over a Bonjour service (Wi-Fi or Apple's direct link) or a host and port.
@MainActor
final class Link {
    enum Event {
        case open
        case text(String)
        case binary(Data)
        case closed(String)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var isOpen = false
    private var done = false
    private let conn: NWConnection

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // a Pencil sample goes out now, not after Nagle's wait
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        let ws = NWProtocolWebSocket.Options(.version13)
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024  // projection frames are JPEGs, well past the 64 KB the Mac accepts
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        conn = NWConnection(to: endpoint, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        conn.start(queue: .main)
    }

    private func changed(_ state: NWConnection.State) {
        guard !done else { return }
        switch state {
        case .ready:
            isOpen = true
            onEvent?(.open)
            receive()
        case .waiting(let error):
            finish("waiting: \(error)")  // no route, or refused: the session retries on its own clock
        case .failed(let error):
            finish("failed: \(error)")
        case .cancelled:
            finish("cancelled")
        default:
            break
        }
    }

    private func receive() {
        conn.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return }
                if let error {
                    self.finish("receive: \(error)")
                    return
                }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                guard let meta else {
                    self.finish("closed by the Mac")
                    return
                }
                switch meta.opcode {
                case .text:
                    if let data, let text = String(data: data, encoding: .utf8) { self.onEvent?(.text(text)) }
                case .binary:
                    if let data { self.onEvent?(.binary(data)) }
                case .close:
                    self.finish("close frame from the Mac")
                    return
                default:
                    break
                }
                self.receive()
            }
        }
    }

    func send(_ text: String) {
        guard isOpen, !done else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Ends it from this side with a close frame (so the Mac lets go of any held button at once), and says nothing more.
    func close() {
        guard !done else { return }
        done = true
        onEvent = nil
        conn.stateUpdateHandler = nil
        guard isOpen else {
            conn.cancel()
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        let conn = conn
        conn.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        // A close frame that never finishes (a Mac that has gone quiet) must not leave the connection open.
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.closeLimit) { conn.cancel() }
    }

    private func finish(_ why: String) {
        guard !done else { return }
        done = true
        conn.stateUpdateHandler = nil
        conn.cancel()
        let handler = onEvent
        onEvent = nil
        handler?(.closed(why))
    }
}
