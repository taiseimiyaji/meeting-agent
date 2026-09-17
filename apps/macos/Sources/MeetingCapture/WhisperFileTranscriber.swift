@preconcurrency import WhisperKit
import Foundation

/// One model instance is reused across audio units. Model preparation downloads
/// model/tokenizer assets only; captured audio is never sent to a server.
public actor WhisperFileTranscriber: FileTranscriber {
    public nonisolated let provider = "whisperkit"
    private let directory: URL
    private var engine: WhisperKit?
    private var releaseTask: Task<Void, Never>?
    public init(directory: URL) { self.directory = directory }

    public func prepareModel() async throws {
        let folder = try await WhisperKit.download(variant: "openai_whisper-small", downloadBase: directory)
        _ = try await ModelUtilities.loadTokenizer(for: .small, tokenizerFolder: directory, additionalSearchPaths: [folder])
        try Data(folder.path.utf8).write(to: directory.appendingPathComponent("installed-model.txt"), options: .atomic)
    }

    public func transcribe(file: URL) async throws -> OfflineTranscript {
        releaseTask?.cancel()
        defer {
            releaseTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                await self?.releaseEngine()
            }
        }
        if engine == nil {
            guard let path = try? String(contentsOf: directory.appendingPathComponent("installed-model.txt"), encoding: .utf8),
                  path.hasPrefix(directory.path + "/"), FileManager.default.fileExists(atPath: path) else {
                throw FileTranscriptionError.modelNotInstalled
            }
            engine = try await WhisperKit(modelFolder: path, tokenizerFolder: directory,
                                          verbose: false, prewarm: false, load: true, download: false)
        }
        try Task.checkCancellation()
        guard let engine else { throw FileTranscriptionError.modelNotInstalled }
        let results = try await engine.transcribe(audioPath: file.path,
            decodeOptions: DecodingOptions(language: "ja", skipSpecialTokens: true, withoutTimestamps: false))
        try Task.checkCancellation()
        let segments = results.flatMap(\.segments)
        return .init(text: results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                     startedAtMs: Int64((segments.first?.start ?? 0) * 1000),
                     endedAtMs: Int64((segments.last?.end ?? 0) * 1000))
    }
    private func releaseEngine() { engine = nil; releaseTask = nil }

}
