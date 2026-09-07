import Foundation

public struct CodexAllowance: Codable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Double?

    public static func validate(_ result: [String: Any]) throws -> CodexAllowance {
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let bucket = buckets?["codex"] ?? result["rateLimits"] as? [String: Any],
              let credits = bucket["credits"] as? [String: Any],
              credits["hasCredits"] as? Bool == false,
              credits["unlimited"] as? Bool == false else {
            throw CodexFailure("追加クレジットを使わずに処理できることを確認できません。Codex側の利用枠・クレジット設定を確認してください。要約は開始していません。")
        }
        let windows = [bucket["primary"], bucket["secondary"], bucket["individualLimit"]].compactMap { $0 as? [String: Any] }
        guard !windows.isEmpty, windows.allSatisfy({ window in
            guard let used = window["usedPercent"] as? Double else { return false }
            return used >= 0 && used < 100
        }), bucket["spendControlReached"] as? Bool != true,
           bucket["rateLimitReachedType"] == nil || bucket["rateLimitReachedType"] is NSNull else {
            throw CodexFailure("Codexのサブスクリプション利用枠が不足しています。枠の回復後に再生成してください。追加クレジットやAPI課金は利用しません。")
        }
        let mostUsed = windows.max { ($0["usedPercent"] as? Double ?? 0) < ($1["usedPercent"] as? Double ?? 0) }!
        return .init(usedPercent: mostUsed["usedPercent"] as! Double, resetsAt: mostUsed["resetsAt"] as? Double)
    }
}

extension CodexRunner {
    /// Read-only app-server RPC. No account tokens, emails or credit-reset IDs
    /// are returned to the desktop app or retained in its audit.
    public func checkAllowance(directory: URL) async throws -> CodexAllowance {
        let log = directory.appendingPathComponent("allowance-rpc.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        let pipe = Pipe()
        let process = Process(); process.executableURL = executable
        process.arguments = ["app-server", "--config", "forced_login_method=\"chatgpt\"", "--config", "model_provider=\"openai\"", "--disable", "hooks", "--disable", "plugins"]
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = pipe
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGTERM) }
            try? output.close(); try? pipe.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: log)
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try pipe.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "meeting_agent", "version": "0.1"], "capabilities": [:]]])
        let deadline = Date().addingTimeInterval(20)
        var initialized = false
        while Date() < deadline && process.isRunning {
            try Task.checkCancellation()
            let data = try Data(contentsOf: log)
            guard data.count < 256_000 else { break }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = object["id"] as? Int else { continue }
                if id == 1 && !initialized {
                    guard object["error"] == nil else { throw CodexFailure("Codexの利用枠確認を開始できませんでした。CLIを更新してください。") }
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["method": "account/rateLimits/read", "id": 2])
                }
                if id == 2 {
                    guard let result = object["result"] as? [String: Any] else { throw CodexFailure("Codexの利用枠を確認できません。接続とChatGPTログインを確認してください。") }
                    return try CodexAllowance.validate(result)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CodexFailure("Codexの利用枠確認がタイムアウトしました。送信せずに停止しました。")
    }
}
