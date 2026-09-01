import assert from "node:assert/strict";
import test from "node:test";
import { evaluate } from "./evaluate.mjs";

test("reports perfect evidence and summary metrics", () => {
  const sample = {
    transcript: [{ id: "t1", startedAtMs: 100, endedAtMs: 200, text: "実装します" }],
    screens: [{ id: "s1", startedAtMs: 50, endedAtMs: 250 }],
    summary: { decisions: ["Swiftを採用"], actionItems: ["試作する"] },
  };
  const result = evaluate(sample, structuredClone(sample));
  assert.equal(result.transcript.characterErrorRate, 0);
  assert.equal(result.keyFrames.precision, 1);
  assert.equal(result.keyFrames.recall, 1);
  assert.equal(result.decisions.f1, 1);
  assert.equal(result.actionItems.f1, 1);
});

test("counts missing keyframes and transcription edits", () => {
  const expected = {
    transcript: [{ id: "t1", startedAtMs: 100, text: "予約を実装する" }],
    screens: [{ startedAtMs: 0, endedAtMs: 100 }, { startedAtMs: 200, endedAtMs: 300 }],
  };
  const actual = {
    transcript: [{ id: "t1", startedAtMs: 120, text: "予約を実装" }],
    screens: [{ startedAtMs: 0, endedAtMs: 100 }],
  };
  const result = evaluate(expected, actual);
  assert.equal(result.timestampOffset.meanMs, 20);
  assert.equal(result.keyFrames.recall, 0.5);
  assert.ok(result.transcript.characterErrorRate > 0);
});
