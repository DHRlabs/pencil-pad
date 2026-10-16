import Foundation
import Network

/// Minimal GET server on 8710. Serves the web root only under /<token>/; everything else is 404.
@MainActor
final class HTTPServer {
    nonisolated static let port: NWEndpoint.Port = 8710

    private let root: URL?
    private var listener: NWListener?

    /// The bundled page when running as PencilPad.app, else the PENCILPAD_WEB folder.
    static func webRoot() -> URL? {
        var isDir: ObjCBool = false
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.path, isDirectory: &isDir), isDir.boolValue {
            return bundled
        }
        if let env = ProcessInfo.processInfo.environment["PENCILPAD_WEB"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return nil
    }

    init(root: URL?) {
        self.root = root?.standardizedFileURL.resolvingSymlinksInPath()
    }

    func start() {
        if let root {
            log.notice("http web root: \(root.path, privacy: .public)")
        } else {
            log.error("http: no web root (not bundled and PENCILPAD_WEB unset); every request is 404")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: Self.port)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: log.notice("http listening on port \(Self.port.rawValue)")
                case .failed(let error): log.error("http listener failed: \(error, privacy: .public)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated {
                    conn.start(queue: .main)
                    self?.read(conn, Data())
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.error("http listener could not start: \(error, privacy: .public)")
        }
    }

    private func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self?.respond(conn, head: buffer[..<end.lowerBound])
                } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                    conn.cancel()
                } else {
                    self?.read(conn, buffer)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, head: Data) {
        let requestLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let status: Int, type: String, body: Data
        if parts.count < 2 {
            (status, type, body) = (400, "text/plain; charset=utf-8", Data("Bad request\n".utf8))
        } else if parts[0] != "GET" {
            (status, type, body) = (405, "text/plain; charset=utf-8", Data("Method not allowed\n".utf8))
        } else if let file = lookup(String(parts[1])) {
            (status, type, body) = (200, file.type, file.data)
        } else {
            (status, type, body) = (404, "text/plain; charset=utf-8", Data("Not found\n".utf8))
        }
        log.debug("http \(status)")
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][status] ?? ""
        var response = Data("""
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: \(type)\r
            Content-Length: \(body.count)\r
            Cache-Control: no-cache\r
            Connection: close\r
            \r

            """.utf8)
        response.append(body)
        conn.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func lookup(_ target: String) -> (type: String, data: Data)? {
        guard let root else { return nil }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let prefix = "/\(Settings.token)/"
        guard path.hasPrefix(prefix), var relative = String(path.dropFirst(prefix.count)).removingPercentEncoding else {
            return nil
        }
        if relative.isEmpty || relative.hasSuffix("/") { relative += "index.html" }
        // No empty, dot, or dot-dot segments, no backslashes or NULs: nothing can climb out of the root.
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0.hasPrefix(".") }),
              !relative.contains("\\"), !relative.contains("\0")
        else { return nil }
        let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard file.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return (Self.contentType(file.pathExtension.lowercased()), data)
    }

    static func contentType(_ ext: String) -> String {
        switch ext {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "webmanifest": "application/manifest+json"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
