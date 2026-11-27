import { expect, it } from "vitest";
import { meetingName } from "./meetingName";
import type { Meeting } from "./types";

it("names an untitled meeting using its local recording start time", () => {
  const meeting: Meeting = { id: "fixture", title: null, status: "completed", startedAt: new Date(2026, 0, 2, 3, 4).toISOString() };
  expect(meetingName(meeting)).toBe("2026-01-02 03:04 ミーティング");
  expect(meetingName({ ...meeting, title: "定例" })).toBe("定例");
});
