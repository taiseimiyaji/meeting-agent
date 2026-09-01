import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedInput, prepareIsolatedInput } from "../src/index.mjs";

test("copies only explicitly selected meeting inputs and cleans them", async () => {
  const fixture = await mkdtemp(join(tmpdir(), "meeting-helper-test-"));
  const timeline = join(fixture, "timeline.json");
  const transcript = join(fixture, "transcript.md");
  const screen = join(fixture, "screen.webp");
  await writeFile(timeline, "{}");
  await writeFile(transcript, "hello");
  await writeFile(screen, "fake-image");
  const isolated = await prepareIsolatedInput({ timelinePath: timeline, transcriptPath: transcript, screenPaths: [screen] });
  await access(join(isolated.directory, "timeline.json"));
  await access(join(isolated.directory, "transcript.md"));
  assert.equal(isolated.copiedScreens.length, 1);
  await cleanupIsolatedInput(isolated.directory);
  await assert.rejects(access(isolated.directory));
});
