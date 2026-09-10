// @vitest-environment jsdom
import { StrictMode } from "react";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { SummaryEvidence } from "./SummaryEvidence";
import { resolveSummaryEvidence } from "./evidenceResolution";
import type { ScreenEvent, TranscriptEvent } from "./types";

const fetchImage = vi.hoisted(() => vi.fn());
vi.mock("./api", () => ({ api: { screenImage: fetchImage } }));
const images: ScreenEvent[] = [
  { id: "s1", startedAtMs: 1000, imageUrl: "/api/meetings/m1/screens/s1/image", description: "設計図", analysisStatus: "completed" },
  { id: "s2", startedAtMs: 9000, imageUrl: "/api/meetings/m1/screens/s2/image", description: "別の話題", analysisStatus: "completed" },
];
const speech: TranscriptEvent[] = [{ id: "t1", revision: 1, startedAtMs: 2000, speaker: "remote", text: "この設計で進めると合意しました", source: "system_audio", isFinal: true, screenRefs: [{ screenId: "s1", relation: "visible_during_speech" }] }];
const item = { text: "設計案を採用", evidenceIds: ["t1"] };
beforeEach(() => {
  fetchImage.mockReset().mockResolvedValue(new Blob(["image"], { type: "image/png" }));
  vi.stubGlobal("URL", Object.assign(URL, { createObjectURL: vi.fn(() => `blob:test-image-${Math.random()}`), revokeObjectURL: vi.fn() }));
  HTMLDialogElement.prototype.showModal = function () { this.setAttribute("open", ""); };
  HTMLDialogElement.prototype.close = function () { this.removeAttribute("open"); };
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
function mount(cached = false) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  if (cached) client.setQueryData(["screen-image", images[0].imageUrl + "?thumbnail=1"], new Blob(["image"]));
  render(<StrictMode><QueryClientProvider client={client}><SummaryEvidence item={item} transcripts={speech} screens={images}/></QueryClientProvider></StrictMode>);
}
it("resolves screenshots through cited speech and excludes unrelated screens", () => {
  const result = resolveSummaryEvidence(item, speech, images);
  expect(result.screens.map((value) => value.screen.id)).toEqual(["s1"]);
  expect(result.transcripts).toEqual(speech);
});
it("deduplicates direct and speech references while preserving relationship labels", () => {
  const result = resolveSummaryEvidence({ text: "採用", evidenceIds: ["t1", "s1", "t1"] }, speech, images);
  expect(result.screens).toHaveLength(1);
  expect([...result.screens[0].relations]).toEqual(["visible_during_speech", "summary_evidence"]);
  expect(result.transcripts).toHaveLength(1);
});
it("preserves previously visible relationships and reports missing evidence without guessing", () => {
  const result = resolveSummaryEvidence({ text: "要確認", evidenceIds: ["missing", "t1"] }, [{ ...speech[0], screenRefs: [{ screenId: "s1", relation: "previously_visible" }, { screenId: "lost", relation: "visible_during_speech" }] }], images);
  expect([...result.screens[0].relations]).toEqual(["previously_visible"]);
  expect(result.missingCount).toBe(2);
  expect(resolveSummaryEvidence({ text: "参照なし", evidenceIds: [] }, speech, images).screens).toEqual([]);
});
it("renders authenticated screenshots, the cited speech, and an accessible enlarged view", async () => {
  mount();
  const image = await screen.findByRole("img", { name: "設計図" });
  expect(image.getAttribute("src")).toMatch(/^blob:test-image-/);
  expect(URL.revokeObjectURL).not.toHaveBeenCalledWith(image.getAttribute("src"));
  expect(fetchImage).toHaveBeenCalledWith(images[0].imageUrl + "?thumbnail=1", expect.any(AbortSignal));
  // StrictMode cancels the first mount; only the remounted request stays active.
  expect(fetchImage.mock.calls.filter((call) => !(call[1] as AbortSignal).aborted)).toHaveLength(1);
  expect(screen.getByText(/発話中に表示/)).toBeTruthy();
  expect(screen.getByText(speech[0].text)).toBeTruthy();
  expect(screen.queryByText("別の話題")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "00:01の画面を拡大" }));
  expect(screen.getByRole("dialog", { name: "スクリーンショットの拡大" })).toBeTruthy();
  expect(fetchImage).toHaveBeenCalledWith(images[0].imageUrl, expect.any(AbortSignal));
  fireEvent.click(screen.getByRole("button", { name: "閉じる" }));
  expect(screen.queryByRole("dialog")).toBeNull();
});
it("shows image download failures without hiding the cited speech", async () => {
  fetchImage.mockRejectedValue(new Error("unavailable"));
  mount();
  expect(await screen.findByText("画像を表示できません")).toBeTruthy();
  expect(screen.getByText(speech[0].text)).toBeTruthy();
});

it("reports undecodable images and keeps the supporting speech available", async () => {
  mount();
  fireEvent.error(await screen.findByRole("img", { name: "設計図" }));
  expect(screen.getByText("画像を表示できません")).toBeTruthy();
  expect(screen.getByText(speech[0].text)).toBeTruthy();
});

it("keeps cached image URLs valid through StrictMode effect cleanup and setup", async () => {
  mount(true);
  const image = await screen.findByRole("img", { name: "設計図" });
  expect(URL.revokeObjectURL).toHaveBeenCalled();
  expect(URL.revokeObjectURL).not.toHaveBeenCalledWith(image.getAttribute("src"));
});
