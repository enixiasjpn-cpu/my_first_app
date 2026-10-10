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

/**
 * iPhone の Safari が録画した MP4 は細かいブロック（フラグメント: moof + mdat）に分かれている。
 * mp4box.js はこの形式で、2つ目以降のブロックのコマのデータ位置と時刻を正しく読めない
 * （つないだ動画でコマが壊れて止まって見える原因）。
 * そこでフラグメント部分は仕様（ISO/IEC 14496-12）どおりに自前で読む。
 * @returns {Map<number, object[]>|null} トラックID → サンプル一覧。フラグメントがなければ null。
 */
function parseFragments(buffer, timescales) {
  const view = new DataView(buffer);
  const u8 = new Uint8Array(buffer);
  const len = buffer.byteLength;
  const u32 = (p) => view.getUint32(p);
  const u64 = (p) => Number(view.getBigUint64(p));
  const type = (p) => String.fromCharCode(u8[p], u8[p + 1], u8[p + 2], u8[p + 3]);

  function* children(start, end) {
    let p = start;
    while (p + 8 <= end) {
      let size = u32(p);
      let header = 8;
      if (size === 1) {
        size = u64(p + 8);
        header = 16;
      } else if (size === 0) {
        size = end - p;
      }
      if (size < header || p + size > end) break;
      yield { type: type(p + 4), start: p, body: p + header, end: p + size };
      p += size;
    }
  }

  // trex（既定値）
  const trex = new Map();
  const moofs = [];
  for (const box of children(0, len)) {
    if (box.type === 'moov') {
      for (const m of children(box.body, box.end)) {
        if (m.type !== 'mvex') continue;
        for (const t of children(m.body, m.end)) {
          if (t.type !== 'trex') continue;
          const b = t.body + 4;
          trex.set(u32(b), { sdi: u32(b + 4), duration: u32(b + 8), size: u32(b + 12), flags: u32(b + 16) });
        }
      }
    } else if (box.type === 'moof') {
      moofs.push(box);
    }
  }
  if (!moofs.length) return null;

  const result = new Map();
  const nextDts = new Map();
  for (const moof of moofs) {
    let previousTrafEnd = null;
    let trafIndex = 0;
    for (const traf of children(moof.body, moof.end)) {
      if (traf.type !== 'traf') continue;
      let trackId = 0;
      let base = moof.start;
      let def = { duration: 0, size: 0, flags: 0 };
      let tfdt = null;
      const truns = [];
      for (const box of children(traf.body, traf.end)) {
        if (box.type === 'tfhd') {
          const flags = u32(box.body) & 0xffffff;
          trackId = u32(box.body + 4);
          const ex = trex.get(trackId) || { duration: 0, size: 0, flags: 0 };
          def = { duration: ex.duration, size: ex.size, flags: ex.flags };
          let p = box.body + 8;
          let explicitBase = null;
          if (flags & 0x1) { explicitBase = u64(p); p += 8; }
          if (flags & 0x2) p += 4;
          if (flags & 0x8) { def.duration = u32(p); p += 4; }
          if (flags & 0x10) { def.size = u32(p); p += 4; }
          if (flags & 0x20) { def.flags = u32(p); p += 4; }
          if (explicitBase !== null) base = explicitBase;
          else if (flags & 0x20000) base = moof.start; // default-base-is-moof
          else base = trafIndex === 0 || previousTrafEnd === null ? moof.start : previousTrafEnd;
        } else if (box.type === 'tfdt') {
          const version = u8[box.body];
          tfdt = version === 1 ? u64(box.body + 4) : u32(box.body + 4);
        } else if (box.type === 'trun') {
          truns.push(box);
        }
      }
      trafIndex++;
      if (!trackId || !timescales[trackId]) {
        continue;
      }
      const list = result.get(trackId) || [];
      result.set(trackId, list);
      let dts = tfdt !== null ? tfdt : (nextDts.get(trackId) || 0);
      let dataPos = base;
      for (const trun of truns) {
        const version = u8[trun.body];
        const flags = u32(trun.body) & 0xffffff;
        const count = u32(trun.body + 4);
        let p = trun.body + 8;
        if (flags & 0x1) { dataPos = base + view.getInt32(p); p += 4; }
        let firstFlags = null;
        if (flags & 0x4) { firstFlags = u32(p); p += 4; }
        for (let k = 0; k < count; k++) {
          let duration = def.duration;
          let size = def.size;
          let sampleFlags = k === 0 && firstFlags !== null ? firstFlags : def.flags;
          let cto = 0;
          if (flags & 0x100) { duration = u32(p); p += 4; }
          if (flags & 0x200) { size = u32(p); p += 4; }
          if (flags & 0x400) { sampleFlags = u32(p); p += 4; }
          if (flags & 0x800) { cto = version === 0 ? u32(p) : view.getInt32(p); p += 4; }
          if (dataPos + size > len) throw new Error('sample outside file');
          list.push({
            data: u8.subarray(dataPos, dataPos + size),
            dts,
            cts: dts + cto,
            duration,
            timescale: timescales[trackId],
            is_sync: ((sampleFlags >> 16) & 0x1) === 0,
          });
          dataPos += size;
          dts += duration;
        }
      }
      nextDts.set(trackId, dts);
      previousTrafEnd = dataPos;
    }
  }
  return result;
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
    // moov 内のサンプルは mp4box.js で、フラグメント部分は自前で読む
    const timescales = {};
    for (const track of [info.videoTracks[0], info.audioTracks[0]]) {
      if (!track) continue;
      timescales[track.id] = track.timescale;
      samples[track.id] = [];
      file.setExtractionOptions(track.id, null, { nbSamples: Infinity });
    }
    file.start();
    let fragments = null;
    try {
      fragments = parseFragments(buffer, timescales);
    } catch (e) {
      reject(e);
      return;
    }
    if (fragments) {
      for (const id of Object.keys(samples)) {
        const fromMoov = samples[id].filter((smp) => smp.moof_number === undefined);
        samples[id] = fromMoov.concat(fragments.get(Number(id)) || []);
      }
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

/** 不具合調査用：1本のクリップの中身（タイミング情報）を文字にまとめる */
export async function describeClip(blob) {
  const lines = [`形式: ${blob.type}`, `サイズ: ${(blob.size / 1024).toFixed(0)} KB`];
  if (!/mp4/.test(blob.type)) return lines.join('\n');
  const MP4Box = await loadMP4Box();
  const clip = await demux(MP4Box, blob);
  const fmt = (n) => (Math.round(n * 1000) / 1000).toString();
  const v = clip.video;
  const vs = v.samples;
  if (vs.length) {
    const ts = vs[0].timescale;
    const durs = vs.map((s) => s.duration);
    const ctsList = vs.map((s) => s.cts);
    const minCts = Math.min(...ctsList);
    const maxCts = Math.max(...ctsList);
    let reorder = 0;
    let nonMono = 0;
    for (let i = 1; i < vs.length; i++) {
      if (vs[i].cts !== vs[i].dts) reorder++;
      if (vs[i].dts < vs[i - 1].dts) nonMono++;
    }
    lines.push(
      `映像: ${v.codec} ${v.width}x${v.height}`,
      `  コマ数 ${vs.length} / キー ${vs.filter((s) => s.is_sync).length} / timescale ${ts}`,
      `  最初 cts ${vs[0].cts} dts ${vs[0].dts}`,
      `  cts範囲 ${fmt((maxCts - minCts) / ts)}秒 / 長さ合計 ${fmt(durs.reduce((a, b) => a + b, 0) / ts)}秒`,
      `  1コマ 最小 ${fmt(Math.min(...durs) / ts)} 最大 ${fmt(Math.max(...durs) / ts)}秒 / 最後 ${fmt(durs[durs.length - 1] / ts)}秒`,
      `  並べ替え ${reorder} / dts逆行 ${nonMono}`,
      `  先頭5: ${vs.slice(0, 5).map((s) => `${s.cts}/${s.dts}/${s.duration}`).join(' ')}`,
      `  末尾3: ${vs.slice(-3).map((s) => `${s.cts}/${s.dts}/${s.duration}`).join(' ')}`,
    );
  } else {
    lines.push('映像: サンプルなし');
  }
  if (clip.audio) {
    const as = clip.audio.samples;
    const ats = as.length ? as[0].timescale : 1;
    lines.push(
      `音声: ${clip.audio.codec} ${clip.audio.sampleRate}Hz ${clip.audio.channels}ch`,
      `  フレーム ${as.length} / 最初 cts ${as.length ? as[0].cts : '-'} / 長さ ${fmt(as.reduce((a, s) => a + s.duration, 0) / ats)}秒`,
    );
  } else {
    lines.push('音声: なし');
  }
  lines.push(`avcC: ${Array.from(v.description.slice(0, 24)).map((b) => b.toString(16).padStart(2, '0')).join('')}`);
  return lines.join('\n');
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

    // 1コマの標準的な間隔（中央値）。最後のコマの長さが短く記録されていても、これだけは表示する
    const sortedCts = vs.map((s) => s.cts).sort((a, b) => a - b);
    const gaps = sortedCts.slice(1).map((c, i) => c - sortedCts[i]).filter((g) => g > 0).sort((a, b) => a - b);
    const typicalFrame = gaps.length ? (gaps[Math.floor(gaps.length / 2)] / scale) * US : 0;

    for (const s of vs) {
      const t = offset + ((s.cts - startCts) / scale) * US;
      const dur = Math.max((s.duration / scale) * US, s === vs[vs.length - 1] ? typicalFrame : 0);
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
