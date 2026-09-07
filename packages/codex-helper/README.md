# Retired Node companion spike

Production integration lives in `apps/macos/Sources/CodexSupport`, `MeetingCodexHelper`, and `MeetingPipeline/CodexCompanion.swift`. The desktop app bundles a Swift helper and calls the installed Codex CLI with ChatGPT-only authentication. It does not need Node or copy login credentials.

`runCodex` in this prototype is disabled so it cannot bypass the production authentication and evidence checks. The input-copy utilities remain for existing fixture tests. See [ADR 0001](../../docs/adr/0001-codex-helper.md).
