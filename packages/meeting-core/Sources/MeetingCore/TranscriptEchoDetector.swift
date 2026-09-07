import Foundation

/// Conservative cross-track duplicate detection, not speaker diarization or AEC.
/// Raw events stay intact; the annotation is derived again when the timeline is read.
public enum TranscriptEchoDetector {
    public static func annotate(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        let system = Dictionary(grouping: events.filter { $0.source == .system && $0.isFinal }, by: { normalized($0.text) })
        return events.map { original in
            var event = original
            event.possibleEchoOf = nil
            guard event.source == .microphone, event.isFinal,
                  let end = event.timeRange.endedAtMs, end > event.timeRange.startedAtMs else { return event }
            let text = normalized(event.text)
            // Short acknowledgments often genuinely occur on both sides.
            guard text.count >= 20 else { return event }
            let candidates = (system[text] ?? []).filter { remote in
                guard remote.meetingId == event.meetingId, let remoteEnd = remote.timeRange.endedAtMs,
                      remoteEnd > remote.timeRange.startedAtMs else { return false }
                let start = event.timeRange.startedAtMs, remoteStart = remote.timeRange.startedAtMs
                let overlap = min(end, remoteEnd) - max(start, remoteStart)
                let duration = max(end - start, remoteEnd - remoteStart)
                // Permit small recognition offsets, but never merge later repetition.
                return abs(Double(start) - Double(remoteStart)) <= 1_000 &&
                    abs(Double(end) - Double(remoteEnd)) <= 1_000 &&
                    Double(overlap) / Double(duration) >= 0.8
            }
            event.possibleEchoOf = candidates.sorted {
                let left = abs(Double($0.timeRange.startedAtMs) - Double(event.timeRange.startedAtMs))
                let right = abs(Double($1.timeRange.startedAtMs) - Double(event.timeRange.startedAtMs))
                return left == right ? $0.id < $1.id : left < right
            }.first?.id
            return event
        }
    }

    private static func normalized(_ text: String) -> String {
        // Preserve case, wording, numeric punctuation and internal spacing.
        // Ignore Japanese reading pauses and whitespace at the ends only.
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { $0 != "、" && $0 != "。" }
            .map(String.init).joined()
    }
}
