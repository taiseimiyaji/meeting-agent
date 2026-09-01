import * as mock from "./mock";
import type { CaptureStatus, Meeting, MeetingDetail, MeetingPage, MeetingSummary, ScreenEvent, ServerEvent, Settings, Timeline, TranscriptEvent } from "./types";

const baseUrl = import.meta.env.VITE_API_BASE_URL ?? "";
const useMock = import.meta.env.VITE_USE_MOCK_API === "1";
const token = import.meta.env.VITE_SESSION_TOKEN;
const csrfToken = import.meta.env.VITE_CSRF_TOKEN;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: token } : {}), ...init?.headers },
  });
  if (!response.ok) throw new Error((await response.text()) || `Local API error (${response.status})`);
  if (response.status === 202 || response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}
async function requestBlob(path: string): Promise<Blob> {
  const response = await fetch(`${baseUrl}${path}`, {
    headers: token ? { Authorization: token } : {},
  });
  if (!response.ok) throw new Error((await response.text()) || `Local API error (${response.status})`);
  return response.blob();
}
const pause = () => new Promise((resolve) => setTimeout(resolve, 160));

export const api = {
  async captureStatus(): Promise<CaptureStatus> { if (!useMock) return request("/api/capture"); await pause(); return mock.capture; },
  async meetings(): Promise<Meeting[]> { if (!useMock) return (await request<MeetingPage>("/api/meetings?limit=100")).items; await pause(); return [...mock.meetings]; },
  async meeting(id: string): Promise<MeetingDetail> { if (!useMock) return request(`/api/meetings/${id}`); await pause(); const value = mock.detail(id); if (!value) throw new Error("Meeting not found"); return value; },
  async timeline(id: string): Promise<Timeline> { if (!useMock) return request(`/api/meetings/${id}/timeline?limit=1000`); await pause(); return { transcript: mock.transcripts[id] ?? [], screens: mock.screens[id] ?? [] }; },
  async transcript(id: string): Promise<TranscriptEvent[]> { return (await this.timeline(id)).transcript; },
  async screens(id: string): Promise<ScreenEvent[]> { return (await this.timeline(id)).screens; },
  async screenImage(path: string): Promise<Blob> {
    if (!useMock) return requestBlob(path);
    return (await fetch(path)).blob();
  },
  async summary(id: string): Promise<MeetingSummary | null> { if (!useMock) return request(`/api/meetings/${id}/summary`); await pause(); return mock.summaries[id] ?? null; },
  async startCapture(targetId?: string): Promise<CaptureStatus> { if (!useMock) { await request<void>("/api/capture/start", { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {}, body: targetId ? JSON.stringify({ targetId }) : undefined }); return this.captureStatus(); } const value = { status: "capturing", meetingId: "mtg-live", videoFrames: 0, systemAudioRms: 0, microphoneRms: 0 } satisfies CaptureStatus; mock.updateCapture(value); return value; },
  async stopCapture(): Promise<CaptureStatus> { if (!useMock) { await request<void>("/api/capture/stop", { method: "POST", headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {} }); return this.captureStatus(); } const value = { status: "idle", videoFrames: 0, systemAudioRms: 0, microphoneRms: 0 } satisfies CaptureStatus; mock.updateCapture(value); return value; },
  async settings(): Promise<Settings> { const saved = localStorage.getItem("meeting-agent.settings"); return saved ? JSON.parse(saved) as Settings : mock.settings; },
  async saveSettings(value: Settings): Promise<Settings> { localStorage.setItem("meeting-agent.settings", JSON.stringify(value)); mock.updateSettings(value); return value; },
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
