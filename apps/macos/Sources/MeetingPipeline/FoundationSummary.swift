import Foundation
import MeetingCore
import MeetingCapture
#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationSummary {
    static func generate(timeline: Timeline) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else { throw FileTranscriptionError.unsupportedProvider("Apple Foundation Models unavailable") }
            // Bounded sections avoid dropping the end of a long meeting.
            let texts = timeline.transcripts.filter(\.isFinal).map(\.text)
            var sections: [String] = [], current = ""
            for text in texts {
                for offset in stride(from: 0, to: text.count, by: 2000) {
                    let part = String(text.dropFirst(offset).prefix(2000))
                    if current.count + part.count > 2500 { sections.append(current); current = "" }
                    current += part + "\n"
                }
            }
            if !current.isEmpty { sections.append(current) }
            var summaries: [String] = []
            for text in sections {
                let result = try await withTranscriptionDeadline {
                    let session = LanguageModelSession(instructions: "会議の記録を日本語で簡潔に要約してください。記録にない事実を補わないでください。")
                    return try await session.respond(to: text).content
                }
                summaries.append(result)
            }
            return summaries.joined(separator: "\n\n")
        }
        #endif
        throw FileTranscriptionError.unsupportedProvider("Apple Foundation Models requires macOS 26")
    }
}
