# Meeting Agent for macOS

ScreenCaptureKit captures the selected window and system audio; AVAudioEngine
captures the microphone. macOS 14+ is supported at runtime. Build with Xcode 26.4+
(or matching Command Line Tools); CI uses Xcode 26.6.

```sh
swift test
swift run MeetingVerification
sh Scripts/build-app.sh
open .build/app/MeetingAgent.app
```

Recording requires Screen Recording and Microphone access. Speech authorization
is only needed for the legacy Apple Speech provider, not to start recording.
On macOS 26, SpeechAnalyzer is the default. Settings also offer Apple Speech and
WhisperKit (pinned 0.15.0, multilingual small model). Save the selected provider,
then use the model download button before the first transcription if needed.
Downloads fetch models/tokenizers, never upload meeting audio.

Audio is saved independently of image processing and recognition. Each track has
approximately 15–20 second CAF units with about 0.5 seconds of boundary overlap,
a meeting-clock sidecar, attempt/error files, and a completion receipt. Closed
units are processed during recording; final units close when producers drain.
Speech failures leave recording running and each unit retries up to three times.
Failed units can be retried from Timeline after capture stops. Successfully saved
text remains visible until its replacement succeeds. Digital silence is recorded
as processed even when there is no text.

The Timeline shows unit completion, failures, provider, and separate recording
state. Data-change notifications, reconnection refresh, and polling keep it live.
Audio write errors are saved in `Audio/errors.json`; shared controller metrics
are in `capture-metrics.json`, including recordings started from Web UI.
Old `system.caf`/`microphone.caf` archives are imported into staged unit folders.

Settings are persisted in `settings.json` next to the database. Retention defaults
to disabled (0); selecting a positive value deletes ended meetings older than that
number of days, excluding active analysis jobs. Summary choices are the local
heuristic and Apple Foundation Models. Codex is not presented as a working choice.

`MeetingVerification` runs without XCTest or Speech permission. It checks real
CAF/SQLite persistence, recovery, silence, clock gaps, deadline, API guards, and a
30-minute dual-track PCM replay. This is accelerated replay, not a 30-minute
physical-device recording. See `docs/evaluation/README.md` for ASR comparisons.

The app bundle includes Swift package resources and is signed for local testing.
Ad-hoc signing may require renewed macOS permissions. The build uses system SQLite,
so it does not link a newer Homebrew dylib into a macOS 14 executable.
