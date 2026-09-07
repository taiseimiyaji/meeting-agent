import Foundation

/// Cross-track duplicate candidates, not speaker identification or acoustic AEC.
/// Raw events stay intact and callers can reveal every candidate.
public enum TranscriptEchoDetector {
    public static func annotate(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        let system = Dictionary(grouping: events.filter {
            $0.source == .system && $0.isFinal && ($0.timeRange.endedAtMs ?? 0) > $0.timeRange.startedAtMs
        }, by: \.meetingId).mapValues { $0.sorted {
            $0.timeRange.startedAtMs == $1.timeRange.startedAtMs ? $0.id < $1.id : $0.timeRange.startedAtMs < $1.timeRange.startedAtMs
        } }
        return events.map { original in
            var event = original
            event.possibleEchoOf = nil
            guard event.source == .microphone, event.isFinal,
                  let end = event.timeRange.endedAtMs, end > event.timeRange.startedAtMs else { return event }
            let text = normalized(event.text)
            // Brief acknowledgments are often spoken independently on both sides.
            guard text.count >= 10 else { return event }
            let start = event.timeRange.startedAtMs
            let candidates = (system[event.meetingId] ?? []).filter {
                $0.timeRange.startedAtMs < end && ($0.timeRange.endedAtMs ?? 0) > start
            }
            for index in candidates.indices {
                var combined = ""
                var previousEnd = candidates[index].timeRange.startedAtMs
                for remote in candidates[index..<min(index + 4, candidates.count)] {
                    guard remote.timeRange.startedAtMs - previousEnd <= 2_000 else { break }
                    combined += normalized(remote.text)
                    previousEnd = remote.timeRange.endedAtMs!
                    let remoteStart = candidates[index].timeRange.startedAtMs
                    let overlap = min(end, previousEnd) - max(start, remoteStart)
                    let duration = max(end - start, previousEnd - remoteStart)
                    guard abs(Double(start) - Double(remoteStart)) <= 2_500,
                          abs(Double(end) - Double(previousEnd)) <= 2_500,
                          Double(overlap) / Double(duration) >= 0.65 else { continue }
                    if similar(text, combined) {
                        event.possibleEchoOf = candidates[index].id
                        return event
                    }
                }
            }
            return event
        }
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0 != "、" && $0 != "。" && !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    private static func similar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let a = Array(lhs), b = Array(rhs)
        guard min(a.count, b.count) >= 20, max(a.count, b.count) <= 2_000 else { return false }
        let limit = min(3, Int(Double(min(a.count, b.count)) * 0.08))
        guard abs(a.count - b.count) <= limit else { return false }
        // Small edits can reverse a decision or change a date/amount. Preserve
        // these differences even when the rest of the sentence is identical.
        let protected = ["ない", "なく", "ません", "反対", "賛成", "不要", "必要", "無効", "有効", "不採用", "中止", "延期", "未定"]
        guard protected.allSatisfy({ lhs.components(separatedBy: $0).count == rhs.components(separatedBy: $0).count }) else { return false }
        let numberPattern = #"[0-9０-９]+(?:[.,:/．・-][0-9０-９]+)*|[一二三四五六七八九十百千万億]+"#
        func numbers(_ value: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: numberPattern)
            return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }
        }
        guard numbers(lhs) == numbers(rhs) else { return false }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices { row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (character == b[j] ? 0 : 1)) }
            if row.min()! > limit { return false }
            previous = row
        }
        return previous[b.count] <= limit
    }
}
