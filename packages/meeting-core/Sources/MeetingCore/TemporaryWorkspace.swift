import Foundation
import Darwin

/// Only our leased, stale directories are eligible. Unknown owners are retained.
public enum TemporaryWorkspace {
    private struct Owner: Codable { let pid: Int32 }
    public static func mark(_ directory: URL, role: String = "owner") throws {
        try JSONEncoder().encode(Owner(pid: getpid())).write(to: directory.appendingPathComponent("\(role).lease"), options: .atomic)
    }
    public static func clean(in root: URL = FileManager.default.temporaryDirectory, now: Date = Date()) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
            guard ["meeting-agent-codex-", "meeting-agent-stt-"].contains(where: { directory.lastPathComponent.hasPrefix($0) }) else { continue }
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard info.isDirectory == true, info.isSymbolicLink != true,
                  let modified = info.contentModificationDate, modified < now.addingTimeInterval(-86400),
                  let ownerData = try? Data(contentsOf: directory.appendingPathComponent("owner.lease")),
                  let owner = try? JSONDecoder().decode(Owner.self, from: ownerData), dead(owner.pid) else { continue }
            let helper = directory.appendingPathComponent("helper.lease")
            if FileManager.default.fileExists(atPath: helper.path) {
                guard let data = try? Data(contentsOf: helper), let lease = try? JSONDecoder().decode(Owner.self, from: data), dead(lease.pid) else { continue }
            }
            try FileManager.default.removeItem(at: directory)
        }
    }
    private static func dead(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == -1 && errno == ESRCH }
}
