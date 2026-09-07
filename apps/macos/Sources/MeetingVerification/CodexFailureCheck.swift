import Foundation
import CodexSupport
import MeetingCore

func verifyCodexFailurePaths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-failure-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = CodexMeetingInput(transcripts: [.init(id: "t1", meetingId: "test", timeRange: .init(startedAtMs: 0, endedAtMs: 1000), text: "検証用の発話", source: .system, isFinal: true)], screens: [], omittedScreenCount: 0)
    try JSONEncoder().encode(input).write(to: root.appendingPathComponent("input.json"))
    let executable = root.appendingPathComponent("fixture-codex")
    try Data("#!/bin/sh\nprintf '%s\\n' 'Logged in using an API key' >&2\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runner = try CodexRunner(executable: executable)
    do { try await runner.summarize(directory: root); throw VerificationError(message: "API-key login was accepted") }
    catch let error as CodexFailure { try check(error.message.contains("APIキー認証"), "API login fails with actionable guidance") }
    try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("analysis.log").path), "API login never reaches inference")
    let limited = #"""
    #!/bin/sh
    if [ "$1" = "login" ]; then
      printf '%s\n' 'Logged in using ChatGPT'
      exit 0
    fi
    if [ "$1" = "app-server" ]; then
      while IFS= read -r request; do
        case "$request" in
          *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
          *'rateLimits'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":100},"credits":{"hasCredits":false,"unlimited":false}}}}' ;;
        esac
      done
    fi
    exit 1
    """#
    try Data(limited.utf8).write(to: executable)
    do { try await runner.summarize(directory: root); throw VerificationError(message: "exhausted quota was accepted") }
    catch let error as CodexFailure { try check(error.message.contains("利用枠が不足"), "real RPC transport rejects exhausted quota") }
    try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("submitted").path), "exhausted quota stops before sending meeting content")
}
