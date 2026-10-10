import { FrameRenderer, loadTimeFont } from './renderer.js';
import { FILTERS } from './filters.js';
import { startRecording, extensionFor, canvasVideoTrack } from './recorder.js';
import { concatenate } from './composer.js';
import * as store from './store.js';
import { toast, shareToPhotos } from './ui.js';

// アプリのバージョン（更新したら上げる）
const APP_VERSION = '2.4';

const CLIP_DURATION_MS = 2000;
const SIZES = {
  vlog: [1920, 1080], // VLOG は横 16:9
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
  snap: $('#btn-snap'),
  libraryButton: $('#btn-library'),
  recTimer: $('#rec-timer'),
  toast: $('#toast'),
  saveBar: $('#save-bar'),
  cameraMessage: $('#camera-message'),
};

const state = {
  mode: 'vlog',
  filter: 0,
  // PHOTO の時刻：入れる写真（both / portrait / landscape / none）と位置（center / bottom）
  photoTimeTarget: 'both',
  photoTimePosition: 'center',
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

}

/**
 * マイクは録画するときに初めて使う（起動しただけではマイクを使わない）。
 * iPhone はマイクを使い始めると音やオレンジの点で知らせるため。
 */
let micPromise = null;
function ensureMic() {
  if (state.audioTrack && state.audioTrack.readyState === 'live') return Promise.resolve(state.audioTrack);
  if (!micPromise) {
    micPromise = navigator.mediaDevices.getUserMedia({ audio: true, video: false })
      .then((mic) => (state.audioTrack = mic.getAudioTracks()[0] || null))
      .catch(() => (state.audioTrack = null)) // マイクなしでも撮影はできる
      .finally(() => { micPromise = null; });
  }
  return micPromise;
}

/** アプリを閉じた・切り替えたらマイクを止める */
function releaseMic() {
  if (state.audioTrack) state.audioTrack.stop();
  state.audioTrack = null;
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

/** VIDEO と PHOTO は 9:16 と 16:9 を同時に表示・保存する */
function isDualMode() {
  return state.mode === 'video' || state.mode === 'photo';
}

function outputSizeForMain() {
  if (state.mode === 'vlog') return SIZES.vlog;
  return SIZES.portrait;
}

function currentText() {
  if (state.recording && state.recording.frozenText !== undefined) return state.recording.frozenText;
  if (state.mode === 'vlog') return store.hourLabel(Date.now());
  if (state.mode === 'photo' && state.photoTimeTarget !== 'none') return store.hourLabel(Date.now());
  return null; // VIDEO は時刻なし
}

/** PHOTO では「時刻を入れる写真」の設定に合わせて、縦・横それぞれに入れるか決める */
function textFor(output) {
  const text = currentText();
  if (!text || state.mode !== 'photo') return text;
  const target = state.photoTimeTarget;
  if (target === 'both') return text;
  if (target === 'portrait') return output === 'main' ? text : null;
  if (target === 'landscape') return output === 'wide' ? text : null;
  return null;
}

function renderFrame() {
  const [mw, mh] = outputSizeForMain();
  mainRenderer.setSize(mw, mh);
  const opts = {
    filter: state.recording ? state.recording.filter : state.filter,
    mirror: state.facing === 'user',
    zoom: state.zoom,
    textPosition: state.mode === 'photo' ? state.photoTimePosition : 'center',
  };
  const ok = mainRenderer.render(els.camera, { ...opts, text: textFor('main') });
  if (isDualMode()) {
    wideRenderer.setSize(...SIZES.wide);
    wideRenderer.render(els.camera, { ...opts, text: textFor('wide') });
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

  if (isDualMode()) {
    const landscape = sw > sh;
    els.stage.style.flexDirection = landscape ? 'row' : 'column';
    let ww, wh, mw, mh;
    if (landscape) {
      // 横持ち：9:16 と 16:9 を左右に並べる
      [ww, wh] = fit(16 / 9, sw * 0.68, sh);
      [mw, mh] = fit(9 / 16, sw - ww - 8, sh);
    } else {
      [ww, wh] = fit(16 / 9, sw, sh * 0.45);
      [mw, mh] = fit(9 / 16, sw, sh - wh - 8);
    }
    Object.assign(els.previewWide.style, { width: `${ww}px`, height: `${wh}px` });
    Object.assign(els.previewMain.style, { width: `${mw}px`, height: `${mh}px` });
  } else {
    els.stage.style.flexDirection = 'column';
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
  const videoRecording = on && state.mode === 'video';
  els.recTimer.classList.toggle('hidden', !videoRecording);
  // VIDEO 録画中は、カメラ切り替えの位置に写真ボタンを出す
  els.switchCam.classList.toggle('hidden', videoRecording);
  els.snap.classList.toggle('hidden', !videoRecording);
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
    await ensureMic();
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

let videoStarting = false;

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
      // 録画中に撮った写真も一緒に保存できるようにする
      const photos = rec.snaps.length / 2;
      offerSave([...items, ...rec.snaps], photos ? `動画と写真${photos}回分を撮影しました` : '9:16 と 16:9 を撮影しました');
    } catch (e) {
      console.error(e);
      toast('録画に失敗しました');
    }
    return;
  }
  if (state.recording || videoStarting) return;

  videoStarting = true;
  try {
    await ensureMic();
  } finally {
    videoStarting = false;
  }
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
    snaps: [], // 録画中に撮った写真
  };
  setRecordingUI(true);
  if (state.torch) setTorch(true);
}

