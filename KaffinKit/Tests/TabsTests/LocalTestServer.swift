import Foundation
import Network

/// Minimal HTTP server, so WebKit integration tests need no internet.
final class LocalTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalTestServer")

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self?.record(path)
                Self.respond(to: path, on: connection, queue: queue)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
            }
            listener.start(queue: queue)
        }
    }

    private let lock = NSLock()
    private var paths: [String] = []

    var requestedPaths: [String] { lock.withLock { paths } }

    private func record(_ path: String) {
        lock.withLock { paths.append(path) }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")! }

    deinit { listener.cancel() }

    private static func respond(to path: String, on connection: NWConnection, queue: DispatchQueue) {
        let body = Data(repeating: 120, count: 2048)
        switch path {
        case "/file", "/slow":
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                + "Content-Disposition: attachment; filename=\"report.bin\"\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let half = body.count / 2
            connection.send(content: Data(head.utf8) + body.prefix(half), completion: .idempotent)
            queue.asyncAfter(deadline: .now() + (path == "/slow" ? 1 : 0)) {
                connection.send(content: body.suffix(from: half), isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        case "/icon.png", "/favicon.ico":
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
            let head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + png, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        default:
            let html = switch path {
            case "/media", "/media?next":
                "<!doctype html><title>Media</title><audio id=a></audio><audio id=pageMuted muted></audio>"
            case "/iconpage":
                "<!doctype html><title>Icon</title><link rel=icon href=/icon.png><p>ok"
            case "/login":
                "<!doctype html><title>Login</title><form id=f action=/page onsubmit='return false'>"
                    + "<input id=u type=text name=user><input id=p type=password name=pass></form>"
            case "/framed":
                "<!doctype html><title>Framed</title><iframe src=/login></iframe>"
            default:
                "<!doctype html><title>Test Page</title><p>ok"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
