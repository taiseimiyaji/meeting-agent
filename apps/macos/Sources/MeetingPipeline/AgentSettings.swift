import Foundation

public struct AgentSettings: Codable, Sendable, Equatable {
    public var sttProvider: String = "apple_speech"
    public var summaryProvider: String = "local_heuristic"
    public var codexIncludeScreens: Bool? = true
    public var retentionDays: Int = 0
    public var recoveryMode: Bool = true
    public init() { if #available(macOS 26.0, *) { sttProvider = "speech_analyzer" } }
    public func validate() throws {
        guard ["apple_speech", "speech_analyzer", "whisperkit"].contains(sttProvider),
              ["local_heuristic", "apple_foundation_models", "codex_chatgpt"].contains(summaryProvider),
              [0, 7, 30, 90, 365].contains(retentionDays), recoveryMode else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
    }
}

public final class AgentSettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    public func load() throws -> AgentSettings {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let value = try JSONDecoder().decode(AgentSettings.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }
    public func save(_ value: AgentSettings) throws {
        try value.validate()
        lock.lock(); defer { lock.unlock() }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
