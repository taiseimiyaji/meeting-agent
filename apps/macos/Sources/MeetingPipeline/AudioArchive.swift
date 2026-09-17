@preconcurrency import AVFoundation
import Foundation
import MeetingCapture

/// The sidecar is written before audio starts. An interrupted open CAF can be
/// recovered by reading its actual frame count; completed receipts are separate.
public struct AudioChunk: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var startedAtMs: Int64
    public var endedAtMs: Int64
    public var fileName: String
    public var closed: Bool
    public var overlapMs: Int64?
}

public final class AudioArchiveWriter: @unchecked Sendable {
    private final class OpenChunk {
        var metadata: AudioChunk
        var file: AVAudioFile?
        var frames: Int64
        var lastEndMs: Int64
        init(metadata: AudioChunk, file: AVAudioFile, frames: Int64 = 0, lastEndMs: Int64) {
            self.metadata = metadata; self.file = file; self.frames = frames; self.lastEndMs = lastEndMs
        }
    }
    private let directory: URL
    private let chunkDuration: Double
    private struct Tail { let buffer: AVAudioPCMBuffer; let timestampMs: Int64 }
    private var tails: [CaptureOutputKind: [Tail]] = [:]
    private var files: [CaptureOutputKind: OpenChunk] = [:]
    private let lock = NSLock()
    private var errors: [String] = []
    private let errorLock = NSLock()
    private var savedFrames: Int64 = 0
    private let encoder = JSONEncoder()
    private let ioQueue = DispatchQueue(label: "meeting-agent.audio-disk", qos: .userInitiated)
    private let queueLock = NSLock()
    private var pendingBytes = 0
    private var accepting = true
    private let maximumPendingBytes = 8 * 1024 * 1024
    private var lastSpaceCheck = Date.distantPast
    private let onClosed: (@Sendable (AudioChunk) throws -> Void)?
    private let checkSpace: @Sendable () throws -> Void

