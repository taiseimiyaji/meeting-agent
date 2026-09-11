import * as mock from "./mock";
import type { CaptureStatus, Meeting, MeetingDetail, MeetingPage, MeetingSummary, ScreenEvent, ServerEvent, Settings, SummaryProgress, Timeline, TranscriptEvent, TranscriptionProgress } from "./types";

const baseUrl = import.meta.env.VITE_API_BASE_URL ?? "";
const useMock = import.meta.env.VITE_USE_MOCK_API === "1";
const launchParameters = new URLSearchParams(window.location.hash.replace(/^#/, ""));
const launchedToken = launchParameters.get("sessionToken");
const launchedCSRFToken = launchParameters.get("csrfToken");
if (launchedToken) sessionStorage.setItem("meeting-agent.session-token", launchedToken);
if (launchedCSRFToken) sessionStorage.setItem("meeting-agent.csrf-token", launchedCSRFToken);
const token = import.meta.env.VITE_SESSION_TOKEN || launchedToken || sessionStorage.getItem("meeting-agent.session-token") || undefined;
const csrfToken = import.meta.env.VITE_CSRF_TOKEN || launchedCSRFToken || sessionStorage.getItem("meeting-agent.csrf-token") || undefined;
if (launchParameters.has("sessionToken") || launchParameters.has("csrfToken")) {
  history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: token } : {}), ...init?.headers },
  });
  if (!response.ok) throw new APIError(response.status, (await response.text()) || `Local API error (${response.status})`);
  if (response.status === 202 || response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}
class APIError extends Error {
  constructor(public readonly status: number, message: string) { super(message); }
}

export function isAuthenticationError(error: unknown): boolean {
  return error instanceof APIError && error.status === 401;
}
async function requestBlob(path: string, signal?: AbortSignal): Promise<Blob> {
  const response = await fetch(`${baseUrl}${path}`, {
    headers: token ? { Authorization: token } : {}, signal,
  });
  if (!response.ok) throw new Error((await response.text()) || `Local API error (${response.status})`);
  return response.blob();
}
const pause = () => new Promise((resolve) => setTimeout(resolve, 160));

