import Foundation

public struct ScreenDescription: Codable, Sendable, Equatable {
    public let text: String
    public let provider: String
    public let model: String
    public let modelVersion: String?
    public let promptVersion: String

    public init(text: String, provider: String, model: String, modelVersion: String? = nil, promptVersion: String) {
        self.text = text
        self.provider = provider
        self.model = model
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
    }
}

public protocol ScreenUnderstandingProvider: Sendable {
    var provider: String { get }
    var model: String { get }
    var promptVersion: String { get }
    func isAvailable() async -> Bool
    func describe(imageURL: URL, ocr: String?) async throws -> ScreenDescription
}

public struct OCRFallbackScreenUnderstanding: ScreenUnderstandingProvider {
    public let provider = "vision-ocr"
    public let model = "none"
    public let promptVersion = "ocr-fallback-v1"

    public init() {}
    public func isAvailable() async -> Bool { true }
    public func describe(imageURL: URL, ocr: String?) async throws -> ScreenDescription {
        let text = ocr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ScreenDescription(
            text: text.isEmpty ? "画面の説明は利用できません。" : "画面に次のテキストが表示されています:\n\(text)",
            provider: provider,
            model: model,
            promptVersion: promptVersion
        )
    }
}