    public init(directory: URL, chunkDuration: Double = 20, checkSpace: (@Sendable () throws -> Void)? = nil, onClosed: (@Sendable (AudioChunk) throws -> Void)? = nil) throws {
        self.onClosed = onClosed
        self.directory = directory
        self.checkSpace = checkSpace ?? { try StorageCapacity.require(at: directory) }
        self.chunkDuration = max(0.1, chunkDuration)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Capture callbacks only retain an owned buffer into a bounded serial queue.
    public func enqueue(_ buffer: AVAudioPCMBuffer, kind: CaptureOutputKind, timestampMs: Int64) throws {
        let size = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        if let error = lastError { throw StorageCapacityError(error) }
        let owned = OwnedAudioBuffer(buffer)
        try queueLock.withLock {
            guard accepting else { throw StorageCapacityError("録音の保存は終了しています。") }
            guard pendingBytes + size <= maximumPendingBytes else {
                throw StorageCapacityError("音声の保存が追いつかないため録音を停止しました。保存先の速度と空き容量を確認してください。")
            }
            pendingBytes += size
            ioQueue.async { [self] in
                defer { queueLock.withLock { pendingBytes -= size } }
                do { try write(owned.buffer, kind: kind, timestampMs: timestampMs) }
                catch { recordFailure(error.localizedDescription) }
            }
        }
    }

    public func write(_ buffer: AVAudioPCMBuffer, kind: CaptureOutputKind, timestampMs: Int64? = nil) throws {
        guard kind == .systemAudio || kind == .microphone, buffer.frameLength > 0 else { return }
        try lock.withLock {
            if Date().timeIntervalSince(lastSpaceCheck) >= 1 {
                try checkSpace()
                lastSpaceCheck = Date()
            }
            let timestamp = timestampMs ?? files[kind]?.lastEndMs ?? 0
            if let last = tails[kind]?.last {
                let end = last.timestampMs + Int64(Double(last.buffer.frameLength) / last.buffer.format.sampleRate * 1000)
                if last.buffer.format != buffer.format || abs(timestamp - end) > 100 { tails[kind] = [] }
            }
            if let current = files[kind],
               current.file?.processingFormat != buffer.format || abs(timestamp - current.lastEndMs) > 100 {
                try close(kind)
                tails[kind] = []
            }
            if files[kind] == nil {
                let id = UUID().uuidString
                let tail = tails[kind] ?? []
                let start = tail.first?.timestampMs ?? timestamp
                let metadata = AudioChunk(id: id, kind: kind.rawValue, startedAtMs: start,
                    endedAtMs: timestamp, fileName: "\(id).caf", closed: false, overlapMs: timestamp - start)
                let file = try AVAudioFile(forWriting: directory.appendingPathComponent(metadata.fileName),
                                          settings: buffer.format.settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                try save(metadata)
                var frames: Int64 = 0
                for item in tail { try file.write(from: item.buffer); frames += Int64(item.buffer.frameLength) }
                files[kind] = OpenChunk(metadata: metadata, file: file, frames: frames, lastEndMs: timestamp)
            }
            guard let current = files[kind] else { return }
            try current.file?.write(from: buffer)
            current.frames += Int64(buffer.frameLength)
            savedFrames += Int64(buffer.frameLength)
            current.lastEndMs = timestamp + Int64(Double(buffer.frameLength) / buffer.format.sampleRate * 1000)
            current.metadata.endedAtMs = current.lastEndMs
            files[kind] = current
            try rememberTail(buffer, kind: kind, timestampMs: timestamp)
            let duration = Double(current.frames) / buffer.format.sampleRate
            // Prefer a quiet boundary, with a hard bound for uninterrupted speech.
            if duration >= chunkDuration || (duration >= chunkDuration * 0.75 && isQuiet(buffer)) {
                try close(kind)
            }
        }
    }

    public func recordFailure(_ message: String) {
        errorLock.withLock {
            guard errors.last != message else { return }
            errors.append(message)
            if errors.count > 100 { errors.removeFirst() }
            try? encoder.encode(errors).write(to: directory.appendingPathComponent("errors.json"), options: .atomic)
        }
    }
    public var lastError: String? { errorLock.withLock { errors.last } }
    public var archivedFrames: Int64 { lock.withLock { savedFrames } }

    public func finish() {
        queueLock.withLock { accepting = false }
        ioQueue.sync {}
        lock.withLock {
            tails.removeAll()
            for kind in Array(files.keys) {
                do { try close(kind) } catch { recordFailure(error.localizedDescription) }
            }

        }
    }

    private func isQuiet(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        var sum = 0.0
        for c in 0..<Int(buffer.format.channelCount) {
            for f in 0..<Int(buffer.frameLength) { let value = Double(buffer.format.isInterleaved ? channels[0][f * Int(buffer.format.channelCount) + c] : channels[c][f]); sum += value * value }
        }
        return sum / Double(max(1, Int(buffer.frameLength) * Int(buffer.format.channelCount))) < 0.000_01
    }

    private func rememberTail(_ buffer: AVAudioPCMBuffer, kind: CaptureOutputKind, timestampMs: Int64) throws {
        let count = min(buffer.frameLength, AVAudioFrameCount(buffer.format.sampleRate * 0.5))
        guard count > 0, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return }
        copy.frameLength = count
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in source.indices {
            let bytesPerFrame = Int(source[i].mDataByteSize) / Int(buffer.frameLength)
            if let from = source[i].mData, let to = destination[i].mData {
                memcpy(to, from.advanced(by: (Int(buffer.frameLength) - Int(count)) * bytesPerFrame), Int(count) * bytesPerFrame)
            }
        }
        let start = timestampMs + Int64(Double(buffer.frameLength - count) / buffer.format.sampleRate * 1000)
        tails[kind, default: []].append(Tail(buffer: copy, timestampMs: start))
        let end = timestampMs + Int64(Double(buffer.frameLength) / buffer.format.sampleRate * 1000)
        while let first = tails[kind]?.first,
              first.timestampMs + Int64(Double(first.buffer.frameLength) / first.buffer.format.sampleRate * 1000) <= end - 500 {
            tails[kind]?.removeFirst()
        }
    }

    private func close(_ kind: CaptureOutputKind) throws {
        guard let current = files.removeValue(forKey: kind) else { return }
        current.metadata.closed = true
        // Shared state releases the handle even when write() still holds the unit.
        current.file = nil
        try save(current.metadata)
        try onClosed?(current.metadata)
    }
    private func save(_ metadata: AudioChunk) throws {
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("\(metadata.id).json"), options: .atomic)
    }

    public static func chunks(in directory: URL, recoverOpen: Bool = false) throws -> [AudioChunk] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url -> AudioChunk? in
                do {
                var chunk = try JSONDecoder().decode(AudioChunk.self, from: Data(contentsOf: url))
                guard UUID(uuidString: chunk.id) != nil, chunk.fileName == "\(chunk.id).caf",
                      ["systemAudio", "microphone"].contains(chunk.kind), chunk.startedAtMs >= 0, chunk.endedAtMs >= chunk.startedAtMs else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if !chunk.closed && recoverOpen {
                    let audio = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.fileName))
                    chunk.endedAtMs = chunk.startedAtMs + Int64(Double(audio.length) / audio.processingFormat.sampleRate * 1000)
                    chunk.closed = true
                    try JSONEncoder().encode(chunk).write(to: url, options: .atomic)
                }
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("invalid"))
                return chunk.closed ? chunk : nil
                } catch {
                    try Data(error.localizedDescription.utf8).write(to: url.deletingPathExtension().appendingPathExtension("invalid"), options: .atomic)
                    return nil
                }
            }.sorted { $0.startedAtMs < $1.startedAtMs }
    }
    public static func corruptUnits(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "invalid" }
            .map { "\($0.lastPathComponent): " + (try String(contentsOf: $0, encoding: .utf8)) }
    }

}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

private struct OwnedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
