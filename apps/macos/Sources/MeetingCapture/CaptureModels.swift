import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum CaptureOutputKind: String, Sendable, CaseIterable {
    case screen
    case systemAudio
    case microphone
}

public struct CaptureTimestamp: Sendable, Equatable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public var milliseconds: Int64 { Int64(nanoseconds / 1_000_000) }
}

public struct VideoFrameEvent: @unchecked Sendable {
    public let timestamp: CaptureTimestamp
    public let presentationTime: CMTime
    public let pixelBuffer: CVPixelBuffer

    public init(timestamp: CaptureTimestamp, presentationTime: CMTime, pixelBuffer: CVPixelBuffer) {
        self.timestamp = timestamp
        self.presentationTime = presentationTime
        self.pixelBuffer = pixelBuffer
    }
}

public struct AudioEvent: @unchecked Sendable {
    public let kind: CaptureOutputKind
    public let timestamp: CaptureTimestamp
    public let presentationTime: CMTime
    public let sampleBuffer: CMSampleBuffer?
    public let pcmBuffer: AVAudioPCMBuffer?

    public init(
        kind: CaptureOutputKind,
        timestamp: CaptureTimestamp,
        presentationTime: CMTime,
        sampleBuffer: CMSampleBuffer?,
        pcmBuffer: AVAudioPCMBuffer?
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.presentationTime = presentationTime
        self.sampleBuffer = sampleBuffer
        self.pcmBuffer = pcmBuffer
    }
}

public enum CaptureEvent: @unchecked Sendable {
    case video(VideoFrameEvent)
    case audio(AudioEvent)
}

public struct CaptureTarget: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let applicationName: String
    public let windowTitle: String

    public init(id: UInt32, applicationName: String, windowTitle: String) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
    }
}

public struct CaptureConfiguration: Sendable, Equatable {
    public var targetWindowID: UInt32?
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool

    public init(
        targetWindowID: UInt32? = nil,
        width: Int = 1920,
        height: Int = 1080,
        framesPerSecond: Int = 5,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = true
    ) {
        self.targetWindowID = targetWindowID
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
    }
}

public enum CaptureState: Sendable, Equatable {
    case idle
    case starting
    case capturing
    case stopping
    case failed(String)
}

public enum CaptureError: LocalizedError, Equatable {
    case alreadyRunning
    case notRunning
    case screenPermissionDenied
    case microphonePermissionDenied
    case targetNotFound
    case invalidSampleBuffer

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Capture is already running."
        case .notRunning: "Capture is not running."
        case .screenPermissionDenied: "Screen Recording permission is required."
        case .microphonePermissionDenied: "Microphone permission is required."
        case .targetNotFound: "No capturable window was found."
        case .invalidSampleBuffer: "The capture sample buffer was invalid."
        }
    }
}
