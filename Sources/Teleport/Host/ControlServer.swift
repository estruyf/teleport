import Foundation
import Network
import TeleportCore

/// A very small HTTP/1.1 server for the host's control endpoint (pairing, tokens).
/// Only JSON in and out, one request per connection.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: Data) async -> (status: Int, body: Data)

    private var listener: NWListener?
    private let handler: Handler
    private let queue = DispatchQueue(label: "teleport.control")

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: Int) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { Log.error("control server failed: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
        Log.info("control endpoint on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let error {
                    Log.warn("control read failed: \(error)")
                    connection.cancel()
                    return
                }
                if let request = Self.parse(buffer) {
                    Task {
                        let (status, body) = await self.handler(request.method, request.path, request.body)
                        self.respond(connection, status: status, body: body)
                    }
                } else if isComplete || buffer.count > 1_000_000 {
                    self.respond(connection, status: 400, body: Data("{\"error\":\"bad request\"}".utf8))
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 410: "Gone", 429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nServer: Teleport\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Returns nil until the whole request (headers plus Content-Length body) has arrived.
    private static func parse(_ data: Data) -> (method: String, path: String, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: data[data.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data[bodyStart ..< bodyStart + contentLength]
        return (String(parts[0]), String(parts[1]), Data(body))
    }
}