/** PHOTO：VIDEO と同じく 9:16 と 16:9 の2枚を同時に撮る */
async function takePhoto() {
  const now = Date.now();
  const text = state.photoTimeTarget !== 'none' ? store.hourLabel(now) : null;
  state.recording = { kind: 'photo', frozenText: text, filter: state.filter };
  renderFrame();
  const shots = [
    { canvas: els.canvasMain, ratio: '9x16' },
    { canvas: els.canvasWide, ratio: '16x9' },
  ].map(({ canvas, ratio }) => ({
    ratio,
    dataURL: canvas.toDataURL('image/jpeg', 0.92),
    thumb: thumbnailFrom(canvas),
  }));
  state.recording = null;
  await savePhotos(shots, now);
}

/**
 * VIDEO 録画中に写真を撮る。動画は止めずに、今のフレーム（9:16 / 16:9）をそのまま写真にする。
 * VIDEO と同じく時刻は入れない。
 */
async function snapDuringVideo() {
  if (!state.recording || state.recording.kind !== 'video') return;
  const now = Date.now();
  const shots = [
    { canvas: els.canvasMain, ratio: '9x16' },
    { canvas: els.canvasWide, ratio: '16x9' },
  ].map(({ canvas, ratio }) => ({
    ratio,
    dataURL: canvas.toDataURL('image/jpeg', 0.92),
    thumb: thumbnailFrom(canvas),
  }));
  const rec = state.recording;
  const items = await savePhotos(shots, now);
  rec.snaps.push(...items);
  toast('写真を撮りました');
}

