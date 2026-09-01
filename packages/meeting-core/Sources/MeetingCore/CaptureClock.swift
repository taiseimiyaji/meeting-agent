import Foundation

/// Maps a process-monotonic clock to meeting-relative milliseconds. Wall time is
/// metadata only and never participates in media/event ordering.
public struct CaptureClock: Sendable {
    public let wallOrigin: Date
    private let monotonicOrigin: ContinuousClock.Instant

    public init(wallOrigin: Date = Date(), clock: ContinuousClock = .init()) {
        self.wallOrigin = wallOrigin
        self.monotonicOrigin = clock.now
    }

    public func elapsedMilliseconds(clock: ContinuousClock = .init()) -> Int64 {
        let duration = monotonicOrigin.duration(to: clock.now)
        let value = duration.components
        let millis = value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000
        return max(0, millis)
    }

    public func wallDate(at milliseconds: Int64) -> Date {
        wallOrigin.addingTimeInterval(Double(milliseconds) / 1_000)
    }
}

public enum ScreenAssociator {
    /// Associates every overlapping segment. Open screen segments are treated as
    /// extending through the transcript end, which is the useful live-capture behavior.
    public static func visibleScreens(for transcript: TranscriptEvent, screens: [ScreenEvent]) -> [ScreenReference] {
        let transcriptEnd = transcript.timeRange.endedAtMs ?? transcript.timeRange.startedAtMs
        return screens.compactMap { screen in
            let screenEnd = screen.timeRange.endedAtMs ?? transcriptEnd
            let overlap = max(0, min(transcriptEnd, screenEnd) - max(transcript.timeRange.startedAtMs, screen.timeRange.startedAtMs))
            guard overlap > 0 else { return nil }
            return ScreenReference(screenId: screen.id, relation: .visibleDuringSpeech, overlapMs: overlap, confidence: 1)
        }.sorted { ($0.overlapMs ?? 0) > ($1.overlapMs ?? 0) }
    }
}
