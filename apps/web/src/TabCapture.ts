import { api } from './api';

export function validateTab(stream: MediaStream) {
  if (stream.getVideoTracks()[0]?.getSettings().displaySurface !== 'browser') throw new Error('「Chrome タブ」から会議タブを選んでください。ウインドウ・画面全体は使用しません。');
  if (!stream.getAudioTracks().length) throw new Error('「タブの音声も共有する」を有効にして、もう一度選んでください。');
}

// Singleton keeps recording alive when navigating between Meeting Agent pages.
class TabCapture {
  private context?: AudioContext;
  private streams: MediaStream[] = [];
  private nodes: AudioWorkletNode[] = [];
  private worker?: Worker;
  private meeting?: string;
  private queue = Promise.resolve();
  private queuedBytes = 0;
  private sequence: Record<string, number> = {};
  private stopping?: Promise<void>;
  private accepting = false;
  private failure?: string;
  private onError?: (error: Error) => void;
  get active() { return !!this.meeting; }
  async start(onError: (error: Error) => void) {
    if (this.active) throw new Error('タブを収録中です。');
    if (!navigator.mediaDevices?.getDisplayMedia) throw new Error('デスクトップアプリの「Chromeでタブ収録を開く」から開いてください。');
    this.onError = onError; this.stopping = undefined; this.sequence = {}; this.failure = undefined; this.queue = Promise.resolve(); this.queuedBytes = 0;
    try {
      // This must be called directly from the user's click, before other awaits.
      const display = await navigator.mediaDevices.getDisplayMedia({
        video: { displaySurface: 'browser', width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 5, max: 5 } },
        audio: { suppressLocalAudioPlayback: false }, selfBrowserSurface: 'exclude', surfaceSwitching: 'exclude', systemAudio: 'exclude', monitorTypeSurfaces: 'exclude',
      } as DisplayMediaStreamOptions);
      this.streams.push(display); validateTab(display);
      const mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: false }, video: false });
      this.streams.push(mic);
      const context = new AudioContext({ sampleRate: display.getAudioTracks()[0].getSettings().sampleRate ?? 48000 });
      this.context = context; await context.suspend();
      await context.audioWorklet.addModule('/tab-audio-worklet.js');
      for (const [kind, stream] of [['systemAudio', display], ['microphone', mic]] as const) {
        const node = new AudioWorkletNode(context, 'tab-pcm');
        context.createMediaStreamSource(new MediaStream(stream.getAudioTracks())).connect(node);
        node.onprocessorerror = () => this.fail(new Error("音声の取得処理が停止しました。保存済みの記録を確定します。"));
        node.connect(context.destination); // Worklet emits silence; never replay the microphone.
        node.port.onmessage = ({ data }) => {
          if (data.pcm) this.enqueue(kind, data.timestamp, new Blob([data.pcm]), data.rate, data.channels);
        };
        this.nodes.push(node);
      }
      if (this.streams.some(stream => stream.getTracks().some(track => track.readyState !== "live"))) throw new Error("共有が停止されました。会議タブを選び直してください。");
      const status = await api.startCapture('browser-tab');
      if (!status.meetingId) throw new Error('収録を開始できませんでした。');
      this.meeting = status.meetingId; this.accepting = true;
      await context.resume();
      context.onstatechange = () => { if (this.accepting && context.state !== "running") this.fail(new Error("Chromeの音声取得が中断されました。")); };
      const epoch = performance.timeOrigin + performance.now() - context.currentTime * 1000;
      this.worker = new Worker('/tab-video-worker.js');
      this.worker.onmessage = ({ data }) => {
        if (data.error) this.fail(new Error(`タブ映像の取得に失敗しました: ${data.error}`));
        else this.enqueue('screen', data.timestamp, data.blob);
      };
      this.worker.onerror = () => this.fail(new Error('タブ映像の取得に失敗しました。Chromeを更新して再試行してください。'));
      const track = display.getVideoTracks()[0].clone();
      this.streams.push(new MediaStream([track]));
      const Processor = (globalThis as unknown as { MediaStreamTrackProcessor?: new (options: { track: MediaStreamTrack }) => { readable: ReadableStream } }).MediaStreamTrackProcessor;
      if (!Processor) throw new Error('このChromeはタブ映像の連続取得に対応していません。Chromeを更新してください。');
      const readable = new Processor({ track }).readable;
      this.worker.postMessage({ readable, epoch }, [readable]);
      for (const stream of this.streams) for (const track of stream.getTracks()) track.onended = () => { void this.stop().catch(onError); };
      window.addEventListener('beforeunload', this.beforeUnload);
    } catch (error) {
      this.failure = error instanceof Error ? error.message : String(error);
      if (this.meeting) await this.stop().catch(() => {}); else await this.release();
      throw error;
    }
  }
  private beforeUnload = (event: BeforeUnloadEvent) => { if (this.active) { event.preventDefault(); event.returnValue = ''; } };
  private enqueue(kind: string, timestamp: number, blob: Blob, rate = 48000, channels = 1) {
    if (!this.accepting) return;
    if (this.queuedBytes + blob.size > 16 * 1024 * 1024) { this.fail(new Error('音声・画面の保存が追いつきません。保存済みの記録を確定して停止します。')); return; }
    this.queuedBytes += blob.size;
    const meeting = this.meeting!, sequence = this.sequence[kind] ?? 0;
    this.sequence[kind] = sequence + 1;
    this.queue = this.queue.then(() => api.tabPacket(meeting, kind, sequence, timestamp, blob, rate, channels))
      .catch((error) => this.fail(error instanceof Error ? error : new Error(String(error))))
      .finally(() => { this.queuedBytes -= blob.size; });
  }
  private fail(error: Error) { if (!this.accepting) return; this.accepting = false; this.failure = error.message; this.onError?.(error); void this.stop().catch(() => {}); }
  stop(): Promise<void> {
    if (this.stopping) return this.stopping;
    this.stopping = this.finish(); return this.stopping;
  }
  private async finish() {
    this.worker?.terminate(); this.worker = undefined;
    // Flush the partial final PCM block before stopping native capture.
    for (const node of this.nodes) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 1000);
        const listener = (event: MessageEvent) => { if (event.data.flushed) { clearTimeout(timer); node.port.removeEventListener('message', listener); resolve(); } };
        node.port.addEventListener('message', listener); node.port.postMessage('flush');
      });
      node.disconnect();
    }
    this.accepting = false;
    await this.context?.suspend();
    await this.queue;
    try { if (this.meeting) await api.stopTab(this.meeting, this.failure); }
    finally { this.meeting = undefined; await this.release(); }
  }
  private async release() {
    this.accepting = false;
    this.worker?.terminate(); this.worker = undefined;
    for (const stream of this.streams) for (const track of stream.getTracks()) { track.onended = null; track.stop(); }
    this.streams = []; this.nodes = [];
    if (this.context && this.context.state !== 'closed') await this.context.close();
    this.context = undefined;
    window.removeEventListener('beforeunload', this.beforeUnload);
  }
}
export const tabCapture = new TabCapture();
