import Foundation
import MeetingCapture
import MeetingCore
import MeetingPipeline

public protocol MeetingAPIRepository: Sendable {
    func meetings(limit: Int, before: Date?) throws -> [Meeting]
    func meeting(id: String) throws -> Meeting?
    func timeline(meetingId: String) throws -> Timeline?
    func summary(meetingId: String) throws -> MeetingSummary?
    func enqueue(meetingId: String, kind: String) throws
    func screenImage(id: String) throws -> APIImage?
}

public struct APIImage: Sendable {
    public let data: Data
    public let contentType: String
    public init(data: Data, contentType: String) { self.data = data; self.contentType = contentType }
}

public final class LocalMeetingRepository: MeetingAPIRepository, @unchecked Sendable {
    private let store: MeetingStore
    private let evidenceRoot: URL

    public init(store: MeetingStore, evidenceRoot: URL) throws {
        self.store = store
        self.evidenceRoot = evidenceRoot.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.evidenceRoot, withIntermediateDirectories: true)
    }

    public func meetings(limit: Int, before: Date?) throws -> [Meeting] { try store.meetings(limit: limit, before: before) }
    public func meeting(id: String) throws -> Meeting? { try store.meeting(id: id) }
    public func timeline(meetingId: String) throws -> Timeline? { try store.timeline(meetingId: meetingId) }
    public func summary(meetingId: String) throws -> MeetingSummary? { try store.activeSummary(meetingId: meetingId) }
    public func enqueue(meetingId: String, kind: String) throws { try store.enqueue(AnalysisJob(meetingId: meetingId, kind: kind)) }

    public func screenImage(id: String) throws -> APIImage? {
        guard let screen = try store.screen(id: id) else { return nil }
        let candidate = (screen.imagePath.hasPrefix("/")
            ? URL(fileURLWithPath: screen.imagePath)
            : evidenceRoot.appendingPathComponent(screen.imagePath))
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = evidenceRoot.path.hasSuffix("/") ? evidenceRoot.path : evidenceRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { throw MeetingStoreError.invalidData("Screen image path is outside the evidence root") }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 25 * 1_024 * 1_024 else {
            throw MeetingStoreError.invalidData("Screen image is not a valid evidence file")
        }
        let type: String
        switch candidate.pathExtension.lowercased() {
        case "jpg", "jpeg": type = "image/jpeg"
        case "png": type = "image/png"
        case "heic", "heif": type = "image/heic"
        default: throw MeetingStoreError.invalidData("Unsupported screen image type")
        }
        let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
        let signatureIsValid: Bool
        switch type {
        case "image/jpeg": signatureIsValid = data.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/png": signatureIsValid = data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/heic": signatureIsValid = data.count >= 12 && String(data: data[4..<8], encoding: .ascii) == "ftyp"
        default: signatureIsValid = false
        }
        guard signatureIsValid else { throw MeetingStoreError.invalidData("Screen image signature does not match its type") }
        return APIImage(data: data, contentType: type)
    }
}

public protocol CaptureAPIControlling: Sendable {
    func snapshot() async -> APICaptureSnapshot
    func start(targetID: String?) async throws
    func stop() async throws
}

public protocol MeetingPipelineControlling: Sendable {
    func start(meeting: Meeting, captureConfiguration: CaptureConfiguration) async throws
    func stop() async throws
}

extension MeetingPipeline: MeetingPipelineControlling {}

public actor LocalCaptureController: CaptureAPIControlling {
    private let adapter: any MeetingCaptureAdapter
    private let store: MeetingStore
    private let evidenceRoot: URL
    private let pipelineBuilder: @Sendable (URL) throws -> any MeetingPipelineControlling
    private var pipeline: (any MeetingPipelineControlling)?
    private var status: APICaptureStatus = .idle
    private var meetingID: String?
    private var lastError: String?

    public init(
        adapter: any MeetingCaptureAdapter,
        store: MeetingStore,
        evidenceRoot: URL,
        pipelineBuilder: (@Sendable (URL) throws -> any MeetingPipelineControlling)? = nil
    ) {
        self.adapter = adapter
        self.store = store
        self.evidenceRoot = evidenceRoot
        self.pipelineBuilder = pipelineBuilder ?? { keyFrameDirectory in
            try MeetingPipeline(
                capture: adapter,
                store: store,
                configuration: .init(keyFrameDirectory: keyFrameDirectory)
            )
        }
    }

    public func availableTargets() async throws -> [CaptureTarget] { try await adapter.availableTargets() }
    public func metricsSnapshot() async -> CaptureMetricsSnapshot { await adapter.metricsSnapshot() }

    public func start(targetID: String?) async throws {
        guard status == .idle || status == .failed else { throw CaptureError.alreadyRunning }
        status = .starting; lastError = nil
        let id = UUID().uuidString
        let meeting = Meeting(id: id, status: .capturing)
        do {
            let keyFrameDirectory = evidenceRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("KeyFrames", isDirectory: true)
            let pipeline = try pipelineBuilder(keyFrameDirectory)
            self.pipeline = pipeline
            try await pipeline.start(
                meeting: meeting,
                captureConfiguration: .init(targetWindowID: targetID.flatMap(UInt32.init))
            )
            meetingID = id; status = .capturing
        } catch {
            var failed = meeting; failed.status = .failed; failed.endedAt = Date()
            try? store.save(failed)
            pipeline = nil
            status = .failed; lastError = error.localizedDescription
            throw error
        }
    }

    public func stop() async throws {
        guard status == .capturing else { throw CaptureError.notRunning }
        status = .stopping
        do {
            guard let pipeline else { throw CaptureError.notRunning }
            try await pipeline.stop()
            self.pipeline = nil
            status = .idle; self.meetingID = nil
        } catch {
            status = .failed; lastError = error.localizedDescription; throw error
        }
    }

    public func snapshot() async -> APICaptureSnapshot {
        let metrics = await adapter.metricsSnapshot()
        return .init(status: status, meetingId: meetingID, videoFrames: metrics.screenFrames,
                     systemAudioRms: Self.linearRMS(metrics.systemAudioRMSDB),
                     microphoneRms: Self.linearRMS(metrics.microphoneRMSDB), error: lastError)
    }

    private static func linearRMS(_ decibels: Double?) -> Double {
        decibels.map { pow(10, $0 / 20) } ?? 0
    }
}
