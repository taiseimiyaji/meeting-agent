import Foundation
import MeetingCapture
import MeetingCore

public struct APIRouter: Sendable {
    private let repository: any MeetingAPIRepository
    private let capture: any CaptureAPIControlling
    private let security: APISecurityPolicy
    private let version: String
    private let webRoot: URL?
    private let publish: @Sendable (APIEvent) async -> Void

    public init(repository: any MeetingAPIRepository, capture: any CaptureAPIControlling,
                security: APISecurityPolicy, version: String = "0.1.0",
                webRoot: URL? = nil,
                publish: @escaping @Sendable (APIEvent) async -> Void = { _ in }) {
        self.repository = repository; self.capture = capture; self.security = security; self.version = version
        self.webRoot = webRoot?.standardizedFileURL
        self.publish = publish
    }

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = security.validateTransportHeaders(request) { return rejection }
        if request.method == .OPTIONS { return preflight(request) }

        let components = URLComponents(string: request.target)
        let path = components?.path ?? request.target
        guard path.hasPrefix("/api/") else { return staticWebResponse(path: path, request: request) }
        let route = String(path.dropFirst(5))
        if route == "health", request.method == .GET {
            return withCORS(.json(200, HealthResponse(status: "ok", version: version)), request: request)
        }
        if let rejection = security.validateAuthentication(request) { return withCORS(rejection, request: request) }
        if request.method == .POST, let rejection = security.validateCSRF(request) { return withCORS(rejection, request: request) }

