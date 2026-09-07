# ADR 0001: Codex is an optional native companion

Status: accepted; native integration replaces the Node spike (2026-09-07)

## Decision

Use the installed Codex CLI through a small Swift companion bundled in `Contents/Helpers`. The TypeScript Codex SDK also controls the local CLI; calling the CLI directly avoids distributing Node in the desktop app. Audio recognition remains on-device and capture does not depend on Codex.

The capture app remains sandboxed. LaunchServices opens a private job request document in the independently signed, non-sandboxed companion. Launch arguments are not used: macOS ignores them for sandboxed callers. The companion accesses the existing login by calling `codex login status`; neither application reads or copies authentication files.

Before inference require ChatGPT login, then pass `forced_login_method="chatgpt"` and `model_provider="openai"`. Exclude API keys and endpoint overrides from the environment and ignore user Codex configuration. There is no API fallback or credit purchase. Before every inference, read `account/rateLimits/read` through the local app server. Require a remaining Codex quota window and explicit `credits.hasCredits=false`, `credits.unlimited=false`. Accounts with available extra credits, exhausted windows, or unconfirmable credit state fail closed. No reset credits are redeemed. The check is a snapshot; simultaneous usage in other Codex clients can exhaust the remaining quota before inference, which must then fail rather than fall back.

## Evidence and lifecycle

Settings disclose external transcript and optional image processing. Each request stages only the selected meeting's final text and at most 32 resized images. Raw audio remains local. Structured output must cite real transcript IDs; names additionally need short utterances and closely timed screenshots. Ambiguous identities remain unknown. Original transcripts are never rewritten by the model.

Use ephemeral threads, read-only sandbox, disabled shell/search/plugins/hooks and host skill discovery. These controls do not make inference local. Provider failures terminate the summary job without fallback or automatic repeated spending. Cancellation removes the request directory; the companion observes its removal and terminates the CLI before exiting. Save category/consent/attempt records and successful token receipts, then remove temporary inputs and logs.

## Limits

Codex has account usage limits. Its default model is recorded as `codex-default` because exec JSON does not reliably report a resolved model identifier. The app does not claim exact model provenance. One job accepts 240 KB of transcript and at most 32 images; an oversized transcript fails explicitly. Sparse saved keyframes and legacy 20-second utterances frequently cannot establish who spoke. Full speaker coverage requires finer audio timestamps and appropriate screen sampling; see issue #39. Synthetic visual checks are integration checks, not a measurement of real meeting accuracy.
