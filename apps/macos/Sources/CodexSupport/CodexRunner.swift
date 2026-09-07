import Foundation
import Darwin
import MeetingCore

public struct CodexReceipt: Codable, Sendable {
    public var authentication: String
    public var model: String
    public var completedAt: Date
    public var inputTokens: Int?
    public var outputTokens: Int?
}

/// Run only in the non-sandboxed companion, never inside the capture app.
public struct CodexRunner: Sendable {
    public let executable: URL
    public let environment: [String: String]
    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // LaunchServices can inherit a sandbox container's HOME. Resolve the
        // account's actual home without opening or copying any login files.
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            throw CodexFailure("ユーザーのホームディレクトリを取得できませんでした。アプリを再起動してください。")
        }
        let home = String(cString: directory)
        let candidates = Self.executableCandidates(home: home, path: environment["PATH"])
        guard let path = executable?.path ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexFailure("Codex CLIを検出できませんでした。ターミナルの command -v codex で場所を確認してください。対応先: ~/.local/bin、Homebrew、npm、nvm、mise、asdf、Volta、PATH。インストール済みの場合はアプリを再起動してください。")
        }
        self.executable = URL(fileURLWithPath: path)
        // Intentionally exclude API keys, base URL/provider overrides and injected libraries.
        var clean = ["HOME": home, "PATH": URL(fileURLWithPath: path).deletingLastPathComponent().path + ":" + home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        if let value = environment["CODEX_HOME"], value.hasPrefix("/") { clean["CODEX_HOME"] = value }
        self.environment = clean
    }

    public static func executableCandidates(home: String, path: String?) -> [String] {
        var paths = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                     home + "/.npm-global/bin", home + "/.npm/bin", home + "/.volta/bin",
                     home + "/.asdf/shims", home + "/.local/share/mise/shims",
                     home + "/.codex/packages/standalone/current/bin"]
        // GUI launches do not normally inherit the terminal's PATH. Include
        // common version-manager installs without sourcing arbitrary shell RCs.
        for root in [home + "/.nvm/versions/node", home + "/.local/share/mise/installs/node"] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { root + "/" + $0 + "/bin" }
        }
        paths += (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        return paths.map { $0 + "/codex" }.filter { seen.insert($0).inserted }
    }

    public func checkLogin(directory: URL) async throws {
        let result = try await command(["login", "status"], directory: directory, name: "login", timeout: 20)
        guard result.code == 0, result.text.contains("Logged in using ChatGPT") else {
            throw CodexFailure("ChatGPTでのCodexログインが必要です。ターミナルで codex login を実行し、ChatGPTを選択してください。APIキー認証は利用しません。")
        }
    }

    public static func arguments(directory: URL, input: CodexMeetingInput) -> [String] {
        var args = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
                    "--sandbox", "read-only", "--cd", directory.path,
                    "--config", "approval_policy=\"never\"", "--config", "forced_login_method=\"chatgpt\"",
                    "--config", "model_provider=\"openai\"", "--config", "web_search=\"disabled\"",
                    "--config", "project_doc_max_bytes=0", "--config", "history.persistence=\"none\"",
                    "--output-schema", directory.appendingPathComponent("schema.json").path,
                    "--output-last-message", directory.appendingPathComponent("result.json").path, "--json"]
        for feature in ["shell_tool", "unified_exec", "shell_snapshot", "multi_agent", "plugins", "hooks", "apps", "image_generation", "view_image", "skill_search", "skill_mcp_dependency_install"] {
            args += ["--disable", feature]
        }
        args += ["--enable", "skip_host_skill_discovery"]
        for screen in input.screens { args += ["--image", directory.appendingPathComponent(screen.fileName).path] }
        return args + ["-"]
    }

    public func summarize(directory: URL) async throws {
        let input = try JSONDecoder().decode(CodexMeetingInput.self, from: Data(contentsOf: directory.appendingPathComponent("input.json")))
        try input.validate()
        try await checkLogin(directory: directory)
        let allowance = try await checkAllowance(directory: directory)
        try JSONEncoder().encode(allowance).write(to: directory.appendingPathComponent("allowance.json"), options: .atomic)
        try Data(CodexSchema.json.utf8).write(to: directory.appendingPathComponent("schema.json"), options: .atomic)
        try Data(input.prompt().utf8).write(to: directory.appendingPathComponent("prompt.txt"), options: .atomic)
        // Written BEFORE inference, so failed/limited requests are auditable too.
        try Data("chatgpt\n".utf8).write(to: directory.appendingPathComponent("submitted"), options: .atomic)
        let result = try await command(Self.arguments(directory: directory, input: input), directory: directory,
                                       name: "analysis", timeout: 240, stdin: directory.appendingPathComponent("prompt.txt"))
        guard result.code == 0 else {
            let lower = result.text.lowercased()
            if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") || lower.contains("429") {
                throw CodexFailure("Codexの利用枠またはレート制限に達しました。枠が回復してから要約を再生成してください。API課金には切り替えません。")
            }
            if lower.contains("401") || lower.contains("unauthorized") || lower.contains("token") && lower.contains("expired") {
                throw CodexFailure("Codexの認証が切れています。codex login でChatGPTにログインし直してください。")
            }
            throw CodexFailure("Codexの処理に失敗しました。CLIを最新版に更新し、ChatGPTログインと接続を確認して再生成してください。")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: Data(contentsOf: directory.appendingPathComponent("result.json")))
        try input.validate(summary)
        var receipt = CodexReceipt(authentication: "chatgpt", model: "codex-default", completedAt: Date())
        for line in result.text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "turn.completed", let usage = object["usage"] as? [String: Int] {
                receipt.inputTokens = usage["input_tokens"]; receipt.outputTokens = usage["output_tokens"]
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        try Data().write(to: directory.appendingPathComponent("completed"), options: .atomic)
    }

    private func command(_ args: [String], directory: URL, name: String, timeout: TimeInterval, stdin: URL? = nil) async throws -> (code: Int32, text: String) {
        let log = directory.appendingPathComponent("\(name).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process(); process.executableURL = executable; process.arguments = args
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardOutput = output; process.standardError = output
        let input = try stdin.map { try FileHandle(forReadingFrom: $0) }
        defer { try? input?.close() }
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline, FileManager.default.fileExists(atPath: directory.path) else {
                    throw CodexFailure("Codexの処理が制限時間を超えました。接続や利用枠を確認して再生成してください。")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size < 8_000_000 else { throw CodexFailure("Codexの応答が大きすぎるため処理を停止しました。") }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            process.terminate()
            // No tools are exposed, so this is the only analysis process to stop.
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }
}