async function savePhotos(shots, now) {
  document.querySelectorAll('.preview .blink').forEach((b) => {
    b.classList.remove('on');
    void b.offsetWidth;
    b.classList.add('on');
  });

  const stamp = fileStamp(now);
  const items = shots.map((shot) => ({
    id: store.newId(),
    kind: 'photo',
    createdAt: now,
    blob: dataURLToBlob(shot.dataURL),
    mime: 'image/jpeg',
    name: `PHOTO-${stamp}-${shot.ratio}.jpg`,
    thumb: shot.thumb,
  }));
  for (const item of items) await store.putMedia(item);
  // 録画中は保存バーを出さない（あとで素材一覧の VIDEO・PHOTO から保存できる）
  if (state.mode === 'photo') offerSave(items, '9:16 と 16:9 を撮影しました');
  return items;
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
  timeMenu.classList.add('hidden');
  const dual = mode === 'video' || mode === 'photo';
  els.previewWide.classList.toggle('hidden', !dual);
  els.previewMain.querySelector('.badge').classList.toggle('hidden', !dual);
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

els.snap.addEventListener('click', snapDuringVideo);

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

// 写真の時刻：入れる写真（縦と横 / 縦だけ / 横だけ / 入れない）と位置（真ん中 / 下）を選べる。
// 選んだ設定は覚えておく（開き直しても戻らない）
const PHOTO_TIME_KEY = 'vlogcam-photo-time-v2';
const OLD_PHOTO_TIME_KEY = 'vlogcam-photo-time';
const timeMenu = $('#time-menu');

function showPhotoTime() {
  const t = state.photoTimeTarget;
  const pos = state.photoTimePosition === 'bottom' ? '下' : '真ん中';
  const which = { both: '', portrait: '・縦だけ', landscape: '・横だけ' }[t] || '';
  els.time.textContent = t === 'none' ? '時刻 OFF' : `時刻 ${pos}${which}`;
  els.time.classList.toggle('active', t !== 'none');
  timeMenu.querySelectorAll('[data-key]').forEach((group) => {
    const value = group.dataset.key === 'target' ? state.photoTimeTarget : state.photoTimePosition;
    group.querySelectorAll('button').forEach((b) => b.classList.toggle('selected', b.dataset.value === value));
  });
  timeMenu.querySelector('[data-key=position]').classList.toggle('disabled', t === 'none');
}

function savePhotoTime() {
  try {
    localStorage.setItem(PHOTO_TIME_KEY, JSON.stringify({ target: state.photoTimeTarget, position: state.photoTimePosition }));
  } catch (_) {
    // 保存できなくても今回の撮影には反映される
  }
}

try {
  const saved = JSON.parse(localStorage.getItem(PHOTO_TIME_KEY) || 'null');
  if (saved) {
    if (['both', 'portrait', 'landscape', 'none'].includes(saved.target)) state.photoTimeTarget = saved.target;
    if (['center', 'bottom'].includes(saved.position)) state.photoTimePosition = saved.position;
  } else if (localStorage.getItem(OLD_PHOTO_TIME_KEY) === '0') {
    state.photoTimeTarget = 'none'; // 以前の「時刻 OFF」を引き継ぐ
  }
} catch (_) {
  // 保存できない環境では既定値
}
showPhotoTime();

els.time.addEventListener('click', (e) => {
  e.stopPropagation();
  timeMenu.classList.toggle('hidden');
});
timeMenu.addEventListener('click', (e) => {
  e.stopPropagation();
  const button = e.target.closest('button[data-value]');
  if (!button) return;
  const key = button.parentElement.dataset.key;
  if (key === 'target') state.photoTimeTarget = button.dataset.value;
  else state.photoTimePosition = button.dataset.value;
  showPhotoTime();
  savePhotoTime();
});
document.addEventListener('click', () => timeMenu.classList.add('hidden'));

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

document.addEventListener('visibilitychange', () => {
  if (document.hidden && !state.recording) releaseMic();
});

// iOS は一度タップしないと映像が止まったままのことがある
document.addEventListener('click', () => {
  if (els.camera.paused && els.camera.srcObject) els.camera.play().catch(() => {});
}, { capture: true });

// ---------------------------------------------------------------- 起動

/**
 * 「更新」ボタン：最新版を読み込み直す。撮った動画・写真（IndexedDB）は消えない。
 */
async function updateApp() {
  const button = $('#btn-update');
  button.textContent = '更新中…';
  button.disabled = true;
  try {
    const regs = navigator.serviceWorker ? await navigator.serviceWorker.getRegistrations() : [];
    await Promise.all(regs.map((r) => r.update().catch(() => {})));
  } catch (_) {
    // 無視して続行
  }
  try {
    const keys = await caches.keys();
    await Promise.all(keys.map((k) => caches.delete(k)));
  } catch (_) {
    // 無視して続行
  }
  try {
    sessionStorage.setItem('vlogcam-updated', '1');
  } catch (_) {
    // 無視して続行
  }
  location.reload();
}

async function init() {
  $('#btn-update').addEventListener('click', updateApp);
  // 時刻用フォントを読み込み、読み込めたら時刻を描き直す（撮影開始は待たせない）
  loadTimeFont().then(() => {
    mainRenderer.invalidateText();
    wideRenderer.invalidateText();
  });
  try {
    if (sessionStorage.getItem('vlogcam-updated')) {
      sessionStorage.removeItem('vlogcam-updated');
      setTimeout(() => toast(`最新版にしました（ver ${APP_VERSION}）`), 600);
    }
  } catch (_) {
    // 無視
  }
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
