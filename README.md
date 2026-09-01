# Meeting Agent

Local-first Meeting Intelligence for macOS. Meeting Agent captures a Google Meet window, remote system audio, and the local microphone, then builds a time-aligned evidence timeline containing transcript segments, key frames, OCR, screen descriptions, and structured summaries.

The source of truth for product and architecture decisions is [meeting-agent-handoff-design.md](meeting-agent-handoff-design.md).

## Repository layout

```text
apps/macos/                  SwiftUI capture agent
apps/web/                    React/Vite local UI
packages/meeting-core/       Timeline domain model and SQLite storage
packages/meeting-analysis/   Frame, OCR, queue, summary and privacy pipeline
packages/codex-helper/       Optional isolated Codex companion
api/openapi.yaml             Native/Web API contract
schemas/                     Portable JSON schemas
tools/evaluation/            Repeatable quality metrics
docs/adr/                    Architecture decisions
```

## Development

Requirements:

- macOS with a full Xcode installation matching the selected Swift toolchain
- Node.js 20 or later
- Screen Recording and Microphone permissions for live capture
- Apple Intelligence-capable OS/device only for the optional Foundation Models provider

Run package checks:

```sh
cd packages/meeting-core && swift test
cd packages/meeting-analysis && swift test
cd apps/macos && swift test
cd apps/web && npm install && npm test && npm run build
cd packages/codex-helper && npm test
cd tools/evaluation && node --test
```

The Codex helper and all external providers are optional. Capture, Canonical Evidence, OCR, and local browsing must continue to work when they are unavailable.

## Data safety

- Local API binds to `127.0.0.1` and still requires a session token, CSRF protection for mutations, and Origin/Host validation.
- Video is not retained by default. A short ephemeral ring buffer is cleared after normal finalization.
- External processing requires explicit, per-category consent and an audit record.
- Never add real confidential meetings to fixtures.
