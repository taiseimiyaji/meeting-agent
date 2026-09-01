import Foundation
import OSLog

enum AgentEnvironment {
    static let logger = Logger(subsystem: "dev.meeting-agent.macos", category: "agent")

    static func prepareDataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("MeetingAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
