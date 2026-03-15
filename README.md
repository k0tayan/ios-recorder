# iOS App Recorder

任意のアプリの画面 (Metal) と音声を MP4 に録画、またはリアルタイムで PC にストリーミングする Jailbreak tweak。
`CAMetalLayer` の `nextDrawable` をフックしてフレームキャプチャ、`AudioUnit` をフックして音声キャプチャを行う。

## 想定ユーザー

- Jailbreak 済み iOS デバイスを持っている開発者・リバースエンジニア
- ゲーム等のアプリ画面を高品質にキャプチャしたい人
- ReplayKit では撮れない内部音声付きの録画が必要な人

Theos のビルド環境構築や SSH 接続が自力でできる程度の知識を前提としている。

## 注意事項

- **ネットワークセキュリティ:** コントロールサーバー (TCP ポート 8190) およびストリーミングサーバー (TCP ポート 8191) に認証機構はない。同一ネットワーク上の誰でも録画・ストリーミングの操作やファイル取得が可能。信頼できるネットワーク (自宅 Wi-Fi 等) でのみ使用すること。公衆 Wi-Fi での使用は推奨しない。
- **Private API の使用:** `CAMetalLayer` や `AudioUnit` のフックに Substrate を使用しているため、iOS アップデートで動作しなくなる可能性がある。
- **対象アプリへの影響:** Metal のレンダリングパイプラインにフックを挿入するため、録画中はわずかにパフォーマンスが低下する可能性がある。非録画時のオーバーヘッドは最小限。
- **本ツールの用途:** 個人利用の範囲での画面録画を想定。録画した映像の利用は各アプリの利用規約に従うこと。

## 必要なもの

- Jailbreak 済み iOS 15.0+ (rootless, arm64)
- [Theos](https://theos.dev) ビルド環境
- デバイスへの SSH 接続 (`ssh ipad`) ※ビルド・インストール時のみ
- PC とデバイスが同一ネットワーク上にあること (TCP 直接接続)
- PC 側に Python 3 (操作スクリプト用)
- PC 側に ffmpeg/ffplay (ストリーミング再生用、`apt install ffmpeg` 等)

## ビルド・インストール

```bash
make                  # ビルド
make package          # .deb をビルド
make package install  # ビルド → パッケージ → デバイスへインストール
make remove           # アンインストール
```

インストール後 respring は不要だが、対象アプリの再起動が必要。

## 対象アプリの設定

`iosrecorder.plist` で対象アプリの Bundle ID を指定する:

```plist
{ Filter = { Bundles = ( "com.sega.pjsekai" ); }; }
```

Bundle ID を変更すれば任意のアプリに適用可能。変更後は再ビルド・再インストールが必要。

## 使い方

対象アプリを起動すると tweak が自動ロードされ、TCP ポート 8190 でコマンドサーバーが待機状態になる。
PC からコントロールスクリプトで操作する (SSH 不要、TCP 直接接続)。

### 録画

```bash
python3 scripts/recorder_client.py status              # 状態確認
python3 scripts/recorder_client.py start               # 録画開始
python3 scripts/recorder_client.py stop                # 録画停止 & ファイル転送
python3 scripts/recorder_client.py stop --no-pull      # 停止のみ (転送しない)
python3 scripts/recorder_client.py list                # 録画一覧
python3 scripts/recorder_client.py set fps=30          # FPS 変更
python3 scripts/recorder_client.py set bitrate=5000000 # ビットレート変更
python3 scripts/recorder_client.py set resolution=1920x1440  # 解像度上限変更
python3 scripts/recorder_client.py cleanup             # tmp ファイル掃除
```

`-o DIR` で出力先ディレクトリを指定可能。デフォルトは `recordings/`。
`--host IP` / `--port PORT` でデバイスの接続先を変更可能。

### ライブストリーミング

ゲーム映像+音声を MPEG-TS でリアルタイム伝送し、PC の ffplay で再生する。Discord の画面共有で配信する用途を想定。

```bash
python3 scripts/stream_client.py                  # ストリーミング開始 & ffplay で再生
python3 scripts/stream_client.py --record          # ストリーミング + 録画を同時実行
python3 scripts/stream_client.py --no-play         # ストリーミングのみ (ffplay を起動しない)
python3 scripts/stream_client.py stop              # ストリーミング停止
python3 scripts/stream_client.py status            # 状態確認
```

ffplay ウィンドウを閉じるか Ctrl+C でストリーミングは自動停止される。
録画とストリーミングは独立して動作し、同時実行も可能。

### デフォルト設定

| 項目 | 録画 | ストリーミング |
|------|------|----------------|
| 解像度上限 | 1920x1080 | 1280x720 |
| FPS | 120 | 120 |
| 映像ビットレート | 24 Mbps | 6 Mbps |
| 音声ビットレート | 128 kbps | 128 kbps |
| コーデック | H.265 (HEVC) / AAC | H.265 (HEVC) / AAC |
| コンテナ | MP4 | MPEG-TS |

## 構成

```
src/
  Tweak.xm          フックのエントリポイント (CAMetalLayer, AudioUnit)
  FrameCapture       Metal フレームキャプチャ (Metal blit → CVPixelBufferPool, addPresentedHandler 駆動)
  AudioCapture       音声キャプチャ (AudioUnit レンダーコールバックフック, lock-free SPSC ring buffer)
  VideoEncoder       H.265 エンコード (VideoToolbox)
  AudioEncoder       AAC エンコード (AudioToolbox / AudioConverter)
  MP4Muxer           MP4 多重化 (AVAssetWriter, passthrough)
  TSMuxer            MPEG-TS 多重化 (HVCC→Annex-B, AAC→ADTS, PES/TS パケット化)
  StreamServer       TCP ストリーミングサーバー (ポート 8191)
  RecorderCore       全体の制御 (録画/ストリーミングのライフサイクル管理)
  ControlServer      TCP コマンドサーバー (ポート 8190)

scripts/
  recorder_client.py 録画コントロールクライアント
  stream_client.py   ストリーミングクライアント (ffplay 連携)
```

## 補足

- アプリがバックグラウンドに遷移すると録画・ストリーミングは自動停止される
- 録画ファイルはアプリのサンドボックス tmp に保存される。`stop` コマンド (PULL) で PC に転送後、デバイス側のファイルは自動削除される
- `cleanup` コマンドで不要な一時ファイルを一括削除できる
- ストリーミングサーバーは単一クライアント接続のみ対応。新しい接続があると既存の接続は切断される
