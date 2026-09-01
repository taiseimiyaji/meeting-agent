import { mkdtemp, cp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve, sep } from "node:path";
import { spawn } from "node:child_process";

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

export function runCodex({ directory, schemaPath, prompt, screenPaths = [], command = "codex" }) {
  const outputPath = join(directory, "summary.json");
  assertInside(directory, outputPath);
  const args = [
    "exec",
    "--sandbox", "read-only",
    "--config", "approval_policy=\"never\"",
    "--ephemeral",
    "--skip-git-repo-check",
    "--cd", directory,
    "--output-schema", resolve(schemaPath),
    "--output-last-message", outputPath,
  ];
  for (const screenPath of screenPaths) {
    assertInside(directory, screenPath);
    args.push("--image", screenPath);
  }
  args.push(prompt);
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { cwd: directory, stdio: ["ignore", "pipe", "pipe"], env: { PATH: process.env.PATH } });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", async (code) => {
      if (code !== 0) {
        reject(new Error(`Codex exited with ${code}: ${stderr.slice(-2000)}`));
        return;
      }
      try { resolvePromise(JSON.parse(await readFile(outputPath, "utf8"))); }
      catch (error) { reject(error); }
    });
  });
}

export async function cleanupIsolatedInput(directory) {
  const expectedPrefix = resolve(tmpdir()) + sep + "meeting-agent-codex-";
  if (!resolve(directory).startsWith(expectedPrefix)) throw new Error("Refusing to remove a non-helper directory");
  await rm(directory, { recursive: true, force: true });
}
