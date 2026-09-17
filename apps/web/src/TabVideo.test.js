import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { expect, it, vi } from 'vitest';
it('confirms a static frame without requiring another source frame', async () => {
  const packets = [], callbacks = [];
  const frame = { displayWidth: 1280, displayHeight: 720, close: vi.fn() };
  let reads = 0;
  const context = {
    onmessage: undefined, postMessage: packet => packets.push(packet), performance: { timeOrigin: 10000, now: () => 800 },
    setTimeout: callback => { callbacks.push(callback); return 1; }, clearTimeout: vi.fn(),
    OffscreenCanvas: class { constructor(w,h) { this.width=w;this.height=h; } getContext() { return { drawImage() {} }; } async convertToBlob() { return 'original-pixels'; } },
  };
  runInNewContext(readFileSync(new URL('../public/tab-video-worker.js', import.meta.url), 'utf8'), context);
  void context.onmessage({ data: { epoch: 10000, readable: { getReader: () => ({ read: () => reads++ ? new Promise(() => {}) : Promise.resolve({value: frame, done:false}), cancel: async () => {} }) } } });
  await vi.waitFor(() => expect(packets).toHaveLength(1)); expect(frame.close).toHaveBeenCalledOnce();
  callbacks[0]();
  expect(packets).toHaveLength(2); expect(packets[1].blob).toBe(packets[0].blob);
});
