// MP4 クリップを「再生せずに」そのままつなぐ（再エンコードなし・画質劣化なし・端末の重さに左右されない）。
// iPhone の Safari が録画した MP4 (H.264 / AAC) が対象。つなげない形式の場合は null を返し、
// 呼び出し側で従来の「再生しながら録画し直す」方式に切り替える。

import { Muxer, ArrayBufferTarget } from '../vendor/mp4-muxer.mjs';

let mp4boxLoading = null;

/** mp4box.js（普通のスクリプト）を必要な時だけ読み込む */
function loadMP4Box() {
  if (window.MP4Box) return Promise.resolve(window.MP4Box);
  if (!mp4boxLoading) {
    mp4boxLoading = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = new URL('../vendor/mp4box.all.min.js', import.meta.url).href;
      script.onload = () => (window.MP4Box ? resolve(window.MP4Box) : reject(new Error('mp4box not found')));
      script.onerror = () => reject(new Error('mp4box load failed'));
      document.head.appendChild(script);
    });
  }
  return mp4boxLoading;
}

function boxPayload(MP4Box, box) {
  const DS = MP4Box.DataStream || window.DataStream;
  const stream = new DS(undefined, 0, DS.BIG_ENDIAN);
  box.write(stream);
  return new Uint8Array(stream.buffer, 8); // 先頭8バイト（サイズ・種類）を除いた中身
}

function sameBytes(a, b) {
  if (!a || !b) return a === b;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** 1本の MP4 から、映像・音声のサンプル（圧縮されたままのデータ）と設定を取り出す */
async function demux(MP4Box, blob) {
  const buffer = await blob.arrayBuffer();
  return new Promise((resolve, reject) => {
    const file = MP4Box.createFile();
    const samples = {};
    let info = null;
    file.onError = (e) => reject(new Error(String(e)));
    file.onReady = (i) => {
      info = i;
      for (const track of [i.videoTracks[0], i.audioTracks[0]]) {
        if (!track) continue;
        samples[track.id] = [];
        file.setExtractionOptions(track.id, null, { nbSamples: Infinity });
      }
      file.start();
    };
    file.onSamples = (id, _user, list) => {
      samples[id].push(...list);
    };
    buffer.fileStart = 0;
    file.appendBuffer(buffer);
    file.flush();

    if (!info) {
      reject(new Error('not an mp4'));
      return;
    }
    const v = info.videoTracks[0];
    if (!v) {
      reject(new Error('no video track'));
      return;
    }
    const vEntry = file.getTrackById(v.id).mdia.minf.stbl.stsd.entries[0];
    const vBox = vEntry.avcC || vEntry.hvcC;
    if (!vBox) {
      reject(new Error('unsupported video codec'));
      return;
    }
    const result = {
      video: {
        codec: v.codec,
        kind: vEntry.avcC ? 'avc' : 'hevc',
        width: v.video ? v.video.width : v.track_width,
        height: v.video ? v.video.height : v.track_height,
        description: boxPayload(MP4Box, vBox),
        samples: samples[v.id] || [],
      },
      audio: null,
    };

    const a = info.audioTracks[0];
    if (a && /^mp4a/.test(a.codec)) {
      const aEntry = file.getTrackById(a.id).mdia.minf.stbl.stsd.entries[0];
      let asc = null;
      try {
        asc = aEntry.esds.esd.findDescriptor(4).findDescriptor(5).data;
      } catch (_) {
        asc = null;
      }
      result.audio = {
        codec: a.codec,
        sampleRate: a.audio ? a.audio.sample_rate : aEntry.getSampleRate(),
        channels: a.audio ? a.audio.channel_count : aEntry.getChannelCount(),
        description: asc ? new Uint8Array(asc) : null,
        samples: samples[a.id] || [],
      };
    }
    resolve(result);
  });
}

/**
 * @param {Blob[]} blobs 撮影順のクリップ
 * @returns {Promise<Blob|null>} つないだ MP4。この方式でつなげない場合は null。
 */
export async function remuxConcat(blobs) {
  if (!blobs.length || !blobs.every((b) => /mp4/.test(b.type))) return null;

  const MP4Box = await loadMP4Box();
  const clips = [];
  for (const blob of blobs) clips.push(await demux(MP4Box, blob));

  // すべてのクリップが同じ形式（解像度・圧縮設定）でないと、そのままはつなげない
  const first = clips[0];
  const sameVideo = clips.every((c) =>
    c.video.kind === first.video.kind &&
    c.video.width === first.video.width &&
    c.video.height === first.video.height &&
    sameBytes(c.video.description, first.video.description));
  if (!sameVideo) return null;

  const audioClips = clips.filter((c) => c.audio && c.audio.description);
  const useAudio = audioClips.length > 0 && audioClips.every((c) =>
    c.audio.sampleRate === audioClips[0].audio.sampleRate &&
    c.audio.channels === audioClips[0].audio.channels &&
    sameBytes(c.audio.description, audioClips[0].audio.description));
  const audioRef = useAudio ? audioClips[0].audio : null;

  const target = new ArrayBufferTarget();
  const muxer = new Muxer({
    target,
    fastStart: 'in-memory',
    firstTimestampBehavior: 'offset',
    video: { codec: first.video.kind, width: first.video.width, height: first.video.height },
    audio: audioRef ? { codec: 'aac', numberOfChannels: audioRef.channels, sampleRate: audioRef.sampleRate } : undefined,
  });

  const videoMeta = {
    decoderConfig: {
      codec: first.video.codec,
      codedWidth: first.video.width,
      codedHeight: first.video.height,
      description: first.video.description,
    },
  };
  const audioMeta = audioRef ? {
    decoderConfig: {
      codec: audioRef.codec,
      sampleRate: audioRef.sampleRate,
      numberOfChannels: audioRef.channels,
      description: audioRef.description,
    },
  } : undefined;

  const US = 1_000_000;
  let offset = 0; // このクリップの開始位置（マイクロ秒）
  let lastAudioEnd = 0;
  let firstVideo = true;
  let firstAudio = true;

  for (const clip of clips) {
    const vs = clip.video.samples;
    if (!vs.length) continue;
    const scale = vs[0].timescale;
    const startDts = vs[0].dts;
    const startCts = Math.min(...vs.map((s) => s.cts));
    let clipEnd = 0;

    for (const s of vs) {
      const t = offset + ((s.cts - startCts) / scale) * US;
      const dur = (s.duration / scale) * US;
      const cto = ((s.cts - s.dts) - (startCts - startDts)) / scale * US;
      muxer.addVideoChunkRaw(s.data, s.is_sync ? 'key' : 'delta', t, dur, firstVideo ? videoMeta : undefined, cto);
      firstVideo = false;
      clipEnd = Math.max(clipEnd, t + dur);
    }

    if (audioRef && clip.audio && clip.audio.description) {
      const as = clip.audio.samples;
      const ascale = as.length ? as[0].timescale : 1;
      // 映像の開始時刻に音声を合わせる
      const videoStartSec = startCts / scale;
      for (const s of as) {
        const t = offset + (s.cts / ascale - videoStartSec) * US;
        const dur = (s.duration / ascale) * US;
        if (t < offset || t < lastAudioEnd - 1 || t >= clipEnd) continue;
        muxer.addAudioChunkRaw(s.data, 'key', t, dur, firstAudio ? audioMeta : undefined);
        firstAudio = false;
        lastAudioEnd = t + dur;
      }
    }

    offset = clipEnd;
  }

  muxer.finalize();
  return new Blob([target.buffer], { type: 'video/mp4' });
}
