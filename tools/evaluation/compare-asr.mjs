#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { evaluate } from './evaluate.mjs';
const [referencePath, ...paths] = process.argv.slice(2);
if (!referencePath || !paths.length) throw new Error('Usage: node compare-asr.mjs reference.txt provider-results.jsonl ...');
const reference = (await readFile(referencePath, 'utf8')).trim();
const results = [];
for (const path of paths) {
  const rows = (await readFile(path, 'utf8')).trim().split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
  const durations = rows.map(row => row.elapsedSeconds).sort((a, b) => a - b);
  results.push({
    provider: rows[0]?.provider, samples: rows.length,
    elapsedP95Seconds: durations[Math.max(0, Math.ceil(durations.length * .95) - 1)],
    observations: rows.map(row => ({ ...row, characterErrorRate: evaluate({ transcript: [{ text: reference }] }, { transcript: [{ text: row.text }] }).transcript.characterErrorRate })),
  });
}
console.log(JSON.stringify({ reference, note: 'Synthetic TTS fixture; file processing time includes model loading on the first call. Not live meeting latency or a Japanese accuracy benchmark.', results }, null, 2));
