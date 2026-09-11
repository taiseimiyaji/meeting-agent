// @vitest-environment jsdom
import { expect, it } from 'vitest';
import { validateTab } from './TabCapture';
function stream(surface: string, audio: boolean) {
  return { getVideoTracks: () => [{ getSettings: () => ({ displaySurface: surface }) }], getAudioTracks: () => audio ? [{}] : [] } as unknown as MediaStream;
}
it('accepts an explicitly chosen browser tab with audio', () => { expect(() => validateTab(stream('browser', true))).not.toThrow(); });
it('rejects window and monitor capture before starting a meeting', () => {
  for (const surface of ['window', 'monitor', '']) expect(() => validateTab(stream(surface, true))).toThrow('Chrome タブ');
});
it('explains missing tab audio rather than creating an empty transcription', () => { expect(() => validateTab(stream('browser', false))).toThrow('タブの音声'); });