export const api = {
  async stopTab(meetingId: string, error?: string): Promise<void> {
    await request<void>('/api/capture/tab/stop', { method: 'POST', body: JSON.stringify({ meetingId, error }), headers: csrfToken ? { 'X-CSRF-Token': csrfToken } : {} });
  },
  async tabPacket(meeting: string, kind: string, sequence: number, timestamp: number, body: Blob, rate: number, channels: number): Promise<void> {
    const query = new URLSearchParams({ meeting, kind, sequence: String(sequence), timestamp: String(timestamp), rate: String(rate), channels: String(channels) });
    await request<void>(`/api/capture/tab/packet?${query}`, { method: 'POST', body, signal: AbortSignal.timeout(10000), headers: { 'Content-Type': 'application/octet-stream', ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {}) } });
  },
  async captureStatus(): Promise<CaptureStatus> { if (!useMock) return request("/api/capture"); await pause(); return mock.capture; },
  async meetings(): Promise<Meeting[]> { if (!useMock) return (await request<MeetingPage>("/api/meetings?limit=100")).items; await pause(); return [...mock.meetings]; },
  async meeting(id: string): Promise<MeetingDetail> { if (!useMock) return request(`/api/meetings/${id}`); await pause(); const value = mock.detail(id); if (!value) throw new Error("Meeting not found"); return value; },
  async timeline(id: string): Promise<Timeline> {
    if (useMock) { await pause(); return { transcript: mock.transcripts[id] ?? [], screens: mock.screens[id] ?? [] }; }
    const result: Timeline = { transcript: [], screens: [] };
    let offset = 0;
    while (true) {
      const page = await request<Timeline & { nextOffset?: number | null }>(`/api/meetings/${id}/timeline?limit=1000${offset ? `&offset=${offset}` : ""}`);
      result.transcript.push(...page.transcript); result.screens.push(...page.screens);
      if (page.nextOffset == null || page.nextOffset <= offset) return result;
      offset = page.nextOffset;
    }
  },
  async transcript(id: string): Promise<TranscriptEvent[]> { return (await this.timeline(id)).transcript; },
  async screens(id: string): Promise<ScreenEvent[]> { return (await this.timeline(id)).screens; },
  async screenImage(path: string, signal?: AbortSignal): Promise<Blob> {
    if (!useMock) return requestBlob(path, signal);
    return (await fetch(path, { signal })).blob();
  },
  async summary(id: string): Promise<MeetingSummary | null> {
    if (!useMock) {
      try { return await request(`/api/meetings/${id}/summary`); }
      catch (error) { if (error instanceof APIError && error.status === 404) return null; throw error; }
    }
    await pause(); return mock.summaries[id] ?? null;
  },
  async summaryProgress(id: string): Promise<SummaryProgress> {
    if (!useMock) return request(`/api/meetings/${id}/summary/status`);
    return { state: mock.summaries[id] ? "completed" : "not_started", retryCount: 0 };
  },
  async summarize(id: string): Promise<void> {
    if (!useMock) await request<void>(`/api/meetings/${id}/summarize`, { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {} });
  },
  async transcriptionProgress(id: string): Promise<TranscriptionProgress> {
    if (!useMock) return request(`/api/meetings/${id}/transcription/status`);
    return { state: (mock.transcripts[id]?.length ?? 0) > 0 ? "completed" : "not_started", retryCount: 0,
      hasSystemAudio: false, hasMicrophoneAudio: false, archivedBytes: 0 };
  },
  async retryTranscription(id: string): Promise<void> {
    if (!useMock) await request<void>(`/api/meetings/${id}/transcribe`, { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {} });
  },
  async startCapture(targetId?: string): Promise<CaptureStatus> { if (!useMock) { await request<void>("/api/capture/start", { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {}, body: targetId ? JSON.stringify({ targetId }) : undefined }); return this.captureStatus(); } const value = { status: "capturing", meetingId: "mtg-live", videoFrames: 0, systemAudioRms: 0, microphoneRms: 0 } satisfies CaptureStatus; mock.updateCapture(value); return value; },
  async stopCapture(): Promise<CaptureStatus> { if (!useMock) { await request<void>("/api/capture/stop", { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {} }); return this.captureStatus(); } const value = { status: "idle", videoFrames: 0, systemAudioRms: 0, microphoneRms: 0 } satisfies CaptureStatus; mock.updateCapture(value); return value; },
  async settings(): Promise<Settings> { if (!useMock) return request("/api/settings"); return mock.settings; },
  async saveSettings(value: Settings): Promise<Settings> {
    if (!useMock) return request("/api/settings", { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {}, body: JSON.stringify(value) });
    mock.updateSettings(value); return value;
  },
  async codexStatus(): Promise<{ error: string }> {
    if (!useMock) return request("/api/settings/codex-status");
    return { error: "デモ表示です。実際のCodex認証は確認していません。" };
  },
  async prepareSpeechModel(): Promise<void> {
    if (!useMock) await request("/api/settings/prepare-speech-model", { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {} });
  },
};

export function websocketTokenProtocol(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return `token.${btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")}`;
}

export function subscribe(onEvent: (event: ServerEvent) => void, onState: (connected: boolean) => void) {
  if (useMock) { onState(true); const dispose = mock.subscribeMock(onEvent); return () => { dispose(); onState(false); }; }
  let ws: WebSocket | undefined;
  let timer: number | undefined;
  let closed = false;
  let attempt = 0;
  const connect = () => {
    const url = new URL(`${baseUrl || window.location.origin}/api/events`);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    const protocols = token ? ["meeting-agent", websocketTokenProtocol(token)] : ["meeting-agent"];
    ws = new WebSocket(url, protocols);
    ws.onopen = () => { attempt = 0; onState(true); };
    ws.onmessage = (message) => { try { onEvent(JSON.parse(message.data) as ServerEvent); } catch { /* ignore malformed server events */ } };
    ws.onclose = () => { onState(false); if (!closed) timer = window.setTimeout(connect, Math.min(1000 * 2 ** attempt++, 30_000)); };
    ws.onerror = () => ws?.close();
  };
  connect();
  return () => { closed = true; if (timer) clearTimeout(timer); ws?.close(); };
}
