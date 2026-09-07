// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { App } from "./App";
const state = vi.hoisted(() => ({ transcript: [] as unknown[], callback: undefined as ((event: unknown) => void) | undefined, onConnect: undefined as ((connected: boolean) => void) | undefined }));
vi.mock("./api", () => ({
  isAuthenticationError: () => false,
  subscribe: (callback: (event: unknown) => void, connected: (value: boolean) => void) => { state.callback = callback; state.onConnect = connected; connected(true); return () => {}; },
  api: {
    captureStatus: async () => ({ status: "capturing", meetingId: "m1", videoFrames: 1 }),
    meetings: async () => [{ id: "m1", title: "検証会議", status: "capturing", startedAt: "2026-09-07T00:00:00Z" }],
    meeting: async () => ({ id: "m1", title: "検証会議", status: "capturing", startedAt: "2026-09-07T00:00:00Z" }),
    transcript: async () => state.transcript,
    screens: async () => [],
    transcriptionProgress: async () => ({ state: "queued", hasSystemAudio: true, hasMicrophoneAudio: true, archivedBytes: 42, totalChunks: 1, completedChunks: 0, isCapturing: true }),
    startCapture: async () => { throw new Error("マイク権限がありません"); },
    stopCapture: async () => { throw new Error("停止処理に失敗しました"); },
  },
}));
beforeEach(() => { state.transcript = []; });
afterEach(() => cleanup());
function mount() { render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><App/></QueryClientProvider>); }
function addTranscript() { state.transcript = [{ id: "t1", revision: 1, startedAtMs: 0, endedAtMs: 1000, speaker: "self", text: "後から届いた文字起こし", isFinal: true, source: "microphone", screenRefs: [] }]; }
it("refreshes transcript in an open detail view after a persisted-data notification", async () => {
  mount(); fireEvent.click(await screen.findByText("ライブ表示")); await screen.findByText("Transcriptはまだありません。");
  addTranscript(); act(() => state.callback?.({ type: "data_changed" })); expect(await screen.findByText("後から届いた文字起こし")).toBeTruthy();
});
it("refetches the open meeting after reconnect", async () => {
  mount(); fireEvent.click(await screen.findByText("ライブ表示")); await screen.findByText("Transcriptはまだありません。");
  addTranscript(); act(() => state.onConnect?.(true)); expect(await screen.findByText("後から届いた文字起こし")).toBeTruthy();
});
it("displays capture mutation errors", async () => {
  mount(); fireEvent.click(await screen.findByText(/停止$/)); expect(await screen.findByText("停止処理に失敗しました")).toBeTruthy();
});
it("does not offer manual recovery while recording", async () => {
  mount(); fireEvent.click(await screen.findByText("ライブ表示")); await screen.findByText(/録音継続中/); expect(screen.queryByText("文字起こしを復旧")).toBeNull();
});
