@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

@available(macOS 26.0, *)
public struct AnalyzerFileTranscriber: FileTranscriber {
    public let provider = "speech_analyzer"
    public init() {}

    public func transcribe(file: URL) async throws -> OfflineTranscript {
        try await withTranscriptionDeadline {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
                throw TranscriberError.localeUnavailable("ja-JP")
            }
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw FileTranscriptionError.modelNotInstalled
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            return try await withTaskCancellationHandler {
                let results = Task { () throws -> OfflineTranscript in
                    var texts: [String] = []
                    var first: Int64?
                    var end: Int64 = 0
                    for try await result in module.results {
                        first = first ?? Int64(result.range.start.seconds * 1000)
                        end = Int64(CMTimeRangeGetEnd(result.range).seconds * 1000)
                        texts.append(String(result.text.characters))
                    }
                    return .init(text: texts.joined(), startedAtMs: first ?? 0, endedAtMs: end)
                }
                do {
                    let audio = try AVAudioFile(forReading: file)
                    try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
                    return try await results.value
                } catch {
                    results.cancel()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
        }
    }

    public static func prepareModel() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw TranscriberError.localeUnavailable("ja-JP")
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }
}
