import Foundation
import Network

/// A minimal HTTP server on the loopback interface. It answers one request per connection.
final class CaptureServer {
    private let port: UInt16
    private let fontFamily: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "FigmaCapture.server")

    init(port: UInt16, fontFamily: String?) {
        self.port = port
        self.fontFamily = fontFamily
    }

    func start() {
        let parameters = NWParameters.tcp
        // Loopback only: the screen must not be readable from the local network.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: parameters, on: nwPort) else {
            print("FigmaCapture: can't listen on port \(port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("FigmaCapture: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
        print("FigmaCapture: ready on http://localhost:\(port)")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            // Figma plugin frames have the origin "null". Web pages have a real origin, so a site
            // open in the browser can't read the screen from localhost.
            let allowed = !request.lowercased().contains("origin:") || request.lowercased().contains("origin: null")
            guard allowed else {
                self?.respond(connection, status: "403 Forbidden", body: Data("Forbidden".utf8))
                return
            }
            switch path {
            case "/ping":
                self?.respond(connection, status: "200 OK", body: Data("{\"ok\":true}".utf8))
            case "/capture":
                DispatchQueue.main.async {
                    let body = ScreenCapture(fontFamily: self?.fontFamily).run()
                    self?.queue.async { self?.respond(connection, status: "200 OK", body: body) }
                }
            default:
                self?.respond(connection, status: "404 Not Found", body: Data("Not found".utf8))
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: null\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
