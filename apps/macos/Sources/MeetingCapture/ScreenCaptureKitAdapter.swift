@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation

public actor ScreenCaptureKitAdapter: MeetingCaptureAdapter {
    public nonisolated let events: AsyncStream<CaptureEvent>

    private nonisolated let continuation: AsyncStream<CaptureEvent>.Continuation
    private let clock = CaptureClock()
    private let metrics = CaptureMetrics()
    private let microphone = MicrophoneCapture()
    private var stream: SCStream?
    private var output: StreamOutput?
    private var state: CaptureState = .idle

    public init() {
        let pair = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        continuation = pair.continuation
    }

    deinit { continuation.finish() }

    public func availableTargets() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let app = window.owningApplication else { return nil }
            return CaptureTarget(
                id: window.windowID,
                applicationName: app.applicationName,
                windowTitle: window.title ?? "Untitled Window"
            )
        }
        .sorted { lhs, rhs in
            let lhsChrome = lhs.applicationName.localizedCaseInsensitiveContains("Chrome")
            let rhsChrome = rhs.applicationName.localizedCaseInsensitiveContains("Chrome")
            return lhsChrome != rhsChrome ? lhsChrome : lhs.windowTitle < rhs.windowTitle
        }
    }

    public func start(configuration: CaptureConfiguration) async throws {
        guard state == .idle else { throw CaptureError.alreadyRunning }
        state = .starting
        clock.reset()
        await metrics.reset()

        do {
            guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenPermissionDenied }
            if configuration.capturesMicrophone {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    throw CaptureError.microphonePermissionDenied
                }
            }

            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let target = chooseWindow(from: content.windows, id: configuration.targetWindowID)
            guard let target else { throw CaptureError.targetNotFound }

            let filter = SCContentFilter(desktopIndependentWindow: target)
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = configuration.width
            streamConfiguration.height = configuration.height
            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
            streamConfiguration.queueDepth = 5
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfiguration.showsCursor = true
            streamConfiguration.capturesAudio = configuration.capturesSystemAudio
            streamConfiguration.excludesCurrentProcessAudio = true
            streamConfiguration.sampleRate = 48_000
            streamConfiguration.channelCount = 2

            let output = StreamOutput(clock: clock, metrics: metrics, continuation: continuation)
            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
            self.output = output
            self.stream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.screenQueue)
            if configuration.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.audioQueue)
            }
            try await stream.startCapture()

            if configuration.capturesMicrophone {
                try microphone.start { [clock, metrics, continuation] buffer, presentationTime in
                    let timestamp = clock.timestamp(for: presentationTime)
                    continuation.yield(.audio(.init(
                        kind: .microphone,
                        timestamp: timestamp,
                        presentationTime: presentationTime,
                        sampleBuffer: nil,
                        pcmBuffer: buffer
                    )))
                    Task { await metrics.record(.microphone, timestamp: timestamp, rmsDB: buffer.rmsDB()) }
                }
            }

            state = .capturing
        } catch {
            microphone.stop()
            if let stream { try? await stream.stopCapture() }
            stream = nil
            output = nil
            state = .failed(error.localizedDescription)
            await metrics.recordError()
            state = .idle
            throw error
        }
    }

    public func stop() async throws {
        guard state == .capturing, let stream else { throw CaptureError.notRunning }
        state = .stopping
        microphone.stop()
        do {
            try await stream.stopCapture()
        } catch {
            await metrics.recordError()
            self.stream = nil
            output = nil
            state = .idle
            throw error
        }
        self.stream = nil
        output = nil
        state = .idle
    }

    public func metricsSnapshot() async -> CaptureMetricsSnapshot { await metrics.snapshot() }

    private func chooseWindow(from windows: [SCWindow], id: UInt32?) -> SCWindow? {
        if let id { return windows.first { $0.windowID == id } }
        return windows.first {
            $0.owningApplication?.applicationName.localizedCaseInsensitiveContains("Google Chrome") == true
        } ?? windows.first {
            $0.owningApplication?.applicationName.localizedCaseInsensitiveContains("Chrome") == true
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let screenQueue = DispatchQueue(label: "meeting-agent.capture.screen", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "meeting-agent.capture.system-audio", qos: .userInitiated)

    private let clock: CaptureClock
    private let metrics: CaptureMetrics
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    init(
        clock: CaptureClock,
        metrics: CaptureMetrics,
        continuation: AsyncStream<CaptureEvent>.Continuation
    ) {
        self.clock = clock
        self.metrics = metrics
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await metrics.recordError() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else {
            Task { await metrics.recordError() }
            return
        }
        let presentationTime = sampleBuffer.presentationTimeStamp
        let timestamp = clock.timestamp(for: presentationTime)

        switch type {
        case .screen:
            guard sampleBuffer.isCompleteScreenFrame else {
                Task { await metrics.recordDroppedScreenFrame() }
                return
            }
            guard let imageBuffer = sampleBuffer.imageBuffer else {
                Task { await metrics.recordDroppedScreenFrame() }
                return
            }
            let result = continuation.yield(.video(.init(
                timestamp: timestamp,
                presentationTime: presentationTime,
                pixelBuffer: imageBuffer
            )))
            if case .dropped = result { Task { await metrics.recordDroppedScreenFrame() } }
            Task { await metrics.record(.screen, timestamp: timestamp) }
        case .audio:
            let pcmBuffer = sampleBuffer.makePCMBuffer()
            let rmsDB = pcmBuffer?.rmsDB()
            continuation.yield(.audio(.init(
                kind: .systemAudio,
                timestamp: timestamp,
                presentationTime: presentationTime,
                sampleBuffer: sampleBuffer,
                pcmBuffer: pcmBuffer
            )))
            Task { await metrics.record(.systemAudio, timestamp: timestamp, rmsDB: rmsDB) }
        case .microphone:
            break // Microphone is captured independently by AVAudioEngine on macOS 14.
        @unknown default:
            break
        }
    }
}

private extension CMSampleBuffer {
    var isCompleteScreenFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else { return false }
        return status == .complete
    }

    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

extension AVAudioPCMBuffer {
    func rmsDB() -> Double? {
        guard format.commonFormat == .pcmFormatFloat32,
              let channels = floatChannelData,
              frameLength > 0 else { return nil }
        var sum = 0.0
        let frameCount = Int(frameLength)
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = Double(channels[channel][frame])
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Double(frameCount * channelCount))
        return 20 * log10(max(rms, 0.000_000_1))
    }
}
