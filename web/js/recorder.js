// canvas（加工済み映像）＋マイク音声を MediaRecorder で動画にする

// iPhone の写真アプリが読めるのは MP4 (H.264) なので、iPhone / Safari では必ず MP4 を選ぶ
const IS_APPLE_WEBKIT =
  /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (/Safari/.test(navigator.userAgent) && !/Chrome|Chromium|Android/.test(navigator.userAgent));

const MIME_CANDIDATES = [
  'video/mp4;codecs=avc1.640028,mp4a.40.2',
  'video/mp4;codecs=avc1,mp4a',
  'video/mp4;codecs=avc1',
  ...(IS_APPLE_WEBKIT ? ['video/mp4'] : []),
  'video/webm;codecs=vp9,opus',
  'video/webm;codecs=vp8,opus',
  'video/webm',
  'video/mp4',
];

export function pickMimeType() {
  if (typeof MediaRecorder === 'undefined') return '';
  for (const type of MIME_CANDIDATES) {
    if (MediaRecorder.isTypeSupported(type)) return type;
  }
  return '';
}

export function extensionFor(mime) {
  return mime.includes('mp4') ? 'mp4' : 'webm';
}

const canvasStreams = new WeakMap();

/** canvas ごとに captureStream は1回だけ作って使い回す（起動時に作っておくと最初の録画から確実に映る） */
export function canvasVideoTrack(canvas) {
  let stream = canvasStreams.get(canvas);
  if (!stream) {
    stream = canvas.captureStream(30);
    canvasStreams.set(canvas, stream);
  }
  return stream.getVideoTracks()[0];
}

/**
 * 録画を開始する。stop() で Blob を返す Promise を得る。
 * @param {HTMLCanvasElement} canvas
 * @param {MediaStreamTrack|null} audioTrack
 * @param {number} bitrate
 */
export function startRecording(canvas, audioTrack, bitrate) {
  const tracks = [canvasVideoTrack(canvas)];
  if (audioTrack && audioTrack.readyState === 'live') tracks.push(audioTrack);
  const stream = new MediaStream(tracks);
  const mimeType = pickMimeType();
  const options = { videoBitsPerSecond: bitrate, audioBitsPerSecond: 128000 };
  if (mimeType) options.mimeType = mimeType;

  const recorder = new MediaRecorder(stream, options);
  const chunks = [];
  recorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) chunks.push(e.data);
  };
  const done = new Promise((resolve, reject) => {
    recorder.onstop = () => {
      const type = recorder.mimeType || mimeType || 'video/mp4';
      resolve(new Blob(chunks, { type }));
    };
    recorder.onerror = (e) => reject(e.error || new Error('録画に失敗しました'));
  });
  recorder.start();

  return {
    mimeType: recorder.mimeType || mimeType,
    stop() {
      if (recorder.state !== 'inactive') recorder.stop();
      return done;
    },
  };
}
