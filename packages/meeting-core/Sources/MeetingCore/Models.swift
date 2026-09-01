import Foundation

public struct TimeRange: Codable, Equatable, Sendable {
    public var startedAtMs: Int64
    public var endedAtMs: Int64?

    public init(startedAtMs: Int64, endedAtMs: Int64? = nil) {
        precondition(startedAtMs >= 0, "Capture time cannot be negative")
        precondition(endedAtMs.map { $0 >= startedAtMs } ?? true, "End must not precede start")
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
    }

    public func overlap(with other: TimeRange) -> Int64 {
        let end = min(endedAtMs ?? startedAtMs, other.endedAtMs ?? other.startedAtMs)
        return max(0, end - max(startedAtMs, other.startedAtMs))
    }
}

public enum MeetingStatus: String, Codable, CaseIterable, Sendable {
    case idle, capturing, finalizing, analyzing, completed, interrupted, failed, partiallyCompleted = "partially_completed"
}

public enum Speaker: String, Codable, Sendable { case `self`, remote, unknown }
public enum AudioSource: String, Codable, Sendable {
    case microphone
    case system = "system_audio"
    case imported
}
public enum ScreenRelation: String, Codable, Sendable {
    case visibleDuringSpeech = "visible_during_speech"
    case previouslyVisible = "previously_visible"
    case explicitlyReferenced = "explicitly_referenced"
}

public struct Meeting: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var captureClockOrigin: Date
    public var status: MeetingStatus

    public init(id: String = UUID().uuidString, title: String? = nil, startedAt: Date = Date(), endedAt: Date? = nil, captureClockOrigin: Date? = nil, status: MeetingStatus = .idle) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.captureClockOrigin = captureClockOrigin ?? startedAt; self.status = status
    }
}

public struct ScreenReference: Codable, Equatable, Sendable {
    public var screenId: String
    public var relation: ScreenRelation
    public var overlapMs: Int64?
    public var confidence: Double?
    public var provider: String?

    public init(screenId: String, relation: ScreenRelation, overlapMs: Int64? = nil, confidence: Double? = nil, provider: String? = nil) {
        precondition(confidence.map { (0...1).contains($0) } ?? true)
        self.screenId = screenId; self.relation = relation; self.overlapMs = overlapMs
        self.confidence = confidence; self.provider = provider
    }
}

public struct TranscriptEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var meetingId: String
    public var revision: Int
    public var timeRange: TimeRange
    public var speaker: Speaker
    public var text: String
    public var source: AudioSource
    public var isFinal: Bool
    public var screenRefs: [ScreenReference]

    public init(id: String = UUID().uuidString, meetingId: String, revision: Int = 1, timeRange: TimeRange, speaker: Speaker = .unknown, text: String, source: AudioSource, isFinal: Bool = false, screenRefs: [ScreenReference] = []) {
        precondition(revision > 0)
        self.id = id; self.meetingId = meetingId; self.revision = revision; self.timeRange = timeRange
        self.speaker = speaker; self.text = text; self.source = source; self.isFinal = isFinal; self.screenRefs = screenRefs
    }

    enum CodingKeys: String, CodingKey { case id, meetingId, revision, startedAtMs, endedAtMs, type, speaker, text, source, isFinal, screenRefs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); meetingId = try c.decode(String.self, forKey: .meetingId)
        revision = try c.decode(Int.self, forKey: .revision)
        timeRange = TimeRange(startedAtMs: try c.decode(Int64.self, forKey: .startedAtMs), endedAtMs: try c.decodeIfPresent(Int64.self, forKey: .endedAtMs))
        speaker = try c.decode(Speaker.self, forKey: .speaker); text = try c.decode(String.self, forKey: .text)
        source = try c.decode(AudioSource.self, forKey: .source); isFinal = try c.decode(Bool.self, forKey: .isFinal)
        screenRefs = try c.decodeIfPresent([ScreenReference].self, forKey: .screenRefs) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(meetingId, forKey: .meetingId); try c.encode(revision, forKey: .revision)
        try c.encode(timeRange.startedAtMs, forKey: .startedAtMs); try c.encodeIfPresent(timeRange.endedAtMs, forKey: .endedAtMs)
        try c.encode("speech", forKey: .type); try c.encode(speaker, forKey: .speaker); try c.encode(text, forKey: .text)
        try c.encode(source, forKey: .source); try c.encode(isFinal, forKey: .isFinal); try c.encode(screenRefs, forKey: .screenRefs)
    }
}

