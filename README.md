# VlogCam

旅行・イベント・日常で、短い動画や写真を簡単に撮影し、時間情報付きの VLOG として残す iPhone 用カメラアプリ。

## Web アプリ版（`web/`）

iPhone の Safari で開くだけで使えるブラウザ版。Mac・パソコン不要。

- 開き方：Safari で公開 URL を開く → 共有ボタン →「ホーム画面に追加」→ ホーム画面のアイコンから起動
  （ホーム画面から起動すると、撮った動画がブラウザに消されにくくなります）
- 保存：「写真アプリに保存」を押すと共有メニューが開くので「ビデオを保存」/「画像を保存」
- Web 版の撮影形式
  - VLOG：横 16:9（1920x1080）
  - VIDEO / PHOTO：9:16 と 16:9 を同時に表示し、1回で縦・横の2本（2枚）を保存
  - VIDEO 録画中は右下の白いボタンで写真も撮れる（録画は止まらない。VIDEO と同じく時刻は入らない）
- ネイティブ版との違い
  - 2秒は「約2秒」（ブラウザの録画機能の都合で ±0.2秒程度ずれることがあります）
  - VLOG の連結は、MP4 のクリップを再生せずにそのままつなぐ（`web/js/remux.js`、mp4box.js + mp4-muxer を `web/vendor/` に同梱）。形式が揃わない場合のみ、再生しながら録画し直す方式に切り替わる
  - 連結後・撮影後の保存は、ボタンをもう一度押して共有メニューから行います（ブラウザの制限）
  - ズームはデジタルズーム、ライトは iPhone の Safari では使えません
  - 16:9 は縦の映像の中央を切り抜くため画質が下がります
- 更新：素材一覧の右上「更新」で最新版を読み込み直す（撮った動画・写真は消えない）。版数は `web/js/app.js` の `APP_VERSION`
- 公開：GitHub Pages（Deploy from a branch / root）→ `https://enixiasjpn-cpu.github.io/my_first_app/web/`

## iPhone へのインストール（Mac なし・Windows + 無料 Apple ID）

