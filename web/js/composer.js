// その日のクリップを撮影順にそのままつないで1本の動画にする。
// フェード・エフェクト・速度変更なし。各クリップは時刻入りなので、つないだ後も時刻が残る。
// ブラウザには動画を直接つなぐ機能がないため、クリップを順に再生しながら録画し直す
// （合計の長さぶん時間がかかる）。

import { startRecording } from './recorder.js';
import { remuxConcat } from './remux.js';

function makeVideo(host) {
  const v = document.createElement('video');
  v.muted = true;
  v.playsInline = true;
  v.setAttribute('playsinline', '');
  v.preload = 'auto';
  v.className = 'offscreen';
  host.appendChild(v);
  return v;
}

function waitFor(el, event, timeoutMs) {
  return new Promise((resolve) => {
    let timer = null;
    const done = () => {
      el.removeEventListener(event, done);
      clearTimeout(timer);
      resolve();
    };
    el.addEventListener(event, done);
    timer = setTimeout(done, timeoutMs);
  });
}

function load(video, url) {
  video.src = url;
  video.load();
  return video.readyState >= 2 ? Promise.resolve() : waitFor(video, 'loadeddata', 5000);
}

/**
 * @param {Blob[]} blobs  撮影順のクリップ
 * @param {{width:number, height:number, onProgress?:(done:number,total:number)=>void}} opts
 * @returns {Promise<Blob>}
 */
export async function concatenate(blobs, { width, height, onProgress }) {
  if (!blobs.length) throw new Error('保存できる動画がありません');

  // まずは再生せずにそのままつなぐ（速い・画質劣化なし・RETRO など重い動画でも縮まない）
  try {
    const joined = await remuxConcat(blobs);
    if (joined) {
      if (onProgress) onProgress(blobs.length, blobs.length);
      return joined;
    }
  } catch (e) {
    console.warn('remux failed, falling back to re-recording', e);
  }
  return reRecord(blobs, { width, height, onProgress });
}

/** 予備の方式：クリップを順に再生しながら録画し直す（合計の長さぶん時間がかかる） */
async function reRecord(blobs, { width, height, onProgress }) {

  const host = document.createElement('div');
  host.className = 'offscreen-host';
  document.body.appendChild(host);

  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  canvas.className = 'offscreen';
  host.appendChild(canvas);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, width, height);

  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  const audioCtx = new AudioCtx();
  try {
    await audioCtx.resume();
  } catch (_) {
    // 失敗しても映像だけは書き出す
  }
  const dest = audioCtx.createMediaStreamDestination();
  const audioBuffers = await Promise.all(
    blobs.map(async (b) => {
      try {
        return await audioCtx.decodeAudioData(await b.arrayBuffer());
      } catch (_) {
        return null; // 音声なしのクリップ
      }
    }),
  );

  const urls = blobs.map((b) => URL.createObjectURL(b));
  const players = [makeVideo(host), makeVideo(host)];

  let active = null;
  let running = true;
  const draw = () => {
    if (active && active.readyState >= 2) {
      // 比率が違うクリップ（以前の縦動画など）は黒帯を付けて収める
      const vw = active.videoWidth || width;
      const vh = active.videoHeight || height;
      const scale = Math.min(width / vw, height / vh);
      const dw = vw * scale;
      const dh = vh * scale;
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, width, height);
      ctx.drawImage(active, (width - dw) / 2, (height - dh) / 2, dw, dh);
    }
    if (running) requestAnimationFrame(draw);
  };

  let recording = null;
  try {
    await load(players[0], urls[0]);
    active = players[0];
    draw();

    recording = startRecording(canvas, dest.stream.getAudioTracks()[0], 10_000_000);

    for (let i = 0; i < urls.length; i++) {
      const video = players[i % 2];
      if (i > 0) await (video.readyState >= 2 ? Promise.resolve() : waitFor(video, 'loadeddata', 5000));

      // 次のクリップを先読み
      if (i + 1 < urls.length) load(players[(i + 1) % 2], urls[i + 1]);

      video.currentTime = 0;
      const duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 2;
      const ended = waitFor(video, 'ended', (duration + 2) * 1000);
      await video.play();
      active = video;

      const buffer = audioBuffers[i];
      if (buffer) {
        const source = audioCtx.createBufferSource();
        source.buffer = buffer;
        source.connect(dest);
        source.start();
      }

      await ended;
      if (onProgress) onProgress(i + 1, urls.length);
    }

    running = false;
    return await recording.stop();
  } finally {
    running = false;
    if (recording) recording.stop();
    urls.forEach((u) => URL.revokeObjectURL(u));
    audioCtx.close().catch(() => {});
    host.remove();
  }
}
