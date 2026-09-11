@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Foundation

/// Authenticated browser packets feed the same evidence pipeline as native capture.
public actor BrowserCaptureAdapter: MeetingCaptureAdapter {
    public nonisolated let events: AsyncStream<CaptureEvent>
    public nonisolated let providesStopEvent = true
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var sink: (@Sendable (AudioEvent) -> Void)?
    private var running = false
    private var lastPacket = Date()
    private var sequence: [String: Int] = [:]
    private var lastTime: [String: Int64] = [:]
    private var metrics = CaptureMetricsSnapshot()
    private let images = CIContext(options: [.cacheIntermediates: false])
    public init() {
        let pair = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        events = pair.stream; continuation = pair.continuation
    }
    public func availableTargets() async throws -> [CaptureTarget] { [] }
    public func setAudioSink(_ sink: (@Sendable (AudioEvent) -> Void)?) -> Bool { self.sink = sink; return true }
    public func start(configuration: CaptureConfiguration) throws {
        guard !running else { throw CaptureError.alreadyRunning }
        running = true; sequence = [:]; lastTime = [:]; lastPacket = Date(); metrics = .init(startedAt: Date())
    }
    public func fail(_ message: String) { running = false; continuation.yield(.failure(String(message.prefix(1000)))) }
    public func stop() { running = false; sink = nil; continuation.yield(.stopped) }
    public func metricsSnapshot() -> CaptureMetricsSnapshot {
        if running && Date().timeIntervalSince(lastPacket) > 15 {
            running = false
            continuation.yield(.failure("Chromeとの収録接続が切れました。保存済みの音声を確定します。"))
        }
        return metrics
    }
    public func accept(kind: String, sequence number: Int, timestamp: Int64, rate: Double, channels: Int, data: Data) throws {
        guard running else { throw CaptureError.notRunning }
        guard number == sequence[kind, default: 0], timestamp >= 0, timestamp <= 7 * 86400 * 1000,
              timestamp >= lastTime[kind, default: 0] else { throw CaptureError.invalidSampleBuffer }
        let stamp = CaptureTimestamp(nanoseconds: UInt64(timestamp) * 1_000_000)
        if kind == "screen" {
            guard data.count <= 9 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, width <= 1920, height > 0, height <= 1080,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.invalidSampleBuffer }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw CaptureError.invalidSampleBuffer }
            images.render(CIImage(cgImage: image), to: pixel)
            continuation.yield(.video(.init(timestamp: stamp, presentationTime: CMTime(value: timestamp, timescale: 1000), pixelBuffer: pixel)))
            metrics.screenFrames += 1; metrics.lastScreenTimestampMs = timestamp
        } else {
            guard let output = CaptureOutputKind(rawValue: kind), output != .screen,
                  rate.isFinite, rate >= 8000, rate <= 192000, channels >= 1, channels <= 2,
                  !data.isEmpty, data.count <= 2 * 1024 * 1024, data.count % (4 * channels) == 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: UInt32(channels), interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(data.count / (4 * channels))) else { throw CaptureError.invalidSampleBuffer }
            buffer.frameLength = buffer.frameCapacity
            data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.audioBufferList.pointee.mBuffers.mData, count: data.count))
            let event = AudioEvent(kind: output, timestamp: stamp, presentationTime: CMTime(value: timestamp, timescale: 1000), sampleBuffer: nil, pcmBuffer: buffer)
            guard let sink else { throw CaptureError.notRunning }
            sink(event)
            let samples = buffer.floatChannelData![0]
            var power = 0.0
            for index in 0..<(data.count / 4) { let value = Double(samples[index]); if value.isFinite { power += value * value } }
            let rms = 10 * log10(max(1e-12, power / Double(data.count / 4)))
            if output == .microphone { metrics.microphoneRMSDB = rms } else { metrics.systemAudioRMSDB = rms }
            if output == .microphone { metrics.microphoneBuffers += 1; metrics.lastMicrophoneTimestampMs = timestamp }
            else { metrics.systemAudioBuffers += 1; metrics.lastSystemAudioTimestampMs = timestamp }
        }
        sequence[kind] = number + 1; lastTime[kind] = timestamp; lastPacket = Date()
    }
}
