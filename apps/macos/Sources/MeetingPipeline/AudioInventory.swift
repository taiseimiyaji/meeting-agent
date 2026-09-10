import Foundation
import MeetingCore

/// SQLite is a rebuildable index; raw sidecars and completion receipts stay canonical.
public enum AudioInventory {
    public static func record(_ chunk: AudioChunk, folder: URL, meetingId: String, store: MeetingStore) throws {
        let done = folder.appendingPathComponent("\(chunk.id).done")
        let attempts = (try? String(contentsOf: folder.appendingPathComponent("\(chunk.id).attempt"), encoding: .utf8)).flatMap(Int.init) ?? 0
        let completed = FileManager.default.fileExists(atPath: done.path)
        let provider = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: done)))?["provider"]
        try store.indexAudio(id: chunk.id, meetingId: meetingId, folder: folder.path,
            payload: String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self),
            status: completed ? "done" : attempts >= 3 ? "failed" : "pending",
            bytes: LosslessAudio.storedSize(folder.appendingPathComponent(chunk.fileName)), provider: provider)
    }
    public static func ensure(folder: URL, meetingId: String, store: MeetingStore, recoverOpen: Bool = false) throws {
        let key = folder.path + (recoverOpen ? "#recovered" : "")
        guard store.needsAudioIndex(folder: key) else { return }
        for chunk in try AudioArchiveWriter.chunks(in: folder, recoverOpen: recoverOpen) {
            try record(chunk, folder: folder, meetingId: meetingId, store: store)
        }
        store.markAudioIndexed(folder: key)
    }
    public static func pending(folder: URL, meetingId: String, store: MeetingStore, recoverOpen: Bool, limit: Int) throws -> [AudioChunk] {
        try ensure(folder: folder, meetingId: meetingId, store: store, recoverOpen: recoverOpen)
        return try store.pendingAudioPayloads(folder: folder.path, limit: limit).map { try JSONDecoder().decode(AudioChunk.self, from: Data($0.utf8)) }
    }
}
