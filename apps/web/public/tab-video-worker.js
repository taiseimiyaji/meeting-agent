let stopped = false;
onmessage = async ({ data }) => {
  if (data.stop) { stopped = true; return; }
  const { readable, epoch } = data;
  let reader;
  try {
    reader = readable.getReader();
    let previous = -Infinity, canvas;
    while (!stopped) {
      const { value: frame, done } = await reader.read();
      if (done) { if (!stopped) postMessage({ error: 'タブ映像の入力が終了しました。' }); break; }
      try {
        const timestamp = Math.floor(performance.timeOrigin + performance.now() - epoch);
        if (timestamp - previous < 190) continue;
        previous = timestamp;
        const ratio = Math.min(1, 1920 / frame.displayWidth, 1080 / frame.displayHeight);
        const width = Math.max(1, Math.round(frame.displayWidth * ratio)), height = Math.max(1, Math.round(frame.displayHeight * ratio));
        if (!canvas || canvas.width !== width || canvas.height !== height) canvas = new OffscreenCanvas(width, height);
        canvas.getContext('2d').drawImage(frame, 0, 0, canvas.width, canvas.height);
        const blob = await canvas.convertToBlob({ type: 'image/png' });
        postMessage({ blob, timestamp });
      } finally { frame.close(); }
    }
  } catch (error) { postMessage({ error: String(error) }); }
  finally { await reader?.cancel(); }
};
