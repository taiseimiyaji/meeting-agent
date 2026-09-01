@preconcurrency import Network
import Foundation

public final class LocalAPIServer: @unchecked Sendable {
    public let credentials: APICredentials
    public let host = "127.0.0.1"
    public let port: UInt16

    private let router: APIRouter
    private let queue = DispatchQueue(label: "meeting-agent.local-api", qos: .userInitiated)
    private let hub: WebSocketHub
    private let lock = NSLock()
    private var listener: NWListener?

    public init(repository: any MeetingAPIRepository, capture: any CaptureAPIControlling,
                port: UInt16 = 8765, credentials: APICredentials = .init(), allowedOrigins: Set<String>? = nil) {
        self.port = port; self.credentials = credentials
        let hub = WebSocketHub(); self.hub = hub
        let hosts = Set(["127.0.0.1:\(port)", "localhost:\(port)"])
        let policy = APISecurityPolicy(credentials: credentials, allowedHosts: hosts,
                                       allowedOrigins: allowedOrigins ?? ["http://127.0.0.1:\(port)", "http://localhost:\(port)", "http://127.0.0.1:5173", "http://localhost:5173"])
        router = APIRouter(repository: repository, capture: capture, security: policy,
                           publish: { event in
                               guard let data = try? JSONEncoder.api.encode(event),
                                     let text = String(data: data, encoding: .utf8) else { return }
                               await hub.broadcast(text)
                           })
    }

    public func start() throws {
        try lock.withLock {
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("Meeting Agent Local API failed: %@", error.localizedDescription) }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    public func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
        Task { await hub.closeAll() }
    }

    public func publish(_ event: APIEvent) async {
        guard let data = try? JSONEncoder.api.encode(event), let text = String(data: data, encoding: .utf8) else { return }
        await hub.broadcast(text)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(connection: connection, accumulated: Data())
    }

    private func receiveHTTPRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated; if let data { buffer.append(data) }
            if let request = HTTPParser.parse(buffer) {
                Task {
                    let response = await router.route(request)
                    connection.send(content: response.wireData, completion: .contentProcessed { sendError in
                        guard sendError == nil, response.upgradesToWebSocket else { connection.cancel(); return }
                        let client = WebSocketClient(connection: connection, hub: self.hub)
                        Task { await self.hub.add(client); client.receive() }
                    })
                }
            } else if complete || error != nil || buffer.count > 1_048_576 {
                connection.cancel()
            } else {
                self.receiveHTTPRequest(connection: connection, accumulated: buffer)
            }
        }
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let head = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestLine = first.split(separator: " ")
        guard requestLine.count == 3, let method = HTTPMethod(rawValue: String(requestLine[0])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerRange.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= 1_048_576, data.count >= bodyStart + length else { return nil }
        return HTTPRequest(method: method, target: String(requestLine[1]), headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

private actor WebSocketHub {
    private var clients: [UUID: WebSocketClient] = [:]
    func add(_ client: WebSocketClient) { clients[client.id] = client }
    func remove(_ id: UUID) { clients[id] = nil }
    func broadcast(_ text: String) { for client in clients.values { client.send(text) } }
    func closeAll() { for client in clients.values { client.close() }; clients.removeAll() }
}

private final class WebSocketClient: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let hub: WebSocketHub

    init(connection: NWConnection, hub: WebSocketHub) { self.connection = connection; self.hub = hub }

    func send(_ text: String) {
        connection.send(content: Self.frame(opcode: 0x1, payload: Data(text.utf8)), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if complete || error != nil || data?.first.map({ $0 & 0x0F == 0x8 }) == true { self.close() }
            else { self.receive() }
        }
    }

    func close() {
        connection.cancel()
        Task { await hub.remove(id) }
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var result = Data([0x80 | opcode])
        if payload.count < 126 { result.append(UInt8(payload.count)) }
        else if payload.count <= Int(UInt16.max) {
            result.append(126); var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        } else {
            result.append(127); var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        }
        result.append(payload); return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
