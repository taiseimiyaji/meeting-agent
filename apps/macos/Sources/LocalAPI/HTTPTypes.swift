import Foundation

public enum HTTPMethod: String, Sendable { case GET, POST, OPTIONS }

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var target: String
    public var headers: [String: String]
    public var body: Data

    public init(method: HTTPMethod, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.target = target
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public subscript(header name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var upgradesToWebSocket: Bool

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), upgradesToWebSocket: Bool = false) {
        self.status = status; self.headers = headers; self.body = body; self.upgradesToWebSocket = upgradesToWebSocket
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        json(status, value, encoder: .api)
    }

    static func json<T: Encodable>(_ status: Int, _ value: T, encoder: JSONEncoder) -> HTTPResponse {
        do {
            return .init(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: try encoder.encode(value))
        } catch {
            return .problem(500, "Response encoding failed")
        }
    }

    public static func problem(_ status: Int, _ message: String) -> HTTPResponse {
        .json(status, APIProblem(error: message))
    }
}

struct APIProblem: Codable { let error: String }

extension JSONEncoder {
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension HTTPResponse {
    var wireData: Data {
        let reasons = [101: "Switching Protocols", 200: "OK", 202: "Accepted", 204: "No Content",
                       400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 409: "Conflict", 500: "Internal Server Error"]
        var allHeaders = headers
        allHeaders["Content-Length"] = upgradesToWebSocket ? nil : String(body.count)
        allHeaders["Connection"] = upgradesToWebSocket ? "Upgrade" : "close"
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Response")\r\n"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8); data.append(body); return data
    }
}
