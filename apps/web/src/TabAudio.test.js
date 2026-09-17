import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { expect, it } from 'vitest';
it('retains stereo samples, timestamps and the partial final block', () => {
  const packets = [];
  let Constructor;
  const environment = {
    AudioWorkletProcessor: class { port = { onmessage: (_ ) => {}, postMessage: (packet) => packets.push(packet) }; },
    registerProcessor: (_, value) => { Constructor = value; }, sampleRate: 8000, currentFrame: 800,
  };
  runInNewContext(readFileSync(new URL('../public/tab-audio-worklet.js', import.meta.url), 'utf8'), environment);
  const processor = new Constructor();
  processor.process([[new Float32Array([0.25, -0.5]), new Float32Array([0.75, -0])]]);
  expect(packets).toHaveLength(0);
  processor.port.onmessage({ data: 'flush' });
  expect(packets).toHaveLength(2);
  expect(packets[0].channels).toBe(2); expect(packets[0].timestamp).toBe(100);
  expect(Array.from(new Float32Array(packets[0].pcm))).toEqual([0.25, 0.75, -0.5, -0]);
  expect(packets[1].flushed).toBe(true);
  expect(processor.process([[new Float32Array([1])]])).toBe(false);
  expect(packets).toHaveLength(2);
});
