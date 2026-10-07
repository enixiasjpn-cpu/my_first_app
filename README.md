# VlogCam

旅行・イベント・日常で、短い動画や写真を簡単に撮影し、時間情報付きの VLOG として残す iPhone 用カメラアプリ。

## 必要な環境

- Mac + Xcode 16 以降
- iPhone（iOS 17 以降）※カメラを使うためシミュレーターでは動作しません

## ビルド手順

1. `VlogCam.xcodeproj` を Xcode で開く
2. ターゲット **VlogCam** → **Signing & Capabilities** で
   - **Team** に自分の Apple ID（Personal Team で可）を選択
   - 必要なら **Bundle Identifier**（初期値 `com.example.vlogcam`）を自分用に変更
3. iPhone を接続して実行先に選び、▶︎ で実行
4. 初回はカメラ・マイク、保存時に写真へのアクセスを許可

## 技術構成

| 項目 | 実装 |
| --- | --- |
| UI | SwiftUI（縦画面固定） |
| カメラ | AVFoundation `AVCaptureSession`（1080p / 30fps） |
| 映像処理 | Core Image（Metal） |
| 録画 | `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput` → `AVAssetWriter`（H.264 / AAC, .mov） |
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
| 8 VIDEO | 9:16 / 16:9 を切替えて録画開始・停止 → 写真アプリに保存される |

## 仕様の解釈（要確認事項）

- **VIDEO モードの時刻**：仕様に記載がないため焼き付けていません（プレビューにも表示しません）
- **VIDEO / PHOTO の保存先**：通常のカメラと同様、撮影後すぐ写真アプリに保存します（アプリ内一覧は VLOG 専用）
- **16:9 の撮り方**：iPhone を横に持てば全画角の横動画、縦持ちのままなら中央を横長に切り抜きます（縦持ち時は画質が下がります）
- **PHOTO の縦横**：端末の向きで自動判定（縦 3:4 / 横 4:3）
- **過去の日の VLOG**：一覧右上のカレンダーから過去の日を開けます。その場合ボタン名は「この日のVLOGを保存」
- **フラッシュ**：PHOTO は撮影時に発光、VLOG / VIDEO は録画中だけライト点灯
- **インカメラ**：プレビューどおり鏡像のまま保存します
- **削除**：確認ダイアログは出しません（長押しメニュー / 再生画面のゴミ箱メニューから削除）
