import Foundation
import CryptoKit
import MeetingCore
import MeetingAnalysis

public enum StorageMaintenance {
    public static func run(meetingId: String, root: URL, store: MeetingStore) throws {
        guard UUID(uuidString: meetingId) != nil else { return }
        let directory = root.appendingPathComponent(meetingId).appendingPathComponent("Audio")
        var packedUnits = 0
        for folder in [directory] + ["legacy-systemAudio", "legacy-microphone"].map({ directory.appendingPathComponent($0) }) {
            for chunk in try AudioArchiveWriter.chunks(in: folder, recoverOpen: true) {
                try Task.checkCancellation()
                guard try !store.hasLiveCapture() else { throw AnalysisDeferred("録音中は容量の最適化を待機します。") }
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(chunk.id).done").path) else { continue }
                let checked = folder.appendingPathComponent("\(chunk.id).compression-checked")
                if !FileManager.default.fileExists(atPath: checked.path) {
                    guard packedUnits < 4 else { throw AnalysisDeferred("容量の最適化を区間ごとに進めています。") }
                    packedUnits += 1
                    _ = try LosslessAudio.compact(folder.appendingPathComponent(chunk.fileName))
                    try AudioInventory.record(chunk, folder: folder, meetingId: meetingId, store: store)
                    try Data().write(to: checked, options: .atomic)
                }
            }
            try clearWorkingFiles(in: folder)
        }
        // Existing duplicate JPEGs share an inode. Every event/path remains valid.
        var originals: [String: URL] = [:]
        for screen in try store.screens(meetingId: meetingId) {
            guard try !store.hasLiveCapture() else { throw AnalysisDeferred("録音中は容量の最適化を待機します。") }
            let file = URL(fileURLWithPath: screen.imagePath).standardizedFileURL.resolvingSymlinksInPath()
            let meetingRoot = root.appendingPathComponent(meetingId).standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard file.path.hasPrefix(meetingRoot), FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let original = originals[hash], original != file {
                let link = file.deletingLastPathComponent().appendingPathComponent(".link-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: link) }
                try FileManager.default.linkItem(at: original, to: link)
                guard rename(link.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } else { originals[hash] = file }
        }
        try clearWorkingFiles(in: root.appendingPathComponent(meetingId).appendingPathComponent("KeyFrames"))
        for name in ["system", "microphone"] {
            let folder = directory.appendingPathComponent(name == "system" ? "legacy-systemAudio" : "legacy-microphone")
            let chunks = try AudioArchiveWriter.chunks(in: folder)
            if !chunks.isEmpty, chunks.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.id).done").path) }) {
                _ = try LegacyAudioVerifier.retire(directory.appendingPathComponent("\(name).caf"), chunks: chunks, folder: folder)
            }
        }
        try store.maintainDatabase()
    }
    private static func clearWorkingFiles(in folder: URL) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            guard [".inflate-", ".packing-", ".link-"].contains(where: { file.lastPathComponent.hasPrefix($0) }),
                  let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < Date().addingTimeInterval(-86400) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
}
