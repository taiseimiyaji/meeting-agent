# Meeting Agent for macOS

SwiftUI shell and capture spike for macOS 14 or later. ScreenCaptureKit emits the
selected Chrome window and its system audio as separate events. AVFoundation emits
the local microphone as a third event. All events are normalized by `CaptureClock`.

## Build and test

Full Xcode (matching its macOS SDK) is recommended:

```sh
swift test
sh Scripts/build-app.sh
open .build/app/MeetingAgent.app
```

The app requests Screen Recording and Microphone access. After changing Screen
Recording permission, macOS may require restarting the app. Select the Meet window,
start capture, and verify all three counters advance. System and microphone audio
are stored locally under each meeting's `Audio/` directory as recovery evidence.
When live transcription produces no text, the app automatically retries from these
files; a manual retry and its progress are available in the meeting Timeline.

The Swift package remains directly buildable for CI, while `build-app.sh` assembles
an ad-hoc signed app bundle with usage descriptions and sandbox entitlements needed
for permission testing.
