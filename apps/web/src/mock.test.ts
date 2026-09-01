// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { detail, subscribeMock, updateCapture } from "./mock";

afterEach(() => vi.useRealTimers());

describe("development mock", () => {
  it("returns the OpenAPI meeting shape", () => {
    const meeting = detail("mtg-architecture");
    expect(meeting).toEqual(expect.objectContaining({ id: "mtg-architecture", status: "partially_completed" }));
    expect(detail("missing")).toBeUndefined();
  });

  it("publishes partial transcript revisions while capture is active", () => {
    vi.useFakeTimers();
    updateCapture({ status: "capturing", meetingId: "mtg-live", videoFrames: 0, systemAudioRms: 0, microphoneRms: 0 });
    const listener = vi.fn();
    const dispose = subscribeMock(listener);
    vi.advanceTimersByTime(5000);
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({ type: "transcript.partial", meetingId: "mtg-live" }));
    dispose();
  });
});
