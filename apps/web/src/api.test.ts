// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const response = (body: unknown, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: vi.fn().mockResolvedValue(body),
  text: vi.fn().mockResolvedValue(typeof body === "string" ? body : JSON.stringify(body)),
}) as unknown as Response;

describe("OpenAPI client contract", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.stubEnv("VITE_USE_MOCK_API", "0");
    vi.stubEnv("VITE_SESSION_TOKEN", "session-secret");
    vi.stubEnv("VITE_CSRF_TOKEN", "csrf-secret");
    vi.stubEnv("VITE_API_BASE_URL", "");
  });
  afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); history.replaceState(null, "", "/"); });

  it("accepts app launch credentials from a fragment and removes them immediately", async () => {
    vi.stubEnv("VITE_SESSION_TOKEN", "");
    vi.stubEnv("VITE_CSRF_TOKEN", "");
    history.replaceState(null, "", "/#sessionToken=launch-session&csrfToken=launch-csrf");
    const fetch = vi.fn().mockResolvedValue(response({ status: "idle" }));
    vi.stubGlobal("fetch", fetch);
    const { api } = await import("./api");
    await api.captureStatus();
    expect(fetch).toHaveBeenCalledWith("/api/capture", expect.objectContaining({ headers: expect.objectContaining({ Authorization: "launch-session" }) }));
    expect(window.location.hash).toBe("");
  });

  it("unwraps the paginated meeting response and sends apiKey auth", async () => {
    const fetch = vi.fn().mockResolvedValue(response({ items: [{ id: "m1", title: null, startedAt: "2026-09-01T00:00:00Z", status: "completed" }], nextCursor: null }));
    vi.stubGlobal("fetch", fetch);
    const { api } = await import("./api");
    await expect(api.meetings()).resolves.toHaveLength(1);
    expect(fetch).toHaveBeenCalledWith("/api/meetings?limit=100", expect.objectContaining({ headers: expect.objectContaining({ Authorization: "session-secret" }) }));
  });

  it("uses the combined timeline endpoint", async () => {
    const timeline = { transcript: [], screens: [{ id: "screen-1", startedAtMs: 0, imageUrl: "/image", analysisStatus: "pending" }] };
    const fetch = vi.fn().mockResolvedValue(response(timeline));
    vi.stubGlobal("fetch", fetch);
    const { api } = await import("./api");
    await expect(api.timeline("m1")).resolves.toEqual(timeline);
    expect(fetch).toHaveBeenCalledWith("/api/meetings/m1/timeline?limit=1000", expect.anything());
  });

  it("fetches protected screen images with the session token", async () => {
    const blob = new Blob(["image"], { type: "image/jpeg" });
    const fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      blob: vi.fn().mockResolvedValue(blob),
      text: vi.fn(),
    } as unknown as Response);
    vi.stubGlobal("fetch", fetch);
    const { api } = await import("./api");
    await expect(api.screenImage("/api/screens/s1/image")).resolves.toBe(blob);
    expect(fetch).toHaveBeenCalledWith("/api/screens/s1/image", { headers: { Authorization: "session-secret" } });
  });

  it("sends CSRF on capture mutation and refreshes state after 202", async () => {
    const capture = { status: "starting", meetingId: "m1", videoFrames: 0, systemAudioRms: 0, microphoneRms: 0 };
    const fetch = vi.fn().mockResolvedValueOnce(response(undefined, 202)).mockResolvedValueOnce(response(capture));
    vi.stubGlobal("fetch", fetch);
    const { api } = await import("./api");
    await expect(api.startCapture("window-42")).resolves.toEqual(capture);
    expect(fetch).toHaveBeenNthCalledWith(1, "/api/capture/start", expect.objectContaining({ method: "POST", body: JSON.stringify({ targetId: "window-42" }), headers: expect.objectContaining({ Authorization: "session-secret", "X-CSRF-Token": "csrf-secret" }) }));
    expect(fetch).toHaveBeenNthCalledWith(2, "/api/capture", expect.anything());
  });

  it("treats a missing summary as pending and can request generation", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(response({ error: "Summary not found" }, 404)).mockResolvedValueOnce(response(undefined, 202));
    vi.stubGlobal("fetch", fetch);
    const { api } = await import("./api");
    await expect(api.summary("m1")).resolves.toBeNull();
    await expect(api.summarize("m1")).resolves.toBeUndefined();
    expect(fetch).toHaveBeenNthCalledWith(2, "/api/meetings/m1/summarize", expect.objectContaining({ method: "POST", headers: expect.objectContaining({ Authorization: "session-secret", "X-CSRF-Token": "csrf-secret" }) }));
  });

  it("authenticates WebSocket with subprotocols without leaking token in the URL", async () => {
    const sockets: MockSocket[] = [];
    class MockSocket {
      static readonly OPEN = 1;
      onopen: (() => void) | null = null;
      onmessage: ((event: MessageEvent) => void) | null = null;
      onclose: (() => void) | null = null;
      onerror: (() => void) | null = null;
      constructor(public url: string, public protocols?: string | string[]) { sockets.push(this); }
      close() {}
    }
    vi.stubGlobal("WebSocket", MockSocket);
    const { subscribe, websocketTokenProtocol } = await import("./api");
    const dispose = subscribe(vi.fn(), vi.fn());
    expect(String(sockets[0].url)).toBe("ws://localhost:3000/api/events");
    expect(String(sockets[0].url)).not.toContain("session-secret");
    expect(sockets[0].protocols).toEqual(["meeting-agent", websocketTokenProtocol("session-secret")]);
    expect(websocketTokenProtocol("session-secret")).toBe("token.c2Vzc2lvbi1zZWNyZXQ");
    dispose();
  });
});
