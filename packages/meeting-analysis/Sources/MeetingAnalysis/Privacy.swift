import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct TimedValue<Value: Sendable>: Sendable {
    public let timestampMs: Int64
    public let value: Value
    public init(timestampMs: Int64, value: Value) {
        self.timestampMs = timestampMs
        self.value = value
    }
}

public actor EphemeralRingBuffer<Value: Sendable> {
    private let retentionMs: Int64
    private var values: [TimedValue<Value>] = []

    public init(retentionMs: Int64) {
        precondition(retentionMs > 0)
        self.retentionMs = retentionMs
    }

    public func append(_ value: Value, at timestampMs: Int64) {
        values.append(.init(timestampMs: timestampMs, value: value))
        values.removeAll { timestampMs - $0.timestampMs > retentionMs }
    }

    public func snapshot() -> [TimedValue<Value>] { values }
    public func clear() { values.removeAll(keepingCapacity: false) }
}

public struct RetentionPolicy: Codable, Sendable, Equatable {
    public let transcriptDays: Int
    public let keyFrameDays: Int
    public let recoveryEnabled: Bool
    public let recoveryMinutes: Int

    public init(transcriptDays: Int, keyFrameDays: Int, recoveryEnabled: Bool = false, recoveryMinutes: Int = 5) {
        precondition(transcriptDays >= 0 && keyFrameDays >= 0 && recoveryMinutes > 0)
        self.transcriptDays = transcriptDays
        self.keyFrameDays = keyFrameDays
        self.recoveryEnabled = recoveryEnabled
        self.recoveryMinutes = recoveryMinutes
    }
}

public enum ExternalDataKind: String, Codable, CaseIterable, Sendable {
    case transcript
    case ocr
    case screenDescription = "screen_description"
    case keyFrame = "key_frame"
    case meetingMetadata = "meeting_metadata"
}

public struct ExternalProcessingConsent: Codable, Sendable, Equatable {
    public let meetingID: String
    public let provider: String
    public let allowedData: Set<ExternalDataKind>
    public let confirmedAt: Date

    public init(meetingID: String, provider: String, allowedData: Set<ExternalDataKind>, confirmedAt: Date = Date()) {
        self.meetingID = meetingID
        self.provider = provider
        self.allowedData = allowedData
        self.confirmedAt = confirmedAt
    }
}

public struct ExternalProcessingAudit: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: String
    public let provider: String
    public let model: String
    public let sentData: Set<ExternalDataKind>
    public let sentAt: Date

    public init(id: UUID = UUID(), meetingID: String, provider: String, model: String, sentData: Set<ExternalDataKind>, sentAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.provider = provider
        self.model = model
        self.sentData = sentData
        self.sentAt = sentAt
    }
}

public actor RetentionService {
    private let meetingsRoot: URL
    private let fileManager: FileManager

    public init(meetingsRoot: URL, fileManager: FileManager = .default) {
        self.meetingsRoot = meetingsRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    public func deleteExpiredFiles(now: Date = Date(), olderThan cutoff: Date) throws -> [URL] {
        guard cutoff <= now else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: meetingsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var deleted = [URL]()
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(meetingsRoot.path + "/") else { continue }
            let values = try standardized.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff else { continue }
            try fileManager.removeItem(at: standardized)
            deleted.append(standardized)
        }
        return deleted
    }
}

#if canImport(CryptoKit)
public struct RecoveryEncryption: Sendable {
    public init() {}

    public func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else { throw RecoveryEncryptionError.missingCombinedData }
        return combined
    }

    public func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

public enum RecoveryEncryptionError: Error { case missingCombinedData }
#endif
