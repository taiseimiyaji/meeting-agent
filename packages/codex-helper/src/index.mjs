import { mkdtemp, cp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve, sep } from "node:path";

function assertInside(parent, child) {
  const root = resolve(parent) + sep;
  if (!resolve(child).startsWith(root)) throw new Error("Path escapes the isolated meeting directory");
}

export async function prepareIsolatedInput({ timelinePath, transcriptPath, screenPaths = [] }) {
  const directory = await mkdtemp(join(tmpdir(), "meeting-agent-codex-"));
  await writeFile(join(directory, ".scope"), "This directory contains one explicitly approved meeting.\n", { mode: 0o600 });
  await cp(timelinePath, join(directory, "timeline.json"));
  await cp(transcriptPath, join(directory, "transcript.md"));
  const copiedScreens = [];
  for (const [index, source] of screenPaths.entries()) {
    const target = join(directory, `screen-${String(index + 1).padStart(4, "0")}-${basename(source)}`);
    assertInside(directory, target);
    await cp(source, target);
    copiedScreens.push(target);
  }
  return { directory, copiedScreens };
}

// Retired spike: production calls the signed native companion, which enforces
// ChatGPT-only authentication and validates references before saving a result.
export function runCodex() {
  throw new Error("Use the bundled MeetingCodexHelper through the desktop app. The prototype runner is disabled.");
}

export async function cleanupIsolatedInput(directory) {
  const expectedPrefix = resolve(tmpdir()) + sep + "meeting-agent-codex-";
  if (!resolve(directory).startsWith(expectedPrefix)) throw new Error("Refusing to remove a non-helper directory");
  await rm(directory, { recursive: true, force: true });
}
