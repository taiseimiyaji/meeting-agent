import Foundation
import MeetingCore

public struct HealthResponse: Codable, Sendable { public let status: String; public let version: String }

public enum SummaryProgressState: String, Codable, Sendable {
    case notStarted = "not_started"
    case queued, running, retrying, completed, failed
}

public struct SummaryProgressResponse: Codable, Sendable, Equatable {
    public let state: SummaryProgressState
    public let retryCount: Int
    public let error: String?
    public let availableAt: Date?
    public init(state: SummaryProgressState, retryCount: Int = 0, error: String? = nil, availableAt: Date? = nil) {
        self.state = state; self.retryCount = retryCount; self.error = error; self.availableAt = availableAt
    }
}

public enum APICaptureStatus: String, Codable, Sendable { case idle, starting, capturing, stopping, failed }

public struct APICaptureSnapshot: Codable, Sendable, Equatable {
    public var status: APICaptureStatus
    public var meetingId: String?
    public var videoFrames: UInt64
    public var systemAudioRms: Double
    public var microphoneRms: Double
    public var error: String?

    public init(status: APICaptureStatus, meetingId: String? = nil, videoFrames: UInt64 = 0,
                systemAudioRms: Double = 0, microphoneRms: Double = 0, error: String? = nil) {
        self.status = status; self.meetingId = meetingId; self.videoFrames = videoFrames
        self.systemAudioRms = systemAudioRms; self.microphoneRms = microphoneRms; self.error = error
    }
}

struct StartCaptureBody: Decodable { var targetId: String? }
struct MeetingPage: Encodable { let items: [Meeting]; let nextCursor: String? }
struct APITimeline: Encodable { let transcript: [TranscriptEvent]; let screens: [APIScreenEvent] }
struct APIScreenEvent: Encodable {
    let id: String; let startedAtMs: Int64; let endedAtMs: Int64?; let imageUrl: String
    let ocr: String?; let description: String?; let analysisStatus: String
    init(_ value: ScreenEvent) {
        id = value.id; startedAtMs = value.timeRange.startedAtMs; endedAtMs = value.timeRange.endedAtMs
        imageUrl = "/api/screens/\(value.id)/image"; ocr = value.ocr; description = value.description
        analysisStatus = value.analysisStatus == .processing ? "running" : value.analysisStatus.rawValue
    }
}

public enum APIEvent: Encodable, Sendable {
    case capture(APICaptureSnapshot)
    case timelineChanged(meetingId: String)

    enum CodingKeys: String, CodingKey { case type, capture, meetingId }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .capture(let capture):
            try values.encode("capture", forKey: .type); try values.encode(capture, forKey: .capture)
        case .timelineChanged(let meetingId):
            try values.encode("timeline_changed", forKey: .type); try values.encode(meetingId, forKey: .meetingId)
        }
    }
}
