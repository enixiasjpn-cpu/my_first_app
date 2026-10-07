// 撮影データの保存（IndexedDB）
// clips: VLOG の2秒クリップ { id, recordedAt, filter, blob, mime, thumb }
// media: VIDEO / PHOTO で撮ったもの { id, kind, createdAt, blob, mime, name, thumb }

const DB_NAME = 'vlogcam';
const DB_VERSION = 1;

let dbPromise = null;

function openDB() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains('clips')) db.createObjectStore('clips', { keyPath: 'id' });
      if (!db.objectStoreNames.contains('media')) db.createObjectStore('media', { keyPath: 'id' });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return dbPromise;
}

async function tx(storeName, mode, fn) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(storeName, mode);
    const store = transaction.objectStore(storeName);
    const result = fn(store);
    transaction.oncomplete = () => resolve(result && 'result' in result ? result.result : undefined);
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

export function newId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

// --- clips ---

export function putClip(clip) {
  return tx('clips', 'readwrite', (s) => s.put(clip));
}

export function deleteClip(id) {
  return tx('clips', 'readwrite', (s) => s.delete(id));
}

/** すべてのクリップ（撮影順） */
export async function allClips() {
  const clips = (await tx('clips', 'readonly', (s) => s.getAll())) || [];
  return clips.sort((a, b) => a.recordedAt - b.recordedAt);
}

// --- media (VIDEO / PHOTO) ---

export function putMedia(item) {
  return tx('media', 'readwrite', (s) => s.put(item));
}

export function deleteMedia(id) {
  return tx('media', 'readwrite', (s) => s.delete(id));
}

/** すべての写真・動画（新しい順） */
export async function allMedia() {
  const items = (await tx('media', 'readonly', (s) => s.getAll())) || [];
  return items.sort((a, b) => b.createdAt - a.createdAt);
}

/** ブラウザに勝手に消されないよう永続化をお願いする */
export async function requestPersistence() {
  try {
    if (navigator.storage && navigator.storage.persist) await navigator.storage.persist();
  } catch (_) {
    // 非対応なら何もしない
  }
}

// --- 日付 ---

export function dayKey(time) {
  const d = new Date(time);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function isToday(time) {
  return dayKey(time) === dayKey(Date.now());
}

/** 撮影時刻を「HH:00」に（12:03 → 12:00、13:01 → 13:00） */
export function hourLabel(time) {
  return `${String(new Date(time).getHours()).padStart(2, '0')}:00`;
}

export function dayTitle(key) {
  const [, m, d] = key.split('-').map(Number);
  return `${m}月${d}日`;
}
