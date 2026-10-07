import { FrameRenderer } from './renderer.js';
import { FILTERS } from './filters.js';
import { startRecording, extensionFor, canvasVideoTrack } from './recorder.js';
import { concatenate } from './composer.js';
import * as store from './store.js';
import { toast, shareToPhotos } from './ui.js';

const CLIP_DURATION_MS = 2000;
const SIZES = {
  portrait: [1080, 1920],
  wide: [1280, 720], // 縦の映像の中央を横長に切り抜くため、この解像度で十分
};

const $ = (sel) => document.querySelector(sel);

const els = {
  camera: $('#camera'),
  canvasMain: $('#canvas-main'),
  canvasWide: $('#canvas-wide'),
  previewMain: $('#preview-main'),
  previewWide: $('#preview-wide'),
  stage: $('#stage'),
  shutter: $('#shutter'),
  zoom: $('#btn-zoom'),
  filter: $('#btn-filter'),
  time: $('#btn-time'),
  grid: $('#btn-grid'),
  torch: $('#btn-torch'),
  switchCam: $('#btn-switch'),
  libraryButton: $('#btn-library'),
  recTimer: $('#rec-timer'),
  toast: $('#toast'),
  saveBar: $('#save-bar'),
  cameraMessage: $('#camera-message'),
};

const state = {
  mode: 'vlog',
  filter: 0,
  photoTime: true,
  grid: false,
  torch: false,
  facing: 'environment',
  zoom: 1,
  recording: null, // { kind, frozenText, startedAt, ... }
  videoStream: null,
  audioTrack: null,
};

const mainRenderer = new FrameRenderer(els.canvasMain);
const wideRenderer = new FrameRenderer(els.canvasWide);

// ---------------------------------------------------------------- カメラ

async function startCamera() {
  els.cameraMessage.classList.add('hidden');
  if (state.videoStream) state.videoStream.getTracks().forEach((t) => t.stop());
  try {
    state.videoStream = await navigator.mediaDevices.getUserMedia({
      video: {
        facingMode: state.facing,
        width: { ideal: 1920 },
        height: { ideal: 1080 },
        frameRate: { ideal: 30 },
      },
      audio: false,
    });
  } catch (e) {
    console.error(e);
    els.cameraMessage.classList.remove('hidden');
    return;
  }
  els.camera.srcObject = state.videoStream;
  try {
    await els.camera.play();
  } catch (_) {
    // autoplay が止められた場合は次のタップで再生
  }

  const track = state.videoStream.getVideoTracks()[0];
  const caps = track.getCapabilities ? track.getCapabilities() : {};
  els.torch.classList.toggle('hidden', !caps.torch);
  state.torch = false;
  els.torch.classList.remove('active');

  if (!state.audioTrack) {
    try {
      const mic = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      state.audioTrack = mic.getAudioTracks()[0] || null;
    } catch (_) {
      state.audioTrack = null; // マイクなしでも撮影はできる
    }
  }
}

async function setTorch(on) {
  const track = state.videoStream && state.videoStream.getVideoTracks()[0];
  if (!track) return;
  try {
    await track.applyConstraints({ advanced: [{ torch: on }] });
  } catch (_) {
    // 非対応
  }
}

// ---------------------------------------------------------------- 描画

function outputSizeForMain() {
  if (state.mode === 'photo') {
    const vw = els.camera.videoWidth || 1080;
    const vh = els.camera.videoHeight || 1920;
    return vw > vh ? [1440, 1080] : [1080, 1440];
  }
  return SIZES.portrait;
}

function currentText() {
  if (state.recording && state.recording.frozenText !== undefined) return state.recording.frozenText;
  if (state.mode === 'vlog') return store.hourLabel(Date.now());
  if (state.mode === 'photo' && state.photoTime) return store.hourLabel(Date.now());
  return null; // VIDEO は時刻なし
}

