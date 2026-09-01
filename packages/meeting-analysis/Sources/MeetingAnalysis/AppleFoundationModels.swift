#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
public actor AppleFoundationTextScreenUnderstanding: ScreenUnderstandingProvider {
    public nonisolated let provider = "apple-foundation-models"
    public nonisolated let model = "system-language-model"
    public nonisolated let promptVersion = "screen-ocr-v1"

    public init() {}

    public nonisolated func isAvailable() async -> Bool {
        SystemLanguageModel.default.availability == .available
    }

    public nonisolated var contextSize: Int { SystemLanguageModel.default.contextSize }

    public func describe(imageURL: URL, ocr: String?) async throws -> ScreenDescription {
        guard await isAvailable() else { throw AppleFoundationModelError.unavailable }
        let text = ocr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw AppleFoundationModelError.imageInputRequiresNewerSDK }
        let session = LanguageModelSession(instructions: """
            あなたは会議中の共有画面を説明します。OCRにない事実を推測せず、画面の種類、主要な要素、議論で参照できる位置関係を簡潔に日本語で説明してください。
            """)
        let response = try await session.respond(to: "共有画面から抽出されたOCR:\n\(text)")
        return ScreenDescription(
            text: response.content,
            provider: provider,
            model: model,
            modelVersion: nil,
            promptVersion: promptVersion
        )
    }
}

public enum AppleFoundationModelError: Error, Equatable {
    case unavailable
    case imageInputRequiresNewerSDK
}
#endif
