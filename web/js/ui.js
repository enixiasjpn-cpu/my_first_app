// 共通の UI 部品

const toastEl = document.querySelector('#toast');

let toastTimer = null;
export function toast(message) {
  toastEl.textContent = message;
  toastEl.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.add('hidden'), 1800);
}


/**
 * iPhone の共有メニューを開く（「ビデオを保存」「画像を保存」で写真アプリへ）。
 * ブラウザの決まりで、ボタンをタップした直後にしか呼べない。
 */
export async function shareToPhotos(items) {
  const files = items.map((it) => new File([it.blob], it.name, { type: it.mime || it.blob.type }));
  if (navigator.canShare && navigator.canShare({ files })) {
    try {
      await navigator.share({ files });
      return true;
    } catch (e) {
      if (e && e.name === 'AbortError') return false;
      console.error(e);
    }
  }
  // 共有できないブラウザではダウンロード
  for (const file of files) {
    const url = URL.createObjectURL(file);
    const a = document.createElement('a');
    a.href = url;
    a.download = file.name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
  return true;
}

