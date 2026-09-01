import CryptoKit
import Foundation
import Security

public struct APICredentials: Sendable, Equatable {
    public let sessionToken: String
    public let csrfToken: String

    public init() {
        self.init(sessionToken: SecureToken.generate(), csrfToken: SecureToken.generate())
    }

    public init(sessionToken: String, csrfToken: String) {
        self.sessionToken = sessionToken; self.csrfToken = csrfToken
    }
}

enum SecureToken {
    static func generate(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct APISecurityPolicy: Sendable {
    public let credentials: APICredentials
    public let allowedHosts: Set<String>
    public let allowedOrigins: Set<String>

    public init(
        credentials: APICredentials,
        allowedHosts: Set<String> = ["127.0.0.1:8765", "localhost:8765"],
        allowedOrigins: Set<String> = ["http://127.0.0.1:8765", "http://localhost:8765", "http://localhost:5173", "http://127.0.0.1:5173"]
    ) {
        self.credentials = credentials; self.allowedHosts = allowedHosts; self.allowedOrigins = allowedOrigins
    }

    func validateTransportHeaders(_ request: HTTPRequest) -> HTTPResponse? {
        guard let host = request[header: "host"], allowedHosts.contains(host.lowercased()) else {
            return .problem(403, "Host is not allowed")
        }
        if let origin = request[header: "origin"], !allowedOrigins.contains(origin.lowercased()) {
            return .problem(403, "Origin is not allowed")
        }
        return nil
    }

    func validateAuthentication(_ request: HTTPRequest) -> HTTPResponse? {
        if let value = request[header: "authorization"], constantTimeEqual(value, credentials.sessionToken) { return nil }
        if let protocols = request[header: "sec-websocket-protocol"] {
            let values = protocols.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let prefix = "token."
            if values.contains("meeting-agent"),
               let encoded = values.first(where: { $0.hasPrefix(prefix) }).map({ String($0.dropFirst(prefix.count)) }),
               let candidate = Self.decodeBase64URL(encoded), constantTimeEqual(candidate, credentials.sessionToken) { return nil }
        }
        return .problem(401, "A valid session token is required")
    }

    private static func decodeBase64URL(_ encoded: String) -> String? {
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    func validateCSRF(_ request: HTTPRequest) -> HTTPResponse? {
        guard let token = request[header: "x-csrf-token"], constantTimeEqual(token, credentials.csrfToken) else {
            return .problem(403, "A valid CSRF token is required")
        }
        return nil
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}

func webSocketAccept(for key: String) -> String {
    let magic = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
    return Data(Insecure.SHA1.hash(data: magic)).base64EncodedString()
}
