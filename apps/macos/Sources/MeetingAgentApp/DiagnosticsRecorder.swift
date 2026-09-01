import Foundation
import MeetingCapture

actor DiagnosticsRecorder {
    private var handle: FileHandle?

    func start(in dataDirectory: URL) throws {
        let directory = dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let name = "capture-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-" )).jsonl"
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ snapshot: CaptureMetricsSnapshot) throws {
        guard let handle else { return }
        var data = try JSONEncoder().encode(snapshot)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    func stop() throws {
        try handle?.close()
        handle = nil
    }
}
