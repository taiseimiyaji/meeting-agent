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
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                guard let ownedBuffer = buffer.deepCopy() else { return }
                handler(ownedBuffer, now)
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
        lock.withLock {
            guard running else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
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