1. GitHub の **Actions** タブ → 最新の「Build」→ 下部 **Artifacts** の `VlogCam-ipa` をダウンロードして解凍（`VlogCam.ipa`）
2. Windows に [Sideloadly](https://sideloadly.io/) と、Apple 公式サイト版の iTunes / iCloud をインストール
3. iPhone を USB でつなぎ、Sideloadly に `VlogCam.ipa` をドラッグ → Apple ID を入力 → **Start**
4. iPhone で「設定 > プライバシーとセキュリティ > デベロッパモード」をオン（再起動あり）
5. 「設定 > 一般 > VPNとデバイス管理」で自分の Apple ID を信頼

無料 Apple ID では **7日ごとに入れ直し** が必要です（同じ手順で上書きインストール。アプリ内の動画は残ります）。

## Mac がある場合

`VlogCam.xcodeproj` を Xcode 16 以降で開き、Signing & Capabilities の Team に Apple ID を設定して実行（iOS 17 以降）。

## 技術構成

| 項目 | 実装 |
| --- | --- |
| UI | SwiftUI（縦画面固定） |
| カメラ | AVFoundation `AVCaptureSession`（1080p / 30fps） |
| 映像処理 | Core Image（Metal） |
| 録画 | `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput` → `AVAssetWriter`（H.264 / AAC, .mov） |
| VIDEO 同時録画 | 1フレームから 9:16 / 16:9 の2出力を作り、2つの `AVAssetWriter` に同時書き込み |
| 写真 | `AVCapturePhotoOutput` → 同じ Core Image 処理 → JPEG |
| 連結 | `AVMutableComposition` + `AVAssetExportSession`（Passthrough = 再エンコードなし） |
| 写真アプリ保存 | PhotoKit（追加のみの権限） |

### 時刻の焼き付け方式

カメラの全フレームを次の順で加工し、**加工後のフレームをそのまま動画ファイルに書き込みます**。

```
カメラ映像 → 回転 → 切り抜き(9:16 / 16:9 / 3:4) → フィルター → 時刻文字の合成
                                                         ├→ プレビュー表示
                                                         └→ AVAssetWriter（ファイル）
```

- 画面のプレビューも同じ加工結果を表示しているため、「画面では見えるが保存ファイルには無い」状態が構造的に起きません
- 時刻は録画開始時の「時」で固定（12:03〜12:59 開始 → `12:00`）。2 秒の途中で時が変わっても変化しません
- VLOG 連結時は時刻入りのクリップをそのままつなぐので、各クリップの時刻が残ります

### ファイル構成

```
VlogCam/
├── App/          アプリ本体・撮影画面の状態 (CameraModel)
├── Camera/       カメラ制御 (CameraService)・録画 (MovieRecorder)・写真・プレビュー・端末の向き
├── Rendering/    フレーム加工 (FrameRenderer)・フィルター (Filters)・時刻文字 (TimeOverlay)
├── Library/      VLOG クリップの保存・日付管理 (ClipStore)・サムネイル
├── Export/       VLOG 連結 (VlogComposer)・写真アプリ保存
└── UI/           撮影画面・素材一覧・再生画面
```

### フィルターの追加方法

`Rendering/Filters.swift` で `CaptureFilter` に準拠した型を作り、`FilterKind` に case を追加するだけです。
上部のフィルターボタンは `FilterKind.allCases` を順番に切り替えます。

## 動作確認チェックリスト（STEP 順）

| STEP | 確認内容 |
| --- | --- |
| 1 カメラ | 起動するとプレビューが表示される。カメラ切替・ピンチでズーム・グリッド・フラッシュが動く |
| 2 VLOG 2秒 | VLOG でシャッターを1回タップ → リングが2秒で一周して自動停止。連続して何本でも撮れる |
| 3 時刻焼き付け | 一覧のクリップを「この動画を保存」→ 写真アプリで再生し、中央に `HH:00` が入っている |
| 4 NORMAL / RETRO | 上部の NORMAL/RETRO で切替。クリップごとに違うフィルターで撮れる（一覧に RETRO バッジ） |
| 5 素材一覧 | 左下のサムネイル → 今日のクリップが撮影順に並ぶ。タップで再生、長押し/ゴミ箱で削除 |
| 6 連結 | 「今日のVLOGを保存」→ 写真アプリに1本の動画として保存。各クリップの時刻が残っている |
| 7 PHOTO | 写真が写真アプリに保存される。「時刻 ON/OFF」で時刻の有無が切り替わる。横持ちで横写真になる |
| 8 VIDEO | 上に 9:16、下に 16:9 のプレビューが同時に出る。録画開始・停止 → 縦・横の2本が写真アプリに保存される |

## 仕様の解釈（要確認事項）

- **VIDEO モードの時刻**：仕様に記載がないため焼き付けていません（プレビューにも表示しません）
- **VIDEO / PHOTO の保存先**：通常のカメラと同様、撮影後すぐ写真アプリに保存します（アプリ内一覧は VLOG 専用）
- **VIDEO（9:16 + 16:9 同時録画）**：縦持ちのカメラ映像から、9:16（全体）と 16:9（中央を横長に切り抜き）の2本を同時に書き出します。切り抜いても 1920x1080 の画質を保つため、VIDEO モードのみ 4K で取り込みます（非対応端末は 1080p）。iPhone は縦持ちで撮る前提です
- **PHOTO の縦横**：端末の向きで自動判定（縦 3:4 / 横 4:3）
- **過去の日の VLOG**：一覧右上のカレンダーから過去の日を開けます。その場合ボタン名は「この日のVLOGを保存」
- **フラッシュ**：PHOTO は撮影時に発光、VLOG / VIDEO は録画中だけライト点灯
- **インカメラ**：プレビューどおり鏡像のまま保存します
- **削除**：確認ダイアログは出しません（長押しメニュー / 再生画面のゴミ箱メニューから削除）