        do {
            let response = try await authenticatedRoute(route, components: components, request: request)
            return withCORS(response, request: request)
        } catch CaptureError.alreadyRunning {
            return withCORS(.problem(409, "Capture is already active"), request: request)
        } catch CaptureError.notRunning {
            return withCORS(.problem(409, "Capture is not active"), request: request)
        } catch {
            return withCORS(.problem(500, error.localizedDescription), request: request)
        }
    }

    private func staticWebResponse(path: String, request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET, let webRoot else { return .problem(404, "Route not found") }
        let relative = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        guard !relative.contains(".."), !relative.contains("\\") else { return .problem(404, "Route not found") }
        var candidate = webRoot.appendingPathComponent(relative).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) || isDirectory.boolValue {
            candidate = webRoot.appendingPathComponent("index.html").standardizedFileURL
        }
        let rootPath = webRoot.path.hasSuffix("/") ? webRoot.path : webRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath), let data = try? Data(contentsOf: candidate) else {
            return .problem(404, "Web UI is not bundled")
        }
        let contentTypes = [
            "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
            "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "ico": "image/x-icon", "woff2": "font/woff2"
        ]
        return .init(status: 200, headers: [
            "Content-Type": contentTypes[candidate.pathExtension.lowercased()] ?? "application/octet-stream",
            "Cache-Control": candidate.lastPathComponent == "index.html" ? "no-store" : "public, max-age=31536000, immutable",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'self'; connect-src 'self' ws://127.0.0.1:8765 ws://localhost:8765; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; script-src 'self'"
        ], body: data)
    }

    private func authenticatedRoute(_ route: String, components: URLComponents?, request: HTTPRequest) async throws -> HTTPResponse {
        if route == "capture", request.method == .GET { return .json(200, await capture.snapshot()) }
        if route == "capture/start", request.method == .POST {
            let input = request.body.isEmpty ? StartCaptureBody(targetId: nil) : try JSONDecoder().decode(StartCaptureBody.self, from: request.body)
            try await capture.start(targetID: input.targetId)
            let snapshot = await capture.snapshot(); await publish(.capture(snapshot)); return .json(202, snapshot)
        }
        if route == "capture/stop", request.method == .POST {
            try await capture.stop()
            let snapshot = await capture.snapshot(); await publish(.capture(snapshot)); return .json(202, snapshot)
        }
        if route == "meetings", request.method == .GET {
            let limit = min(max(queryInt("limit", components) ?? 20, 1), 100)
            let cursor = query("cursor", components).flatMap(ISO8601DateFormatter().date)
            let values = try repository.meetings(limit: limit + 1, before: cursor)
            let page = Array(values.prefix(limit))
            let next = values.count > limit ? page.last.map { ISO8601DateFormatter().string(from: $0.startedAt) } : nil
            return .json(200, MeetingPage(items: page, nextCursor: next))
        }
        if route == "events", request.method == .GET { return webSocketUpgrade(request) }

        let screenPieces = route.split(separator: "/").map(String.init)
        if screenPieces.count == 3, screenPieces[0] == "screens", screenPieces[2] == "image", request.method == .GET {
            guard UUID(uuidString: screenPieces[1]) != nil else { return .problem(404, "Screen not found") }
            guard let image = try repository.screenImage(id: screenPieces[1]) else { return .problem(404, "Screen not found") }
            return .init(status: 200, headers: ["Content-Type": image.contentType, "Cache-Control": "no-store"], body: image.data)
        }

        let pieces = route.split(separator: "/").map(String.init)
        guard pieces.first == "meetings", pieces.count >= 2, UUID(uuidString: pieces[1]) != nil else {
            return .problem(404, "Route not found")
        }
        let meetingID = pieces[1]
        if pieces.count == 2, request.method == .GET {
            guard let meeting = try repository.meeting(id: meetingID) else { return .problem(404, "Meeting not found") }
            return .json(200, meeting)
        }
        if pieces.count == 3, pieces[2] == "timeline", request.method == .GET {
            guard let timeline = try repository.timeline(meetingId: meetingID) else { return .problem(404, "Meeting not found") }
            let after = Int64(query("afterMs", components) ?? "") ?? 0
            let limit = min(max(queryInt("limit", components) ?? 200, 1), 1_000)
            let transcripts = timeline.transcripts.filter { $0.timeRange.startedAtMs >= after }.prefix(limit)
            let screens = timeline.screens.filter { $0.timeRange.startedAtMs >= after }.prefix(limit)
            return .json(200, APITimeline(transcript: Array(transcripts), screens: screens.map(APIScreenEvent.init)))
        }
        if pieces.count == 3, pieces[2] == "summary", request.method == .GET {
            guard try repository.meeting(id: meetingID) != nil else { return .problem(404, "Meeting not found") }
            guard let summary = try repository.summary(meetingId: meetingID) else { return .problem(404, "Summary not found") }
            return .json(200, summary)
        }
        if pieces.count == 4, pieces[2] == "summary", pieces[3] == "status", request.method == .GET {
            guard try repository.meeting(id: meetingID) != nil else { return .problem(404, "Meeting not found") }
            return .json(200, try repository.summaryProgress(meetingId: meetingID))
        }
        if pieces.count == 4, pieces[2] == "transcription", pieces[3] == "status", request.method == .GET {
            guard try repository.meeting(id: meetingID) != nil else { return .problem(404, "Meeting not found") }
            return .json(200, try repository.transcriptionProgress(meetingId: meetingID))
        }
        if pieces.count == 3, ["summarize", "transcribe", "export"].contains(pieces[2]), request.method == .POST {
            guard try repository.meeting(id: meetingID) != nil else { return .problem(404, "Meeting not found") }
            try repository.enqueue(meetingId: meetingID, kind: pieces[2]); return .json(202, APIProblem(error: "queued"))
        }
        return .problem(404, "Route not found")
    }

    private func webSocketUpgrade(_ request: HTTPRequest) -> HTTPResponse {
        guard request[header: "upgrade"]?.lowercased() == "websocket",
              request[header: "connection"]?.lowercased().contains("upgrade") == true,
              request[header: "sec-websocket-version"] == "13",
              let key = request[header: "sec-websocket-key"] else { return .problem(400, "Invalid WebSocket upgrade") }
        var headers = ["Upgrade": "websocket", "Sec-WebSocket-Accept": webSocketAccept(for: key)]
        if request[header: "sec-websocket-protocol"]?.split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("meeting-agent") == true {
            headers["Sec-WebSocket-Protocol"] = "meeting-agent"
        }
        return .init(status: 101, headers: headers, upgradesToWebSocket: true)
    }

    private func preflight(_ request: HTTPRequest) -> HTTPResponse {
        guard let origin = request[header: "origin"], security.allowedOrigins.contains(origin.lowercased()) else {
            return .problem(403, "Origin is not allowed")
        }
        return .init(status: 204, headers: [
            "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, X-CSRF-Token", "Vary": "Origin"
        ])
    }

    private func withCORS(_ response: HTTPResponse, request: HTTPRequest) -> HTTPResponse {
        guard let origin = request[header: "origin"], security.allowedOrigins.contains(origin.lowercased()) else { return response }
        var value = response; value.headers["Access-Control-Allow-Origin"] = origin; value.headers["Vary"] = "Origin"; return value
    }

    private func query(_ name: String, _ components: URLComponents?) -> String? {
        components?.queryItems?.first(where: { $0.name == name })?.value
    }
    private func queryInt(_ name: String, _ components: URLComponents?) -> Int? { query(name, components).flatMap(Int.init) }
}
