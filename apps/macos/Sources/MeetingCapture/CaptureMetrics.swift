import Foundation
import Darwin

public struct CaptureMetricsSnapshot: Sendable, Equatable, Codable {
    public var startedAt: Date?
    public var screenFrames: UInt64 = 0
    public var systemAudioBuffers: UInt64 = 0
    public var microphoneBuffers: UInt64 = 0
    public var droppedScreenFrames: UInt64 = 0
    public var errors: UInt64 = 0
    public var lastScreenTimestampMs: Int64?
    public var lastSystemAudioTimestampMs: Int64?
    public var lastMicrophoneTimestampMs: Int64?
    public var systemAudioRMSDB: Double?
    public var microphoneRMSDB: Double?
    public var processCPUPercent: Double?
    public var residentMemoryBytes: UInt64?

    public init(
        startedAt: Date? = nil,
        screenFrames: UInt64 = 0,
        systemAudioBuffers: UInt64 = 0,
        microphoneBuffers: UInt64 = 0,
        droppedScreenFrames: UInt64 = 0,
        errors: UInt64 = 0,
        lastScreenTimestampMs: Int64? = nil,
        lastSystemAudioTimestampMs: Int64? = nil,
        lastMicrophoneTimestampMs: Int64? = nil,
        systemAudioRMSDB: Double? = nil,
        microphoneRMSDB: Double? = nil,
        processCPUPercent: Double? = nil,
        residentMemoryBytes: UInt64? = nil
    ) {
        self.startedAt = startedAt; self.screenFrames = screenFrames
        self.systemAudioBuffers = systemAudioBuffers; self.microphoneBuffers = microphoneBuffers
        self.droppedScreenFrames = droppedScreenFrames; self.errors = errors
        self.lastScreenTimestampMs = lastScreenTimestampMs; self.lastSystemAudioTimestampMs = lastSystemAudioTimestampMs
        self.lastMicrophoneTimestampMs = lastMicrophoneTimestampMs; self.systemAudioRMSDB = systemAudioRMSDB
        self.microphoneRMSDB = microphoneRMSDB; self.processCPUPercent = processCPUPercent
        self.residentMemoryBytes = residentMemoryBytes
    }

    public var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }
}

public actor CaptureMetrics {
    private var value = CaptureMetricsSnapshot()
    private var resourceSampler = ProcessResourceSampler()

    public init() {}

    public func reset(startedAt: Date = Date()) {
        value = .init(startedAt: startedAt)
        resourceSampler = .init()
    }

    public func record(_ kind: CaptureOutputKind, timestamp: CaptureTimestamp, rmsDB: Double? = nil) {
        switch kind {
        case .screen:
            value.screenFrames += 1
            value.lastScreenTimestampMs = timestamp.milliseconds
        case .systemAudio:
            value.systemAudioBuffers += 1
            value.lastSystemAudioTimestampMs = timestamp.milliseconds
            value.systemAudioRMSDB = rmsDB
        case .microphone:
            value.microphoneBuffers += 1
            value.lastMicrophoneTimestampMs = timestamp.milliseconds
            value.microphoneRMSDB = rmsDB
        }
    }

    public func recordDroppedScreenFrame() { value.droppedScreenFrames += 1 }
    public func recordError() { value.errors += 1 }
    public func snapshot() -> CaptureMetricsSnapshot {
        if let resource = resourceSampler.sample() {
            value.processCPUPercent = resource.cpuPercent
            value.residentMemoryBytes = resource.residentMemoryBytes
        }
        return value
    }
}

private struct ProcessResourceSampler {
    private var previousWallTime: TimeInterval?
    private var previousCPUTimeNanoseconds: UInt64?

    mutating func sample(now: Date = Date()) -> (cpuPercent: Double?, residentMemoryBytes: UInt64)? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { usagePointer in
            // `rusage_info_t` is imported as `void *`, so Swift exposes the C
            // buffer parameter as a pointer-to-optional-pointer. Rebind the
            // storage itself; passing a separate pointer variable would make
            // libproc overwrite that variable and corrupt the stack.
            usagePointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else { return nil }
        let cpuTime = usage.ri_user_time + usage.ri_system_time
        let wallTime = now.timeIntervalSinceReferenceDate
        let cpuPercent: Double?
        if let previousWallTime, let previousCPUTimeNanoseconds, wallTime > previousWallTime {
            cpuPercent = Double(cpuTime - previousCPUTimeNanoseconds) / 1_000_000_000 / (wallTime - previousWallTime) * 100
        } else {
            cpuPercent = nil
        }
        previousWallTime = wallTime
        previousCPUTimeNanoseconds = cpuTime
        return (cpuPercent, usage.ri_resident_size)
    }
}
