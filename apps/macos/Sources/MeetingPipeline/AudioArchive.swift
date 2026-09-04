@preconcurrency import AVFoundation
import Foundation
import MeetingCapture

/// Keeps captured audio durable even if live speech recognition fails.
public final class AudioArchiveWriter: @unchecked Sendable {
    private let directory: URL
    private var files: [CaptureOutputKind: AVAudioFile] = [:]
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ buffer: AVAudioPCMBuffer, kind: CaptureOutputKind) throws {
        guard kind == .systemAudio || kind == .microphone else { return }
        try lock.withLock {
            let file: AVAudioFile
            if let existing = files[kind] {
                file = existing
            } else {
                let name = kind == .systemAudio ? "system.caf" : "microphone.caf"
                file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: buffer.format.settings)
                files[kind] = file
            }
            try file.write(from: buffer)
        }
    }

    public func finish() { lock.withLock { files.removeAll() } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
