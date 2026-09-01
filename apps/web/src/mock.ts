import type { CaptureStatus, Meeting, MeetingDetail, MeetingSummary, ScreenEvent, ServerEvent, Settings, TranscriptEvent } from "./types";

const now = Date.now();
export const meetings: Meeting[] = [
  { id: "mtg-live", title: "プロダクト定例", startedAt: new Date(now - 1_812_000).toISOString(), status: "capturing" },
  { id: "mtg-architecture", title: "OAuth アーキテクチャレビュー", startedAt: new Date(now - 86_400_000).toISOString(), endedAt: new Date(now - 82_800_000).toISOString(), status: "partially_completed" },
  { id: "mtg-kickoff", title: "Meeting Agent キックオフ", startedAt: new Date(now - 172_800_000).toISOString(), endedAt: new Date(now - 169_800_000).toISOString(), status: "completed" },
];
export const transcripts: Record<string, TranscriptEvent[]> = {
  "mtg-live": [
    { id: "u-1", revision: 1, startedAtMs: 1_780_000, endedAtMs: 1_784_600, speaker: "remote", text: "次は画面共有の差分判定を確認しましょう。", source: "system_audio", isFinal: true, screenRefs: [{ screenId: "screen-018", relation: "visible_during_speech", overlapMs: 4600, confidence: .98 }] },
    { id: "u-2", revision: 3, startedAtMs: 1_808_000, speaker: "self", text: "安定時間を入れた結果は…", source: "microphone", isFinal: false, screenRefs: [{ screenId: "screen-019", relation: "visible_during_speech", confidence: .91 }] },
  ],
  "mtg-architecture": [
    { id: "u-42", revision: 3, startedAtMs: 1_812_000, endedAtMs: 1_815_800, speaker: "self", text: "ここは OAuth 2.1 に準拠させたいです。", source: "microphone", isFinal: true, screenRefs: [{ screenId: "screen-018", relation: "visible_during_speech", overlapMs: 3100, confidence: .96 }] },
    { id: "u-43", revision: 1, startedAtMs: 1_843_000, endedAtMs: 1_847_200, speaker: "remote", text: "Resource Server 側では aud もチェックしますか？", source: "system_audio", isFinal: true, screenRefs: [{ screenId: "screen-018", relation: "visible_during_speech", overlapMs: 4200, confidence: .99 }] },
  ],
};
const svg = (label: string) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="960" height="540"><rect width="100%" height="100%" fill="#10231f"/><rect x="70" y="65" width="820" height="410" rx="18" fill="#edf3ee"/><text x="120" y="150" font-family="sans-serif" font-size="35" fill="#112b25">${label}</text><path d="M180 270h180m60 0h180m60 0h120" stroke="#2c7865" stroke-width="8"/><circle cx="390" cy="270" r="20" fill="#e3a52e"/><circle cx="630" cy="270" r="20" fill="#e3a52e"/></svg>`)}`;
export const screens: Record<string, ScreenEvent[]> = {
  "mtg-live": [{ id: "screen-019", startedAtMs: 1_790_000, imageUrl: svg("Key frame stability results"), ocr: "Key Frame / stability 600ms", description: "Key Frame安定時間の比較結果", analysisStatus: "running" }],
  "mtg-architecture": [{ id: "screen-018", startedAtMs: 1_805_000, endedAtMs: 2_022_000, imageUrl: svg("OAuth 2.1 Architecture"), ocr: "OAuth 2.1 / PKCE / Resource Server", description: "OAuth 認証フローのアーキテクチャ図", analysisStatus: "completed" }],
};
export const summaries: Record<string, MeetingSummary> = {
  "mtg-architecture": { summary: "OAuth 2.1準拠を軸に、PKCEとResource Serverでのaud検証方針を議論した。画面解析の一部のみ失敗したが、文字起こしと要約は完了している。", decisions: [{ text: "Authorization Code + PKCEを採用する", evidenceIds: ["u-42"] }, { text: "Resource Serverでaudを検証する", evidenceIds: ["u-43"] }], actionItems: [{ text: "脅威モデルを更新する", evidenceIds: ["u-42", "screen-018"], assignee: "佐藤", dueAt: "2026-09-05T09:00:00+09:00" }], openQuestions: [{ text: "legacy clientの移行期限をいつにするか", evidenceIds: ["u-43"] }], topics: ["OAuth 2.1", "PKCE", "Token validation"] },
};
export let capture: CaptureStatus = { status: "capturing", meetingId: "mtg-live", videoFrames: 1812, systemAudioRms: .22, microphoneRms: .16 };
export let settings: Settings = { sttProvider: "apple_speech", summaryProvider: "apple_foundation_models", retentionDays: 30, recoveryMode: false };

export function detail(id: string): MeetingDetail | undefined {
  const m = meetings.find((item) => item.id === id);
  return m ? { ...m } : undefined;
}
export function updateCapture(next: CaptureStatus) { capture = next; }
export function updateSettings(next: Settings) { settings = next; }
export function subscribeMock(onEvent: (event: ServerEvent) => void) {
  const timer = window.setInterval(() => {
    if (capture.status !== "capturing" || !capture.meetingId) return;
    const meetingId = capture.meetingId;
    capture = { ...capture, videoFrames: capture.videoFrames + 5 };
    onEvent({ type: "transcript.partial", meetingId, payload: { id: "u-2", revision: 4, startedAtMs: 1_808_000, speaker: "self", text: "安定時間を入れた結果は、誤検出が減っています…", source: "microphone", isFinal: false, screenRefs: [{ screenId: "screen-019", relation: "visible_during_speech", confidence: .93 }] } });
  }, 5000);
  return () => window.clearInterval(timer);
}
