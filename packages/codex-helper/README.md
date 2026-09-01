# Optional Codex summarizer helper

This package is an optional companion; it is not required by the native capture agent.

It copies only user-approved meeting artifacts to a per-job temporary directory and runs Codex with:

- an ephemeral thread;
- a read-only sandbox;
- no interactive approvals;
- a structured output schema;
- the meeting-scoped directory as its working directory.

The caller must present and persist `ExternalProcessingConsent` before invoking the helper. Always call `cleanupIsolatedInput` after success or failure.

The helper intentionally does not inherit arbitrary environment variables. Existing Codex login is discovered by the Codex runtime itself.