public enum ScreenAnalysisStatus: String, Codable, Sendable { case pending, processing, completed, failed }

public struct ScreenEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var meetingId: String
    public var timeRange: TimeRange
    public var imagePath: String
    public var ocr: String?
    public var description: String?
    public var analysisStatus: ScreenAnalysisStatus

    public init(id: String = UUID().uuidString, meetingId: String, timeRange: TimeRange, imagePath: String, ocr: String? = nil, description: String? = nil, analysisStatus: ScreenAnalysisStatus = .pending) {
        self.id = id; self.meetingId = meetingId; self.timeRange = timeRange; self.imagePath = imagePath
        self.ocr = ocr; self.description = description; self.analysisStatus = analysisStatus
    }

    enum CodingKeys: String, CodingKey { case id, meetingId, startedAtMs, endedAtMs, type, imagePath, ocr, description, analysisStatus }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); meetingId = try c.decode(String.self, forKey: .meetingId)
        timeRange = TimeRange(startedAtMs: try c.decode(Int64.self, forKey: .startedAtMs), endedAtMs: try c.decodeIfPresent(Int64.self, forKey: .endedAtMs))
        imagePath = try c.decode(String.self, forKey: .imagePath); ocr = try c.decodeIfPresent(String.self, forKey: .ocr)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        analysisStatus = try c.decodeIfPresent(ScreenAnalysisStatus.self, forKey: .analysisStatus) ?? .pending
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(meetingId, forKey: .meetingId)
        try c.encode(timeRange.startedAtMs, forKey: .startedAtMs); try c.encodeIfPresent(timeRange.endedAtMs, forKey: .endedAtMs)
        try c.encode("screen_change", forKey: .type); try c.encode(imagePath, forKey: .imagePath)
        try c.encodeIfPresent(ocr, forKey: .ocr); try c.encodeIfPresent(description, forKey: .description); try c.encode(analysisStatus, forKey: .analysisStatus)
    }
}

public struct Timeline: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var meeting: Meeting
    public var transcripts: [TranscriptEvent]
    public var screens: [ScreenEvent]
    public init(schemaVersion: Int = 1, meeting: Meeting, transcripts: [TranscriptEvent], screens: [ScreenEvent]) {
        self.schemaVersion = schemaVersion; self.meeting = meeting; self.transcripts = transcripts; self.screens = screens
    }
}

public struct SummaryItem: Codable, Equatable, Sendable {
    public var text: String
    public var evidenceIds: [String]
    public var assignee: String?
    public var dueAt: Date?

    public init(text: String, evidenceIds: [String] = [], assignee: String? = nil, dueAt: Date? = nil) {
        self.text = text; self.evidenceIds = evidenceIds; self.assignee = assignee; self.dueAt = dueAt
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public var summary: String
    public var decisions: [SummaryItem]
    public var actionItems: [SummaryItem]
    public var openQuestions: [SummaryItem]
    public var topics: [String]

    public init(
        summary: String,
        decisions: [SummaryItem] = [],
        actionItems: [SummaryItem] = [],
        openQuestions: [SummaryItem] = [],
        topics: [String] = []
    ) {
        self.summary = summary; self.decisions = decisions; self.actionItems = actionItems
        self.openQuestions = openQuestions; self.topics = topics
    }
}

public struct SummaryRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var meetingId: String
    public var provider: String
    public var model: String?
    public var modelVersion: String?
    public var promptVersion: String?
    public var value: MeetingSummary
    public var status: String
    public var isActive: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, meetingId: String, provider: String, model: String? = nil,
                modelVersion: String? = nil, promptVersion: String? = nil, value: MeetingSummary,
                status: String = "completed", isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.meetingId = meetingId; self.provider = provider; self.model = model
        self.modelVersion = modelVersion; self.promptVersion = promptVersion; self.value = value
        self.status = status; self.isActive = isActive; self.createdAt = createdAt
    }
}
