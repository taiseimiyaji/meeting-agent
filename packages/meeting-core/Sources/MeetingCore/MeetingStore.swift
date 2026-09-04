import CSQLite
import Foundation

public enum MeetingStoreError: Error, Equatable, LocalizedError {
    case open(String), sqlite(String), staleRevision(current: Int, attempted: Int), finalizedTranscript(String), invalidData(String)
    public var errorDescription: String? {
        switch self {
        case .open(let message), .sqlite(let message), .invalidData(let message): message
        case .staleRevision(let current, let attempted): "Stale transcript revision \(attempted); current is \(current)"
        case .finalizedTranscript(let id): "Transcript \(id) is already final"
        }
    }
}

public struct RecoveryReport: Equatable, Sendable {
    public var interruptedMeetingIds: [String]
    public var recoveredJobCount: Int
    public init(interruptedMeetingIds: [String], recoveredJobCount: Int) {
        self.interruptedMeetingIds = interruptedMeetingIds; self.recoveredJobCount = recoveredJobCount
    }
}

public enum AnalysisJobStatus: String, Codable, Sendable { case pending, processing, completed, failed }

public struct AnalysisJob: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var meetingId: String; public var kind: String
    public var status: AnalysisJobStatus; public var retryCount: Int; public var error: String?
    public var priority: Int; public var availableAt: Date
    public init(id: String = UUID().uuidString, meetingId: String, kind: String, status: AnalysisJobStatus = .pending, retryCount: Int = 0, error: String? = nil, priority: Int = 1, availableAt: Date = Date()) {
        self.id = id; self.meetingId = meetingId; self.kind = kind; self.status = status; self.retryCount = retryCount; self.error = error
        self.priority = priority; self.availableAt = availableAt
    }
}

