@preconcurrency import AVFoundation
import Foundation

public enum LegacyAudioVerifier {
    /// Removes only a legacy duplicate whose decoded PCM is fully covered by
    /// byte-identical chunk ranges. Ambiguous/unsupported conversions keep it.
    @discardableResult public static func retire(_ original: URL, chunks: [AudioChunk], folder: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: original.path), !chunks.isEmpty else { return false }
        let source = try AVAudioFile(forReading: original)
        // Do not prove equality after a lossy sample-format conversion.
        guard source.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              source.fileFormat.commonFormat == source.processingFormat.commonFormat else { return false }
        let rate = source.processingFormat.sampleRate
        var covered: AVAudioFramePosition = 0
        func bytes(_ buffer: AVAudioPCMBuffer) -> Data {
            var result = Data()
            for item in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let pointer = item.mData { result.append(pointer.assumingMemoryBound(to: UInt8.self), count: Int(item.mDataByteSize)) }
            }
            return result
        }
        for chunk in chunks.sorted(by: { $0.startedAtMs < $1.startedAtMs }) {
            let restored = try LosslessAudio.materialize(folder.appendingPathComponent(chunk.fileName))
            defer { restored.cleanup() }
            let part = try AVAudioFile(forReading: restored.url)
            guard part.fileFormat.commonFormat == source.fileFormat.commonFormat,
                  part.processingFormat == source.processingFormat, part.length > 0,
                  let a = AVAudioPCMBuffer(pcmFormat: part.processingFormat, frameCapacity: 4096),
                  let b = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096) else { return false }
            let estimated = AVAudioFramePosition(Double(chunk.startedAtMs) * rate / 1000)
            let radius = AVAudioFramePosition(ceil(rate / 1000)) + 1
            let lower = max(0, estimated - radius), upper = min(source.length - part.length, estimated + radius)
            guard lower <= upper else { return false }
            var match: AVAudioFramePosition?
            for offset in lower...upper where offset <= covered {
                var equal = true
                // Reject mismatches cheaply at both ends before reading the unit.
                for position in [AVAudioFramePosition(0), max(0, part.length - 1024)] {
                    part.framePosition = position; source.framePosition = offset + position
                    let count = AVAudioFrameCount(min(1024, part.length - position))
                    try part.read(into: a, frameCount: count); try source.read(into: b, frameCount: count)
                    if bytes(a) != bytes(b) { equal = false; break }
                }
                if !equal { continue }
                part.framePosition = 0; source.framePosition = offset
                while part.framePosition < part.length {
                    try Task.checkCancellation()
                    let count = AVAudioFrameCount(min(4096, part.length - part.framePosition))
                    try part.read(into: a, frameCount: count); try source.read(into: b, frameCount: count)
                    if bytes(a) != bytes(b) { equal = false; break }
                }
                if equal { match = offset; break }
            }
            guard let match else { return false }
            covered = max(covered, match + part.length)
        }
        guard covered == source.length else { return false }
        let proof: [String: String] = ["verification": "all-decoded-pcm-bytes-equal", "frames": String(source.length), "sampleRate": String(rate), "channels": String(source.processingFormat.channelCount), "chunks": chunks.map(\.id).joined(separator: ",")]
        try JSONEncoder().encode(proof).write(to: original.appendingPathExtension("verified-migration"), options: .atomic)
        try FileManager.default.removeItem(at: original)
        return true
    }
}
