import AVFoundation
import CoreGraphics
import Foundation
import Speech

public enum PermissionState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case granted
    case restricted
}

public struct CapturePermissionSnapshot: Sendable, Equatable {
    public var screenRecording: PermissionState
    public var microphone: PermissionState
    public var speechRecognition: PermissionState

    public init(
        screenRecording: PermissionState,
        microphone: PermissionState,
        speechRecognition: PermissionState = .notDetermined
    ) {
        self.screenRecording = screenRecording
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }
}

public protocol CapturePermissionProviding: Sendable {
    func current() async -> CapturePermissionSnapshot
    func requestScreenRecording() async -> PermissionState
    func requestMicrophone() async -> PermissionState
    func requestSpeechRecognition() async -> PermissionState
}

public struct SystemCapturePermissions: CapturePermissionProviding {
    private static let screenRequestAttemptedKey = "meetingAgent.screenCaptureRequestAttempted"

    public init() {}

    public func current() async -> CapturePermissionSnapshot {
        let screen: PermissionState = if CGPreflightScreenCaptureAccess() {
            .granted
        } else if UserDefaults.standard.bool(forKey: Self.screenRequestAttemptedKey) {
            .denied
        } else {
            .notDetermined
        }
        let microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        let speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        return .init(screenRecording: screen, microphone: microphone, speechRecognition: speech)
    }

    public func requestScreenRecording() async -> PermissionState {
        UserDefaults.standard.set(true, forKey: Self.screenRequestAttemptedKey)
        return CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    public func requestMicrophone() async -> PermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    public func requestSpeechRecognition() async -> PermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }


    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}
