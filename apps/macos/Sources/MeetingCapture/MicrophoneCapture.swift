@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class MicrophoneCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, CMTime) -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false

    func start(handler: @escaping Handler) throws {
        try lock.withLock {
            guard !running else { throw CaptureError.alreadyRunning }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.invalidSampleBuffer }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                guard let ownedBuffer = buffer.deepCopy() else { return }
                self.lock.withLock { if self.running { handler(ownedBuffer, now) } }
            }
            engine.prepare()
            do {
                try engine.start()
                running = true
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        }
    }

    func stop() {
        let wasRunning = lock.withLock { let value = running; running = false; return value }
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { continue }
            let byteCount = Int(source[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