/// A small, dependency-free SQLite repository. Each operation is serialized;
/// WAL lets capture writes coexist with readers in other processes.
public final class MeetingStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw MeetingStoreError.open(message)
        }
        db = handle
        do { try migrate() } catch { sqlite3_close(handle); db = nil; throw error }
    }

    deinit { if let db { sqlite3_close(db) } }

    public var schemaVersion: Int {
        Int((try? scalarInt("PRAGMA user_version")) ?? 0)
    }

    public func migrate() throws {
        try locked {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            let version = try scalarInt("PRAGMA user_version")
            guard version <= 2 else { throw MeetingStoreError.invalidData("Database schema \(version) is newer than supported schema 2") }
            if version == 0 {
                try transaction {
                    try execute(Self.migrationV1)
                    try execute("PRAGMA user_version = 1")
                }
            }
            if version < 2 {
                try transaction {
                    try execute(Self.migrationV2)
                    try execute("PRAGMA user_version = 2")
                }
            }
        }
    }

    public func save(_ meeting: Meeting) throws {
        let now = Self.date(Date())
        try run("""
            INSERT INTO meetings(id,title,started_at,ended_at,capture_clock_origin,status,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, ended_at=excluded.ended_at,
              status=excluded.status, updated_at=excluded.updated_at
            """, [.text(meeting.id), .optionalText(meeting.title), .text(Self.date(meeting.startedAt)),
                    .optionalText(meeting.endedAt.map(Self.date)), .text(Self.date(meeting.captureClockOrigin)),
                    .text(meeting.status.rawValue), .text(now), .text(now)])
    }

    /// Upserts a partial revision. Final evidence cannot be altered, and older
    /// async STT results cannot overwrite a newer revision.
    public func save(_ event: TranscriptEvent) throws {
        try transaction { try saveTranscriptWithinTransaction(event) }
    }

    /// At capture finalization, the newest partial revision is the best durable
    /// evidence available when Speech did not emit its final callback in time.
    @discardableResult public func finalizePartialTranscripts(meetingId: String) throws -> Int {
        try changeCount(
            "UPDATE transcript_events SET is_final=1,updated_at=? WHERE meeting_id=? AND is_final=0 AND length(trim(text))>0",
            [.text(Self.date(Date())), .text(meetingId)]
        )
    }

    public func replaceTranscripts(meetingId: String, with events: [TranscriptEvent]) throws {
        guard events.allSatisfy({ $0.meetingId == meetingId }) else {
            throw MeetingStoreError.invalidData("Replacement transcript belongs to another meeting")
        }
        try transaction {
            try run("DELETE FROM transcript_events WHERE meeting_id=?", [.text(meetingId)])
            for event in events { try saveTranscriptWithinTransaction(event) }
        }
    }

    private func saveTranscriptWithinTransaction(_ event: TranscriptEvent) throws {
        if let existing = try transcriptState(id: event.id) {
            guard event.revision >= existing.revision else { throw MeetingStoreError.staleRevision(current: existing.revision, attempted: event.revision) }
            if existing.isFinal && (event.revision != existing.revision || !event.isFinal) {
                throw MeetingStoreError.finalizedTranscript(event.id)
            }
        }
        let now = Self.date(Date())
        try run("""
            INSERT INTO transcript_events(id,meeting_id,revision,started_at_ms,ended_at_ms,speaker,source,text,is_final,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,started_at_ms=excluded.started_at_ms,
              ended_at_ms=excluded.ended_at_ms,speaker=excluded.speaker,source=excluded.source,text=excluded.text,
              is_final=excluded.is_final,updated_at=excluded.updated_at
            """, [.text(event.id), .text(event.meetingId), .integer(Int64(event.revision)), .integer(event.timeRange.startedAtMs),
                    .optionalInteger(event.timeRange.endedAtMs), .text(event.speaker.rawValue), .text(event.source.rawValue),
                    .text(event.text), .integer(event.isFinal ? 1 : 0), .text(now), .text(now)])
        try run("DELETE FROM transcript_screen_refs WHERE transcript_id=?", [.text(event.id)])
        for reference in event.screenRefs { try relate(transcriptId: event.id, reference: reference) }
    }

    public func save(_ screen: ScreenEvent) throws {
        let now = Self.date(Date())
        try run("""
            INSERT INTO screen_events(id,meeting_id,started_at_ms,ended_at_ms,image_path,ocr,description,analysis_status,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET ended_at_ms=excluded.ended_at_ms,image_path=excluded.image_path,
              ocr=excluded.ocr,description=excluded.description,analysis_status=excluded.analysis_status,updated_at=excluded.updated_at
            """, [.text(screen.id), .text(screen.meetingId), .integer(screen.timeRange.startedAtMs), .optionalInteger(screen.timeRange.endedAtMs),
                    .text(screen.imagePath), .optionalText(screen.ocr), .optionalText(screen.description), .text(screen.analysisStatus.rawValue),
                    .text(now), .text(now)])
    }

    public func relate(transcriptId: String, reference: ScreenReference) throws {
        try run("""
            INSERT INTO transcript_screen_refs(transcript_id,screen_id,relation,overlap_ms,confidence,provider)
            VALUES(?,?,?,?,?,?) ON CONFLICT(transcript_id,screen_id,relation) DO UPDATE SET
              overlap_ms=excluded.overlap_ms,confidence=excluded.confidence,provider=excluded.provider
            """, [.text(transcriptId), .text(reference.screenId), .text(reference.relation.rawValue),
                    .optionalInteger(reference.overlapMs), .optionalDouble(reference.confidence), .optionalText(reference.provider)])
    }

    public func associateVisibleScreens(transcriptId: String) throws -> [ScreenReference] {
        guard var transcript = try transcript(id: transcriptId) else { throw MeetingStoreError.invalidData("Unknown transcript \(transcriptId)") }
        let screens = try screens(meetingId: transcript.meetingId)
        let refs = ScreenAssociator.visibleScreens(for: transcript, screens: screens)
        transcript.screenRefs = refs
        try save(transcript)
        return refs
    }

    public func timeline(meetingId: String) throws -> Timeline? {
        guard let meeting = try meeting(id: meetingId) else { return nil }
        return Timeline(meeting: meeting, transcripts: try transcripts(meetingId: meetingId), screens: try screens(meetingId: meetingId))
    }

    public func enqueue(_ job: AnalysisJob) throws {
        let now = Self.date(Date())
        try run("""
            INSERT INTO analysis_jobs(id,meeting_id,kind,status,retry_count,error,created_at,updated_at,priority,available_at)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,retry_count=excluded.retry_count,error=excluded.error,priority=excluded.priority,available_at=excluded.available_at,updated_at=excluded.updated_at
            """, [.text(job.id),.text(job.meetingId),.text(job.kind),.text(job.status.rawValue),.integer(Int64(job.retryCount)),.optionalText(job.error),.text(now),.text(now),.integer(Int64(job.priority)),.text(Self.date(job.availableAt))])
    }

    /// Enqueues work only when the same meeting/kind is not already pending or
    /// processing. Completed/failed jobs do not prevent an explicit rerun.
    @discardableResult public func enqueueIfNeeded(_ job: AnalysisJob) throws -> Bool {
        let now = Self.date(Date())
        return try changeCount("""
            INSERT INTO analysis_jobs(id,meeting_id,kind,status,retry_count,error,created_at,updated_at,priority,available_at)
            SELECT ?,?,?,?,?,?,?,?,?,?
            WHERE NOT EXISTS (
              SELECT 1 FROM analysis_jobs WHERE meeting_id=? AND kind=? AND status IN ('pending','processing')
            )
            """, [.text(job.id), .text(job.meetingId), .text(job.kind), .text(job.status.rawValue),
                    .integer(Int64(job.retryCount)), .optionalText(job.error), .text(now), .text(now),
                    .integer(Int64(job.priority)), .text(Self.date(job.availableAt)), .text(job.meetingId), .text(job.kind)]) == 1
    }

    /// Claims one ready job in priority/FIFO order. BEGIN IMMEDIATE makes the
    /// select-and-transition atomic across multiple store connections.
    public func claimNextAnalysisJob(now: Date = Date()) throws -> AnalysisJob? {
        try transaction {
            var claimed: AnalysisJob?
            try query("""
                SELECT id,meeting_id,kind,status,retry_count,error,priority,available_at
                FROM analysis_jobs WHERE status='pending' AND available_at<=?
                ORDER BY priority DESC,available_at ASC,created_at ASC,id ASC LIMIT 1
                """, [.text(Self.date(now))]) { claimed = try decodeJob($0) }
            guard var job = claimed else { return nil }
            let updated = try changeCount("UPDATE analysis_jobs SET status='processing',updated_at=? WHERE id=? AND status='pending'", [.text(Self.date(now)), .text(job.id)])
            guard updated == 1 else { return nil }
            job.status = .processing
            return job
        }
    }

    public func completeAnalysisJob(id: String, now: Date = Date()) throws {
        guard try changeCount("UPDATE analysis_jobs SET status='completed',error=NULL,updated_at=? WHERE id=? AND status='processing'", [.text(Self.date(now)), .text(id)]) == 1 else {
            throw MeetingStoreError.invalidData("Analysis job \(id) is not processing")
        }
    }

    @discardableResult public func retryAnalysisJob(id: String, error message: String, availableAt: Date, now: Date = Date()) throws -> AnalysisJob {
        guard try changeCount("UPDATE analysis_jobs SET status='pending',retry_count=retry_count+1,error=?,available_at=?,updated_at=? WHERE id=? AND status='processing'", [.text(message), .text(Self.date(availableAt)), .text(Self.date(now)), .text(id)]) == 1,
              let job = try analysisJob(id: id) else { throw MeetingStoreError.invalidData("Analysis job \(id) is not processing") }
        return job
    }

    public func failAnalysisJob(id: String, error message: String, now: Date = Date()) throws {
        guard try changeCount("UPDATE analysis_jobs SET status='failed',error=?,updated_at=? WHERE id=? AND status='processing'", [.text(message), .text(Self.date(now)), .text(id)]) == 1 else {
            throw MeetingStoreError.invalidData("Analysis job \(id) is not processing")
        }
    }

    public func pendingAnalysisJobCount(now: Date? = nil) throws -> Int {
        if let now { return Int(try scalarInt("SELECT count(*) FROM analysis_jobs WHERE status='pending' AND available_at<='\(Self.date(now))'")) }
        return Int(try scalarInt("SELECT count(*) FROM analysis_jobs WHERE status='pending'"))
    }

    public func analysisJob(id: String) throws -> AnalysisJob? {
        var job: AnalysisJob?
        try query("SELECT id,meeting_id,kind,status,retry_count,error,priority,available_at FROM analysis_jobs WHERE id=?", [.text(id)]) { job = try decodeJob($0) }
        return job
    }

    public func latestAnalysisJob(meetingId: String, kind: String) throws -> AnalysisJob? {
        var job: AnalysisJob?
        try query("""
            SELECT id,meeting_id,kind,status,retry_count,error,priority,available_at
            FROM analysis_jobs WHERE meeting_id=? AND kind=?
            ORDER BY updated_at DESC,created_at DESC LIMIT 1
            """, [.text(meetingId), .text(kind)]) { job = try decodeJob($0) }
        return job
    }

    /// Called at launch. Capture sessions and in-flight analysis did not survive
    /// process termination, so they become explicitly recoverable states.
    @discardableResult public func recoverInterruptedWork() throws -> RecoveryReport {
        try transaction {
            let ids = try strings("SELECT id FROM meetings WHERE status IN ('capturing','finalizing','analyzing') ORDER BY id")
            let now = Self.date(Date())
            try run("UPDATE meetings SET status='interrupted',updated_at=? WHERE status IN ('capturing','finalizing','analyzing')", [.text(now)])
            let recovered = Int(try scalarInt("SELECT count(*) FROM analysis_jobs WHERE status='processing'"))
            try run("UPDATE analysis_jobs SET status='pending',retry_count=retry_count+1,error='Process interrupted',available_at=?,updated_at=? WHERE status='processing'", [.text(now), .text(now)])
            return RecoveryReport(interruptedMeetingIds: ids, recoveredJobCount: recovered)
        }
    }

    // MARK: Reads
    public func meeting(id: String) throws -> Meeting? {
        var result: Meeting?
        try query("SELECT id,title,started_at,ended_at,capture_clock_origin,status FROM meetings WHERE id=?", [.text(id)]) { row in
            guard let started = Self.parse(row.text(2)), let origin = Self.parse(row.text(4)), let status = MeetingStatus(rawValue: row.text(5) ?? "") else { throw MeetingStoreError.invalidData("Invalid meeting row") }
            result = Meeting(id: row.text(0)!, title: row.text(1), startedAt: started, endedAt: Self.parse(row.text(3)), captureClockOrigin: origin, status: status)
        }
        return result
    }

    public func meetings(limit: Int = 20, before: Date? = nil) throws -> [Meeting] {
        let boundedLimit = min(max(limit, 1), 100)
        var values: [Meeting] = []
        let sql: String
        let parameters: [Value]
        if let before {
            sql = "SELECT id,title,started_at,ended_at,capture_clock_origin,status FROM meetings WHERE started_at < ? ORDER BY started_at DESC,id DESC LIMIT ?"
            parameters = [.text(Self.date(before)), .integer(Int64(boundedLimit))]
        } else {
            sql = "SELECT id,title,started_at,ended_at,capture_clock_origin,status FROM meetings ORDER BY started_at DESC,id DESC LIMIT ?"
            parameters = [.integer(Int64(boundedLimit))]
        }
        try query(sql, parameters) { row in
            guard let started = Self.parse(row.text(2)), let origin = Self.parse(row.text(4)),
                  let status = MeetingStatus(rawValue: row.text(5) ?? "") else {
                throw MeetingStoreError.invalidData("Invalid meeting row")
            }
            values.append(Meeting(id: row.text(0)!, title: row.text(1), startedAt: started,
                                  endedAt: Self.parse(row.text(3)), captureClockOrigin: origin, status: status))
        }
        return values
    }

    public func activeSummary(meetingId: String) throws -> MeetingSummary? {
        var value: MeetingSummary?
        try query("SELECT summary,payload_json FROM summaries WHERE meeting_id=? AND is_active=1 ORDER BY created_at DESC LIMIT 1", [.text(meetingId)]) { row in
            if let payload = row.text(1), let data = payload.data(using: .utf8) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                value = try decoder.decode(MeetingSummary.self, from: data)
            } else {
                value = MeetingSummary(summary: row.text(0) ?? "")
            }
        }
        return value
    }

    public func saveSummary(_ record: SummaryRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(record.value)
        guard let payloadJSON = String(data: payload, encoding: .utf8) else {
            throw MeetingStoreError.invalidData("Summary JSON is not UTF-8")
        }
        try transaction {
            if record.isActive {
                try run("UPDATE summaries SET is_active=0 WHERE meeting_id=?", [.text(record.meetingId)])
            }
            try run("""
                INSERT INTO summaries(id,meeting_id,provider,model,model_version,prompt_version,summary,payload_json,status,is_active,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET provider=excluded.provider,model=excluded.model,
                  model_version=excluded.model_version,prompt_version=excluded.prompt_version,summary=excluded.summary,
                  payload_json=excluded.payload_json,status=excluded.status,is_active=excluded.is_active
                """, [.text(record.id), .text(record.meetingId), .text(record.provider), .optionalText(record.model),
                        .optionalText(record.modelVersion), .optionalText(record.promptVersion), .text(record.value.summary),
                        .text(payloadJSON), .text(record.status), .integer(record.isActive ? 1 : 0), .text(Self.date(record.createdAt))])
        }
    }

    public func transcript(id: String) throws -> TranscriptEvent? {
        var result: TranscriptEvent?
        try query("SELECT id,meeting_id,revision,started_at_ms,ended_at_ms,speaker,source,text,is_final FROM transcript_events WHERE id=?", [.text(id)]) { row in result = try decodeTranscript(row) }
        if var value = result { value.screenRefs = try references(transcriptId: value.id); return value }
        return nil
    }

    public func transcripts(meetingId: String) throws -> [TranscriptEvent] {
        var values: [TranscriptEvent] = []
        try query("SELECT id,meeting_id,revision,started_at_ms,ended_at_ms,speaker,source,text,is_final FROM transcript_events WHERE meeting_id=? ORDER BY started_at_ms,id", [.text(meetingId)]) { row in values.append(try decodeTranscript(row)) }
        for index in values.indices { values[index].screenRefs = try references(transcriptId: values[index].id) }
        return values
    }

    public func screens(meetingId: String) throws -> [ScreenEvent] {
        var values: [ScreenEvent] = []
        try query("SELECT id,meeting_id,started_at_ms,ended_at_ms,image_path,ocr,description,analysis_status FROM screen_events WHERE meeting_id=? ORDER BY started_at_ms,id", [.text(meetingId)]) { row in
            guard let status = ScreenAnalysisStatus(rawValue: row.text(7) ?? "") else { throw MeetingStoreError.invalidData("Invalid screen status") }
            values.append(ScreenEvent(id: row.text(0)!, meetingId: row.text(1)!, timeRange: TimeRange(startedAtMs: row.int(2), endedAtMs: row.optionalInt(3)), imagePath: row.text(4)!, ocr: row.text(5), description: row.text(6), analysisStatus: status))
        }
        return values
    }

    public func screen(id: String) throws -> ScreenEvent? {
        var value: ScreenEvent?
        try query("SELECT id,meeting_id,started_at_ms,ended_at_ms,image_path,ocr,description,analysis_status FROM screen_events WHERE id=?", [.text(id)]) { row in
            guard let status = ScreenAnalysisStatus(rawValue: row.text(7) ?? "") else {
                throw MeetingStoreError.invalidData("Invalid screen status")
            }
            value = ScreenEvent(id: row.text(0)!, meetingId: row.text(1)!,
                                timeRange: TimeRange(startedAtMs: row.int(2), endedAtMs: row.optionalInt(3)),
                                imagePath: row.text(4)!, ocr: row.text(5), description: row.text(6), analysisStatus: status)
        }
        return value
    }

    private func references(transcriptId: String) throws -> [ScreenReference] {
        var values: [ScreenReference] = []
        try query("SELECT screen_id,relation,overlap_ms,confidence,provider FROM transcript_screen_refs WHERE transcript_id=? ORDER BY overlap_ms DESC", [.text(transcriptId)]) { row in
            guard let relation = ScreenRelation(rawValue: row.text(1) ?? "") else { throw MeetingStoreError.invalidData("Invalid screen relation") }
            values.append(ScreenReference(screenId: row.text(0)!, relation: relation, overlapMs: row.optionalInt(2), confidence: row.optionalDouble(3), provider: row.text(4)))
        }
        return values
    }

    private func decodeTranscript(_ row: Row) throws -> TranscriptEvent {
        guard let speaker = Speaker(rawValue: row.text(5) ?? ""), let source = AudioSource(rawValue: row.text(6) ?? "") else { throw MeetingStoreError.invalidData("Invalid transcript row") }
        return TranscriptEvent(id: row.text(0)!, meetingId: row.text(1)!, revision: Int(row.int(2)), timeRange: TimeRange(startedAtMs: row.int(3), endedAtMs: row.optionalInt(4)), speaker: speaker, text: row.text(7)!, source: source, isFinal: row.int(8) != 0)
    }

    private func transcriptState(id: String) throws -> (revision: Int, isFinal: Bool)? {
        var state: (Int, Bool)?
        try query("SELECT revision,is_final FROM transcript_events WHERE id=?", [.text(id)]) { state = (Int($0.int(0)), $0.int(1) != 0) }
        return state
    }

    private func decodeJob(_ row: Row) throws -> AnalysisJob {
        guard let status = AnalysisJobStatus(rawValue: row.text(3) ?? ""), let available = Self.parse(row.text(7)) else { throw MeetingStoreError.invalidData("Invalid analysis job row") }
        return AnalysisJob(id: row.text(0)!, meetingId: row.text(1)!, kind: row.text(2)!, status: status, retryCount: Int(row.int(4)), error: row.text(5), priority: Int(row.int(6)), availableAt: available)
    }

    // MARK: SQLite plumbing
    private enum Value { case text(String), integer(Int64), double(Double), null
        static func optionalText(_ value: String?) -> Value { value.map(Value.text) ?? .null }
        static func optionalInteger(_ value: Int64?) -> Value { value.map(Value.integer) ?? .null }
        static func optionalDouble(_ value: Double?) -> Value { value.map(Value.double) ?? .null }
    }
    private struct Row {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
        func optionalInt(_ i: Int32) -> Int64? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : int(i) }
        func optionalDouble(_ i: Int32) -> Double? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_double(statement, i) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func transaction<T>(_ body: () throws -> T) throws -> T { try locked { try execute("BEGIN IMMEDIATE"); do { let value = try body(); try execute("COMMIT"); return value } catch { try? execute("ROLLBACK"); throw error } } }
    private func execute(_ sql: String) throws {
        try locked {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &message)
            guard result == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "SQLite execution failed"
                sqlite3_free(message)
                throw MeetingStoreError.sqlite(text)
            }
        }
    }
    private func run(_ sql: String, _ values: [Value]) throws { try query(sql, values) { _ in } }
    private func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        try locked {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1); let result: Int32
                switch value {
                case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
                case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
                case .double(let value): result = sqlite3_bind_double(statement, index, value)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw error() }
            }
            while true { let result = sqlite3_step(statement); if result == SQLITE_ROW { try row(Row(statement: statement)) } else if result == SQLITE_DONE { break } else { throw error() } }
        }
    }
    private func scalarInt(_ sql: String) throws -> Int64 { var value: Int64 = 0; try query(sql) { value = $0.int(0) }; return value }
    private func changeCount(_ sql: String, _ values: [Value]) throws -> Int { try run(sql, values); return Int(sqlite3_changes(db)) }
    private func strings(_ sql: String) throws -> [String] { var value: [String] = []; try query(sql) { if let text = $0.text(0) { value.append(text) } }; return value }
    private func error() -> MeetingStoreError { .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite is closed") }

    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func parse(_ value: String?) -> Date? { value.flatMap { ISO8601DateFormatter().date(from: $0) } }

    private static let migrationV1 = """
    CREATE TABLE meetings(id TEXT PRIMARY KEY,title TEXT,started_at TEXT NOT NULL,ended_at TEXT,capture_clock_origin TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
    CREATE TABLE transcript_events(id TEXT PRIMARY KEY,meeting_id TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),started_at_ms INTEGER NOT NULL CHECK(started_at_ms>=0),ended_at_ms INTEGER,speaker TEXT NOT NULL,source TEXT NOT NULL,text TEXT NOT NULL,is_final INTEGER NOT NULL DEFAULT 0 CHECK(is_final IN(0,1)),created_at TEXT NOT NULL,updated_at TEXT NOT NULL,FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,CHECK(ended_at_ms IS NULL OR ended_at_ms>=started_at_ms));
    CREATE TABLE screen_events(id TEXT PRIMARY KEY,meeting_id TEXT NOT NULL,started_at_ms INTEGER NOT NULL CHECK(started_at_ms>=0),ended_at_ms INTEGER,image_path TEXT NOT NULL,ocr TEXT,description TEXT,analysis_status TEXT NOT NULL DEFAULT 'pending',created_at TEXT NOT NULL,updated_at TEXT NOT NULL,FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,CHECK(ended_at_ms IS NULL OR ended_at_ms>=started_at_ms));
    CREATE TABLE transcript_screen_refs(transcript_id TEXT NOT NULL,screen_id TEXT NOT NULL,relation TEXT NOT NULL,overlap_ms INTEGER,confidence REAL,provider TEXT,PRIMARY KEY(transcript_id,screen_id,relation),FOREIGN KEY(transcript_id) REFERENCES transcript_events(id) ON DELETE CASCADE,FOREIGN KEY(screen_id) REFERENCES screen_events(id) ON DELETE CASCADE,CHECK(overlap_ms IS NULL OR overlap_ms>=0),CHECK(confidence IS NULL OR confidence BETWEEN 0 AND 1));
    CREATE TABLE analysis_jobs(id TEXT PRIMARY KEY,meeting_id TEXT NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,retry_count INTEGER NOT NULL DEFAULT 0,error TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE);
    CREATE TABLE summaries(id TEXT PRIMARY KEY,meeting_id TEXT NOT NULL,provider TEXT NOT NULL,model TEXT,model_version TEXT,prompt_version TEXT,summary TEXT NOT NULL,payload_json TEXT,status TEXT NOT NULL,is_active INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE);
    CREATE INDEX idx_transcript_meeting_time ON transcript_events(meeting_id,started_at_ms);
    CREATE INDEX idx_screen_meeting_time ON screen_events(meeting_id,started_at_ms);
    CREATE INDEX idx_summary_meeting_created ON summaries(meeting_id,created_at);
    CREATE INDEX idx_jobs_status ON analysis_jobs(status,created_at);
    """
    private static let migrationV2 = """
    ALTER TABLE analysis_jobs ADD COLUMN priority INTEGER NOT NULL DEFAULT 1;
    ALTER TABLE analysis_jobs ADD COLUMN available_at TEXT;
    UPDATE analysis_jobs SET available_at=created_at WHERE available_at IS NULL;
    CREATE INDEX idx_jobs_ready ON analysis_jobs(status,available_at,priority DESC,created_at);
    """
}
