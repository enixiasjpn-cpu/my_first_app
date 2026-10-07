// 素材一覧：その日のクリップ一覧・再生・削除・「今日のVLOGを保存」、VIDEO / PHOTO の一覧

import * as store from './store.js';
import { concatenate } from './composer.js';
import { extensionFor } from './recorder.js';
import { toast, shareToPhotos } from './ui.js';

const $ = (sel) => document.querySelector(sel);

const els = {
  sheet: $('#library'),
  daySelect: $('#day-select'),
  clipGrid: $('#clip-grid'),
  clipEmpty: $('#clip-empty'),
  saveDay: $('#btn-save-day'),
  mediaGrid: $('#media-grid'),
  mediaEmpty: $('#media-empty'),
  viewer: $('#viewer'),
  viewerTitle: $('#viewer-title'),
  viewerVideo: $('#viewer-video'),
  viewerImage: $('#viewer-image'),
  saveOne: $('#btn-save-one'),
  deleteButton: $('#btn-delete'),
};

let clips = [];
let selectedDay = store.dayKey(Date.now());
let exported = null; // { key, item } 書き出し済みの VLOG
let exporting = false;
let viewing = null; // { type: 'clip' | 'media', item }
let objectURL = null;
let onCloseCallback = null;

export function initLibrary({ onClose }) {
  onCloseCallback = onClose;
  $('#btn-library').addEventListener('click', open);
  els.sheet.querySelector('[data-close]').addEventListener('click', close);
  els.viewer.querySelector('[data-close]').addEventListener('click', closeViewer);

  els.sheet.querySelectorAll('.tabs button').forEach((b) => {
    b.addEventListener('click', () => selectTab(b.dataset.tab));
  });

  els.daySelect.addEventListener('change', () => {
    selectedDay = els.daySelect.value;
    renderClips();
  });

  els.saveDay.addEventListener('click', onSaveDay);
  els.saveOne.addEventListener('click', onSaveOne);
  els.deleteButton.addEventListener('click', onDelete);
}

async function open() {
  selectedDay = store.dayKey(Date.now());
  exported = null;
  els.sheet.classList.remove('hidden');
  selectTab('vlog');
  await refresh();
}

function close() {
  els.sheet.classList.add('hidden');
  els.clipGrid.innerHTML = '';
  els.mediaGrid.innerHTML = '';
  if (onCloseCallback) onCloseCallback();
}

function selectTab(tab) {
  els.sheet.querySelectorAll('.tabs button').forEach((b) => b.classList.toggle('selected', b.dataset.tab === tab));
  $('#tab-vlog').classList.toggle('hidden', tab !== 'vlog');
  $('#tab-media').classList.toggle('hidden', tab !== 'media');
  if (tab === 'media') renderMedia();
}

async function refresh() {
  clips = await store.allClips();
  renderDayOptions();
  renderClips();
}

// ---------------------------------------------------------------- VLOG

function renderDayOptions() {
  const today = store.dayKey(Date.now());
  const days = [...new Set([today, ...clips.map((c) => store.dayKey(c.recordedAt))])].sort().reverse();
  els.daySelect.innerHTML = '';
  for (const key of days) {
    const count = clips.filter((c) => store.dayKey(c.recordedAt) === key).length;
    const option = document.createElement('option');
    option.value = key;
    option.textContent = `${key === today ? '今日 ' : ''}${store.dayTitle(key)}（${count}本）`;
    els.daySelect.appendChild(option);
  }
  if (!days.includes(selectedDay)) selectedDay = today;
  els.daySelect.value = selectedDay;
}

function clipsOfSelectedDay() {
  return clips.filter((c) => store.dayKey(c.recordedAt) === selectedDay);
}

function renderClips() {
  const list = clipsOfSelectedDay();
  els.clipGrid.innerHTML = '';
  for (const clip of list) {
    const cell = document.createElement('button');
    cell.className = 'cell';
    if (clip.thumb) cell.style.backgroundImage = `url(${clip.thumb})`;
    if (clip.filter && clip.filter !== 'NORMAL') {
      const tag = document.createElement('span');
      tag.className = 'tag';
      tag.textContent = clip.filter;
      cell.appendChild(tag);
    }
    cell.addEventListener('click', () => openViewer({ type: 'clip', item: clip }));
    els.clipGrid.appendChild(cell);
  }
  els.clipEmpty.classList.toggle('hidden', list.length > 0);
  updateSaveDayButton();
}

function exportKey() {
  return clipsOfSelectedDay().map((c) => c.id).join(',');
}

