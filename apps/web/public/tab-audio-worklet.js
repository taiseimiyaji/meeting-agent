class TabPCM extends AudioWorkletProcessor {
  constructor() {
    super(); this.parts = []; this.frames = 0; this.channels = 0; this.start = 0;
    this.port.onmessage = ({ data }) => { if (data === 'flush') { this.closed = true; this.flush(); this.port.postMessage({ flushed: true }); } };
  }
  flush() {
    if (!this.frames) return;
    const pcm = new Float32Array(this.frames * this.channels);
    let offset = 0;
    for (const part of this.parts) { pcm.set(part, offset); offset += part.length; }
    this.port.postMessage({ pcm: pcm.buffer, channels: this.channels, rate: sampleRate, timestamp: Math.floor(this.start / sampleRate * 1000) }, [pcm.buffer]);
    this.parts = []; this.frames = 0;
  }
  process(inputs) {
    if (this.closed) return false;
    const input = inputs[0];
    if (!input?.length || !input[0].length) return true;
    if (this.channels !== input.length) { this.flush(); this.channels = input.length; }
    if (!this.frames) this.start = currentFrame;
    const frames = input[0].length, part = new Float32Array(frames * input.length);
    for (let f = 0; f < frames; f++) for (let c = 0; c < input.length; c++) part[f * input.length + c] = input[c][f];
    this.parts.push(part); this.frames += frames;
    if (this.frames >= sampleRate / 2) this.flush();
    return true;
  }
}
registerProcessor('tab-pcm', TabPCM);
