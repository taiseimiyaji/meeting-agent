#!/usr/bin/env node
import { readFile } from "node:fs/promises";

function usage() {
  console.error("Usage: node evaluate.mjs expected.json actual.json");
  process.exitCode = 2;
}

function intervals(items) {
  return items.map((item) => [item.startedAtMs, item.endedAtMs ?? item.startedAtMs]);
}

function overlap(a, b) {
  return Math.max(0, Math.min(a[1], b[1]) - Math.max(a[0], b[0]));
}

function intervalIoU(a, b) {
  const intersection = overlap(a, b);
  const union = Math.max(a[1], b[1]) - Math.min(a[0], b[0]);
  return union === 0 ? Number(a[0] === b[0]) : intersection / union;
}

function bestMatches(expected, actual, threshold = 0.5) {
  const used = new Set();
  let matched = 0;
  for (const target of expected) {
    let best = -1;
    let bestScore = 0;
    for (let index = 0; index < actual.length; index += 1) {
      if (used.has(index)) continue;
      const score = intervalIoU(target, actual[index]);
      if (score > bestScore) {
        best = index;
        bestScore = score;
      }
    }
    if (best >= 0 && bestScore >= threshold) {
      used.add(best);
      matched += 1;
    }
  }
  return { matched, expected: expected.length, actual: actual.length };
}

function normalizeText(value) {
  return value.normalize("NFKC").toLowerCase().replace(/[\s。、,.!?！？]/gu, "");
}

function characterErrorRate(reference, hypothesis) {
  const a = [...normalizeText(reference)];
  const b = [...normalizeText(hypothesis)];
  const row = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i += 1) {
    let previous = row[0];
    row[0] = i;
    for (let j = 1; j <= b.length; j += 1) {
      const old = row[j];
      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, previous + Number(a[i - 1] !== b[j - 1]));
      previous = old;
    }
  }
  return a.length === 0 ? Number(b.length > 0) : row[b.length] / a.length;
}

function setMetrics(expected, actual) {
  const target = new Set(expected.map(normalizeText));
  const observed = new Set(actual.map(normalizeText));
  const truePositive = [...observed].filter((value) => target.has(value)).length;
  const precision = observed.size === 0 ? Number(target.size === 0) : truePositive / observed.size;
  const recall = target.size === 0 ? 1 : truePositive / target.size;
  return { precision, recall, f1: precision + recall === 0 ? 0 : (2 * precision * recall) / (precision + recall) };
}

function timestampOffsets(expectedEvents, actualEvents) {
  const actualById = new Map(actualEvents.map((item) => [item.id, item]));
  const offsets = expectedEvents.flatMap((item) => {
    const observed = actualById.get(item.id);
    return observed ? [Math.abs(item.startedAtMs - observed.startedAtMs)] : [];
  });
  offsets.sort((a, b) => a - b);
  return {
    samples: offsets.length,
    meanMs: offsets.length ? offsets.reduce((sum, value) => sum + value, 0) / offsets.length : null,
    p95Ms: offsets.length ? offsets[Math.min(offsets.length - 1, Math.floor(offsets.length * 0.95))] : null,
  };
}

export function evaluate(expected, actual) {
  const screenMatch = bestMatches(intervals(expected.screens ?? []), intervals(actual.screens ?? []));
  const expectedTranscript = (expected.transcript ?? []).map((item) => item.text).join("\n");
  const actualTranscript = (actual.transcript ?? []).map((item) => item.text).join("\n");
  const decisionMetrics = setMetrics(expected.summary?.decisions ?? [], actual.summary?.decisions ?? []);
  const actionMetrics = setMetrics(expected.summary?.actionItems ?? [], actual.summary?.actionItems ?? []);
  return {
    schemaVersion: 1,
    timestampOffset: timestampOffsets(expected.transcript ?? [], actual.transcript ?? []),
    transcript: { characterErrorRate: characterErrorRate(expectedTranscript, actualTranscript) },
    keyFrames: {
      recall: screenMatch.expected ? screenMatch.matched / screenMatch.expected : 1,
      precision: screenMatch.actual ? screenMatch.matched / screenMatch.actual : Number(screenMatch.expected === 0),
      expected: screenMatch.expected,
      actual: screenMatch.actual,
      matched: screenMatch.matched,
    },
    decisions: decisionMetrics,
    actionItems: actionMetrics,
    runtime: actual.runtime ?? null,
    recovery: actual.recovery ?? null,
  };
}

if (process.argv[1]?.endsWith("evaluate.mjs")) {
  if (process.argv.length !== 4) usage();
  else {
    const [expected, actual] = await Promise.all(process.argv.slice(2).map(async (path) => JSON.parse(await readFile(path, "utf8"))));
    console.log(JSON.stringify(evaluate(expected, actual), null, 2));
  }
}
