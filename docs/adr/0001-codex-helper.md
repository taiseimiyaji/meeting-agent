# ADR 0001: Codex is an optional isolated companion

Status: accepted for spike implementation

## Decision

Use Codex CLI as an optional companion process for the first integration. Do not embed Node.js or Python in the native app and do not make Codex part of capture.

Each job receives a new temporary directory containing only the explicitly approved transcript, timeline, and key frames. Codex runs with an ephemeral thread and read-only sandbox. The helper validates its output against the summary JSON Schema and deletes the directory after the result is persisted.

## Why

- Reuses an existing Codex login without copying credentials into Meeting Agent.
- Keeps Capture operational when Codex is absent, logged out, slow, or unavailable.
- Narrows filesystem visibility to one meeting job.
- Allows the integration to be removed or replaced without changing Canonical Evidence.

## Consequences

- Codex CLI installation and a compatible account remain explicit optional prerequisites.
- The app must show exactly which artifact categories will be sent and record provider, model, categories, and time.
- Network egress is inherent to this provider and must be allowed by company policy.
- Python SDK remains a future option if process lifecycle or login UI requirements outgrow the CLI adapter.
