import Foundation
import MeetingCore
import XCTest
@testable import LocalAPI

final class APIRouterTests: XCTestCase {
    private let credentials = APICredentials(sessionToken: "session-secret", csrfToken: "csrf-secret")

    func testHealthRequiresValidHostButNotAuthentication() async throws {
        let fixture = try Fixture(credentials: credentials)
        let health = await fixture.router.route(.init(method: .GET, target: "/api/health", headers: ["Host": "127.0.0.1:8765"]))
        let badHost = await fixture.router.route(.init(method: .GET, target: "/api/health", headers: ["Host": "attacker.example"]))
        XCTAssertEqual(health.status, 200); XCTAssertEqual(badHost.status, 403)
    }

    func testBundledWebUIAndSPAPathsAreServedWithoutExposingOtherFiles() async throws {
        let webRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: webRoot) }
        try Data("<html>meeting agent</html>".utf8).write(to: webRoot.appendingPathComponent("index.html"))
        try Data("console.log('ok')".utf8).write(to: webRoot.appendingPathComponent("app.js"))
        let fixture = try Fixture(credentials: credentials, webRoot: webRoot)

        let index = await fixture.router.route(request(.GET, "/", authenticated: false, origin: nil))
        let spa = await fixture.router.route(request(.GET, "/meetings/example", authenticated: false, origin: nil))
        let script = await fixture.router.route(request(.GET, "/app.js", authenticated: false, origin: nil))
        let traversal = await fixture.router.route(request(.GET, "/../secret", authenticated: false, origin: nil))
        XCTAssertEqual(index.status, 200)
        XCTAssertEqual(spa.body, index.body)
        XCTAssertEqual(script.headers["Content-Type"], "text/javascript; charset=utf-8")
        XCTAssertEqual(traversal.status, 404)
    }

    func testAuthenticationOriginAndCSRFEnforced() async throws {
        let fixture = try Fixture(credentials: credentials)
        let unauthenticated = await fixture.router.route(request(.GET, "/api/capture", authenticated: false))
        let evilOrigin = await fixture.router.route(request(.GET, "/api/capture", origin: "https://evil.example"))
        let noCSRF = await fixture.router.route(request(.POST, "/api/capture/start"))
        XCTAssertEqual(unauthenticated.status, 401); XCTAssertEqual(evilOrigin.status, 403); XCTAssertEqual(noCSRF.status, 403)
        let accepted = await fixture.router.route(request(.POST, "/api/capture/start", csrf: true, body: Data("{\"targetId\":\"42\"}".utf8)))
        XCTAssertEqual(accepted.status, 202)
        let snapshot = await fixture.capture.snapshot(); let target = await fixture.capture.lastTarget
        XCTAssertEqual(snapshot.status, .capturing); XCTAssertEqual(target, "42")
    }

    func testMeetingTimelineAndMissingSummaryRoutes() async throws {
        let fixture = try Fixture(credentials: credentials); let id = UUID().uuidString
        try fixture.store.save(Meeting(id: id, title: "Design", status: .completed))
        try fixture.store.save(TranscriptEvent(meetingId: id, timeRange: .init(startedAtMs: 10), speaker: .remote, text: "hello", source: .system, isFinal: true))
        let detail = await fixture.router.route(request(.GET, "/api/meetings/\(id)")); XCTAssertEqual(detail.status, 200)
        let timeline = await fixture.router.route(request(.GET, "/api/meetings/\(id)/timeline?afterMs=0&limit=20"))
        XCTAssertEqual(timeline.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: timeline.body) as? [String: Any])
        XCTAssertEqual((json["transcript"] as? [Any])?.count, 1); XCTAssertNotNil(json["screens"])
        let summary = await fixture.router.route(request(.GET, "/api/meetings/\(id)/summary")); XCTAssertEqual(summary.status, 404)
        let progress = await fixture.router.route(request(.GET, "/api/meetings/\(id)/summary/status"))
        XCTAssertEqual(progress.status, 200)
        let progressJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: progress.body) as? [String: Any])
        XCTAssertEqual(progressJSON["state"] as? String, "not_started")
        try fixture.store.enqueue(AnalysisJob(id: "summary-job", meetingId: id, kind: "summarize", status: .processing, retryCount: 1))
        let running = await fixture.router.route(request(.GET, "/api/meetings/\(id)/summary/status"))
        let runningJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: running.body) as? [String: Any])
        XCTAssertEqual(runningJSON["state"] as? String, "running")
        XCTAssertEqual(runningJSON["retryCount"] as? Int, 1)
    }

    func testWebSocketContractAndReconnectDoNotChangeCapture() async throws {
        let fixture = try Fixture(credentials: credentials); var websocket = request(.GET, "/api/events")
        websocket.headers["authorization"] = nil; websocket.headers["upgrade"] = "websocket"; websocket.headers["connection"] = "Upgrade"
        websocket.headers["sec-websocket-version"] = "13"; websocket.headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ=="
        websocket.headers["sec-websocket-protocol"] = "meeting-agent, token.c2Vzc2lvbi1zZWNyZXQ"
        let first = await fixture.router.route(websocket); let second = await fixture.router.route(websocket)
        XCTAssertEqual(first.status, 101); XCTAssertEqual(second.status, 101)
        XCTAssertEqual(first.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertEqual(first.headers["Sec-WebSocket-Protocol"], "meeting-agent")
        let starts = await fixture.capture.startCount; let state = await fixture.capture.snapshot()
        XCTAssertEqual(starts, 0); XCTAssertEqual(state.status, .idle)
    }

    func testScreenImageIsServedOnlyFromEvidenceRoot() async throws {
        let fixture = try Fixture(credentials: credentials); let meetingID = UUID().uuidString
        try fixture.store.save(Meeting(id: meetingID, status: .completed))
        let imageID = UUID().uuidString; let imageURL = fixture.evidenceRoot.appendingPathComponent("frame.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: imageURL)
        try fixture.store.save(ScreenEvent(id: imageID, meetingId: meetingID, timeRange: .init(startedAtMs: 0), imagePath: "frame.jpg"))
        let image = await fixture.router.route(request(.GET, "/api/screens/\(imageID)/image"))
        XCTAssertEqual(image.status, 200); XCTAssertEqual(image.headers["Content-Type"], "image/jpeg")

        let escapedID = UUID().uuidString
        try fixture.store.save(ScreenEvent(id: escapedID, meetingId: meetingID, timeRange: .init(startedAtMs: 1), imagePath: "../secret.jpg"))
        let escaped = await fixture.router.route(request(.GET, "/api/screens/\(escapedID)/image"))
        XCTAssertNotEqual(escaped.status, 200)
    }

    private func request(_ method: HTTPMethod, _ target: String, authenticated: Bool = true, csrf: Bool = false,
                         origin: String? = "http://localhost:5173", body: Data = Data()) -> HTTPRequest {
        var headers = ["Host": "127.0.0.1:8765"]
        if authenticated { headers["Authorization"] = credentials.sessionToken }
        if csrf { headers["X-CSRF-Token"] = credentials.csrfToken }; if let origin { headers["Origin"] = origin }
        return .init(method: method, target: target, headers: headers, body: body)
    }
}

private struct Fixture {
    let store: MeetingStore; let evidenceRoot: URL; let capture = MockCaptureController(); let router: APIRouter
    init(credentials: APICredentials, webRoot: URL? = nil) throws {
        store = try MeetingStore(path: ":memory:")
        evidenceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try LocalMeetingRepository(store: store, evidenceRoot: evidenceRoot)
        router = APIRouter(repository: repository, capture: capture, security: .init(credentials: credentials), webRoot: webRoot)
    }
}
private actor MockCaptureController: CaptureAPIControlling {
    private var state = APICaptureSnapshot(status: .idle); private(set) var lastTarget: String?; private(set) var startCount = 0
    func snapshot() async -> APICaptureSnapshot { state }
    func start(targetID: String?) async throws { startCount += 1; lastTarget = targetID; state.status = .capturing }
    func stop() async throws { state.status = .idle }
}