function renderFrame() {
  const [mw, mh] = outputSizeForMain();
  mainRenderer.setSize(mw, mh);
  const opts = {
    filter: state.recording ? state.recording.filter : state.filter,
    text: currentText(),
    mirror: state.facing === 'user',
    zoom: state.zoom,
  };
  const ok = mainRenderer.render(els.camera, opts);
  if (state.mode === 'video') {
    wideRenderer.setSize(...SIZES.wide);
    wideRenderer.render(els.camera, opts);
  }
  return ok;
}

let lastLayoutKey = '';
function loop() {
  renderFrame();
  const key = `${state.mode}|${els.stage.clientWidth}x${els.stage.clientHeight}|${els.canvasMain.width}x${els.canvasMain.height}`;
  if (key !== lastLayoutKey) {
    lastLayoutKey = key;
    layout();
  }
  if (state.recording && state.recording.kind === 'video') {
    const s = Math.floor((Date.now() - state.recording.startedAt) / 1000);
    els.recTimer.querySelector('.time').textContent =
      `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  }
  requestAnimationFrame(loop);
}

/** プレビューを画面内に収まるサイズに配置する */
function layout() {
  const sw = els.stage.clientWidth - 16;
  const sh = els.stage.clientHeight;
  const fit = (aspect, maxW, maxH) => {
    let w = maxW;
    let h = w / aspect;
    if (h > maxH) {
      h = maxH;
      w = h * aspect;
    }
    return [Math.floor(w), Math.floor(h)];
  };

  if (state.mode === 'video') {
    const [ww, wh] = fit(16 / 9, sw, sh * 0.45);
    const [mw, mh] = fit(9 / 16, sw, sh - wh - 8);
    Object.assign(els.previewWide.style, { width: `${ww}px`, height: `${wh}px` });
    Object.assign(els.previewMain.style, { width: `${mw}px`, height: `${mh}px` });
  } else {
    const aspect = els.canvasMain.width / els.canvasMain.height;
    const [mw, mh] = fit(aspect, sw, sh);
    Object.assign(els.previewMain.style, { width: `${mw}px`, height: `${mh}px` });
  }
}

// ---------------------------------------------------------------- 撮影

function thumbnailFrom(canvas, maxSide = 360) {
  const scale = maxSide / Math.max(canvas.width, canvas.height);
  const c = document.createElement('canvas');
  c.width = Math.round(canvas.width * scale);
  c.height = Math.round(canvas.height * scale);
  c.getContext('2d').drawImage(canvas, 0, 0, c.width, c.height);
  return c.toDataURL('image/jpeg', 0.7);
}

function dataURLToBlob(dataURL) {
  const [head, body] = dataURL.split(',');
  const mime = head.match(/:(.*?);/)[1];
  const bin = atob(body);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type: mime });
}

function setRecordingUI(on) {
  els.shutter.classList.toggle('recording', on);
  const lock = [els.switchCam, els.libraryButton, els.filter, ...document.querySelectorAll('.modes button')];
  lock.forEach((b) => { b.disabled = on; });
  els.recTimer.classList.toggle('hidden', !(on && state.mode === 'video'));
}

/** VLOG：1タップで2秒録画 → 自動停止 → アプリ内に保存 */
async function recordVlogClip() {
  if (state.recording) return;
  const startedAt = Date.now();
  const filter = state.filter;
  state.recording = { kind: 'vlog', frozenText: store.hourLabel(startedAt), filter, startedAt };
  renderFrame(); // 固定した時刻で1枚描いてから録画開始
  setRecordingUI(true);
  if (state.torch) setTorch(true);

  let thumb = null;
  try {
    const rec = startRecording(els.canvasMain, state.audioTrack, 8_000_000);
    const thumbTimer = setTimeout(() => { thumb = thumbnailFrom(els.canvasMain); }, CLIP_DURATION_MS / 2);
    await new Promise((r) => setTimeout(r, CLIP_DURATION_MS));
    const blob = await rec.stop();
    clearTimeout(thumbTimer);
    if (blob.size < 2000) throw new Error('empty recording');
    if (!thumb) thumb = thumbnailFrom(els.canvasMain);
    await store.putClip({
      id: store.newId(),
      recordedAt: startedAt,
      filter: FILTERS[filter].name,
      blob,
      mime: blob.type,
      thumb,
    });
    updateLibraryButton(thumb);
  } catch (e) {
    console.error(e);
    toast('録画に失敗しました');
  } finally {
    state.recording = null;
    setRecordingUI(false);
  }
}

/** VIDEO：9:16 と 16:9 を同時に録画 */
async function toggleVideo() {
  if (state.recording && state.recording.kind === 'video') {
    const rec = state.recording;
    state.recording = null;
    setRecordingUI(false);
    try {
      const [portrait, wide] = await Promise.all([rec.main.stop(), rec.wide.stop()]);
      const stamp = fileStamp(rec.startedAt);
      const items = [
        { blob: portrait, name: `VIDEO-${stamp}-9x16`, thumb: rec.thumbMain },
        { blob: wide, name: `VIDEO-${stamp}-16x9`, thumb: rec.thumbWide },
      ].map((v) => ({
        id: store.newId(),
        kind: 'video',
        createdAt: rec.startedAt,
        blob: v.blob,
        mime: v.blob.type,
        name: `${v.name}.${extensionFor(v.blob.type)}`,
        thumb: v.thumb,
      }));
      for (const item of items) await store.putMedia(item);
      offerSave(items, '9:16 と 16:9 を撮影しました');
    } catch (e) {
      console.error(e);
      toast('録画に失敗しました');
    }
    return;
  }
  if (state.recording) return;

  const startedAt = Date.now();
  renderFrame();
  const audio2 = state.audioTrack ? state.audioTrack.clone() : null;
  state.recording = {
    kind: 'video',
    frozenText: null,
    filter: state.filter,
    startedAt,
    main: startRecording(els.canvasMain, state.audioTrack, 8_000_000),
    wide: startRecording(els.canvasWide, audio2, 5_000_000),
    thumbMain: thumbnailFrom(els.canvasMain),
    thumbWide: thumbnailFrom(els.canvasWide),
  };
  setRecordingUI(true);
  if (state.torch) setTorch(true);
}

/** PHOTO */
async function takePhoto() {
  const text = state.photoTime ? store.hourLabel(Date.now()) : null;
  state.recording = { kind: 'photo', frozenText: text, filter: state.filter };
  renderFrame();
  const dataURL = els.canvasMain.toDataURL('image/jpeg', 0.92);
  const thumb = thumbnailFrom(els.canvasMain);
  state.recording = null;

  document.querySelectorAll('#preview-main .blink').forEach((b) => {
    b.classList.remove('on');
    void b.offsetWidth;
    b.classList.add('on');
  });

  const blob = dataURLToBlob(dataURL);
  const item = {
    id: store.newId(),
    kind: 'photo',
    createdAt: Date.now(),
    blob,
    mime: 'image/jpeg',
    name: `PHOTO-${fileStamp(Date.now())}.jpg`,
    thumb,
  };
  await store.putMedia(item);
  offerSave([item], '写真を撮影しました');
}

function fileStamp(time) {
  const d = new Date(time);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// ---------------------------------------------------------------- 写真アプリへの保存

let saveBarItems = [];
let saveBarTimer = null;
function offerSave(items, label) {
  saveBarItems = items;
  els.saveBar.querySelector('.label').textContent = label;
  els.saveBar.classList.remove('hidden');
  clearTimeout(saveBarTimer);
  saveBarTimer = setTimeout(() => els.saveBar.classList.add('hidden'), 8000);
}

els.saveBar.querySelector('.primary').addEventListener('click', async () => {
  els.saveBar.classList.add('hidden');
  await shareToPhotos(saveBarItems);
});
els.saveBar.querySelector('.close').addEventListener('click', () => els.saveBar.classList.add('hidden'));

// ---------------------------------------------------------------- UI

function setMode(mode) {
  if (state.recording) return;
  state.mode = mode;
  document.querySelectorAll('.modes button').forEach((b) => b.classList.toggle('selected', b.dataset.mode === mode));
  els.shutter.className = `shutter mode-${mode}`;
  els.time.classList.toggle('hidden', mode !== 'photo');
  els.previewWide.classList.toggle('hidden', mode !== 'video');
  els.previewMain.querySelector('.badge').classList.toggle('hidden', mode !== 'video');
  lastLayoutKey = '';
}

function updateLibraryButton(thumb) {
  els.libraryButton.style.backgroundImage = thumb ? `url(${thumb})` : '';
}

function setZoom(z) {
  state.zoom = Math.min(5, Math.max(1, z));
  const r = Math.round(state.zoom * 10) / 10;
  els.zoom.textContent = `${Number.isInteger(r) ? r : r.toFixed(1)}x`;
}

els.shutter.addEventListener('click', () => {
  if (state.mode === 'vlog') recordVlogClip();
  else if (state.mode === 'video') toggleVideo();
  else takePhoto();
});

document.querySelectorAll('.modes button').forEach((b) => b.addEventListener('click', () => setMode(b.dataset.mode)));

els.filter.addEventListener('click', () => {
  state.filter = (state.filter + 1) % FILTERS.length;
  els.filter.textContent = FILTERS[state.filter].name;
  els.filter.classList.toggle('active', state.filter !== 0);
});

els.time.addEventListener('click', () => {
  state.photoTime = !state.photoTime;
  els.time.textContent = state.photoTime ? '時刻 ON' : '時刻 OFF';
  els.time.classList.toggle('active', state.photoTime);
});

els.grid.addEventListener('click', () => {
  state.grid = !state.grid;
  els.grid.classList.toggle('active', state.grid);
  document.querySelectorAll('.preview .grid').forEach((g) => g.classList.toggle('hidden', !state.grid));
});

els.torch.addEventListener('click', () => {
  state.torch = !state.torch;
  els.torch.classList.toggle('active', state.torch);
  if (state.mode === 'photo' || state.recording) setTorch(state.torch);
});

els.switchCam.addEventListener('click', async () => {
  if (state.recording) return;
  state.facing = state.facing === 'environment' ? 'user' : 'environment';
  setZoom(1);
  await startCamera();
});

els.zoom.addEventListener('click', () => {
  setZoom(state.zoom < 1.5 ? 2 : state.zoom < 2.5 ? 3 : 1);
});

// ピンチでズーム
let pinch = null;
els.stage.addEventListener('touchstart', (e) => {
  if (e.touches.length === 2) {
    const [a, b] = e.touches;
    pinch = { dist: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), zoom: state.zoom };
  }
}, { passive: true });
els.stage.addEventListener('touchmove', (e) => {
  if (pinch && e.touches.length === 2) {
    const [a, b] = e.touches;
    const dist = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
    setZoom(pinch.zoom * (dist / pinch.dist));
  }
}, { passive: true });
els.stage.addEventListener('touchend', () => { pinch = null; });

$('#btn-retry').addEventListener('click', startCamera);

// iOS は一度タップしないと映像が止まったままのことがある
document.addEventListener('click', () => {
  if (els.camera.paused && els.camera.srcObject) els.camera.play().catch(() => {});
}, { capture: true });

// ---------------------------------------------------------------- 起動

async function init() {
  document.documentElement.style.setProperty('--clip-duration', `${CLIP_DURATION_MS}ms`);
  store.requestPersistence();
  const clips = await store.allClips();
  if (clips.length) updateLibraryButton(clips[clips.length - 1].thumb);

  const { initLibrary } = await import('./library.js');
  initLibrary({ onClose: async () => {
    const all = await store.allClips();
    updateLibraryButton(all.length ? all[all.length - 1].thumb : null);
  } });

  requestAnimationFrame(loop);
  await startCamera();
  canvasVideoTrack(els.canvasMain);
  canvasVideoTrack(els.canvasWide);

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
}

init();