function updateSaveDayButton() {
  const list = clipsOfSelectedDay();
  const isToday = selectedDay === store.dayKey(Date.now());
  const base = isToday ? '今日のVLOGを保存' : 'この日のVLOGを保存';
  if (exporting) return;
  if (exported && exported.key === exportKey()) {
    els.saveDay.textContent = '写真アプリに保存';
  } else {
    els.saveDay.textContent = list.length ? `${base}（${list.length}本）` : base;
  }
  els.saveDay.disabled = list.length === 0;
}

/**
 * 1回目のタップ：撮影順に連結（合計の長さぶん時間がかかる）
 * 2回目のタップ：iPhone の共有メニューを開いて写真アプリに保存
 * （ブラウザの決まりで、共有メニューはタップした直後にしか開けないため2段階）
 */
async function onSaveDay() {
  if (exporting) return;
  const key = exportKey();
  if (exported && exported.key === key) {
    await shareToPhotos([exported.item]);
    return;
  }

  const list = clipsOfSelectedDay();
  if (!list.length) return;
  exporting = true;
  els.saveDay.disabled = true;
  els.saveDay.textContent = `つないでいます… 0/${list.length}`;
  try {
    const blob = await concatenate(list.map((c) => c.blob), {
      width: 1920,
      height: 1080,
      onProgress: (done, total) => {
        els.saveDay.textContent = `つないでいます… ${done}/${total}`;
      },
    });
    const name = `VLOG-${selectedDay.replaceAll('-', '')}.${extensionFor(blob.type)}`;
    exported = { key, item: { blob, name, mime: blob.type } };
    toast('できました。「写真アプリに保存」を押してください');
  } catch (e) {
    console.error(e);
    toast('VLOGの書き出しに失敗しました');
  } finally {
    exporting = false;
    updateSaveDayButton();
  }
}

// ---------------------------------------------------------------- VIDEO / PHOTO

async function renderMedia() {
  const items = await store.allMedia();
  els.mediaGrid.innerHTML = '';
  for (const item of items) {
    const cell = document.createElement('button');
    cell.className = 'cell';
    if (item.thumb) cell.style.backgroundImage = `url(${item.thumb})`;
    cell.style.backgroundSize = 'contain';
    const tag = document.createElement('span');
    tag.className = 'tag';
    const ratio = item.name.includes('16x9') ? '16:9' : '9:16';
    tag.textContent = item.kind === 'photo' ? `PHOTO ${ratio}` : ratio;
    cell.appendChild(tag);
    cell.addEventListener('click', () => openViewer({ type: 'media', item }));
    els.mediaGrid.appendChild(cell);
  }
  els.mediaEmpty.classList.toggle('hidden', items.length > 0);
}

// ---------------------------------------------------------------- 再生画面

function openViewer(target) {
  viewing = target;
  const { item } = target;
  if (objectURL) URL.revokeObjectURL(objectURL);
  objectURL = URL.createObjectURL(item.blob);

  const isPhoto = target.type === 'media' && item.kind === 'photo';
  els.viewerVideo.classList.toggle('hidden', isPhoto);
  els.viewerImage.classList.toggle('hidden', !isPhoto);
  if (isPhoto) {
    els.viewerImage.src = objectURL;
  } else {
    els.viewerVideo.src = objectURL;
    els.viewerVideo.play().catch(() => {});
  }

  const time = target.type === 'clip' ? item.recordedAt : item.createdAt;
  els.viewerTitle.textContent = `${store.dayTitle(store.dayKey(time))} ${store.hourLabel(time)}`;
  els.saveOne.textContent = isPhoto ? 'この写真を保存' : 'この動画を保存';
  els.viewer.classList.remove('hidden');
}

function closeViewer() {
  els.viewerVideo.pause();
  els.viewerVideo.removeAttribute('src');
  els.viewerVideo.load();
  els.viewerImage.removeAttribute('src');
  if (objectURL) URL.revokeObjectURL(objectURL);
  objectURL = null;
  viewing = null;
  els.viewer.classList.add('hidden');
}

async function onSaveOne() {
  if (!viewing) return;
  const { type, item } = viewing;
  const name = type === 'clip'
    ? `VLOG-${store.dayKey(item.recordedAt).replaceAll('-', '')}-${item.id}.${extensionFor(item.blob.type)}`
    : item.name;
  await shareToPhotos([{ blob: item.blob, name, mime: item.blob.type }]);
}

async function onDelete() {
  if (!viewing) return;
  const { type, item } = viewing;
  closeViewer();
  if (type === 'clip') {
    await store.deleteClip(item.id);
    exported = null;
    await refresh();
  } else {
    await store.deleteMedia(item.id);
    await renderMedia();
  }
  toast('削除しました');
}
