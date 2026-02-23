# iOS App Recorder

任意のアプリの画面 (Metal) と音声を MP4 に録画する Jailbreak tweak。
`CAMetalLayer` の `nextDrawable` をフックしてフレームキャプチャ、`AudioUnit` をフックして音声キャプチャを行う。

## 必要なもの

- Jailbreak 済み iOS 15.0+ (rootless, arm64)
- [Theos](https://theos.dev) ビルド環境
- デバイスへの SSH 接続 (`ssh ipad`)
- PC 側に Python 3 (操作スクリプト用)

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

対象アプリを起動すると tweak が自動ロードされ、ソケットサーバーが待機状態になる。
PC からコントロールスクリプトで操作する。

### コントロールスクリプト

```bash
python3 scripts/recorder_client.py status              # 状態確認
python3 scripts/recorder_client.py start               # 録画開始
python3 scripts/recorder_client.py stop                # 録画停止 & ファイル転送
python3 scripts/recorder_client.py stop --no-pull      # 停止のみ (転送しない)
python3 scripts/recorder_client.py set fps=30          # FPS 変更
python3 scripts/recorder_client.py set bitrate=5000000 # ビットレート変更
python3 scripts/recorder_client.py set resolution=1920x1440  # 解像度上限変更
python3 scripts/recorder_client.py cleanup             # tmp ファイル掃除
```

`-o DIR` で出力先ディレクトリを指定可能。デフォルトは `recordings/`。

スクリプトは SSH ソケットフォワーディングでアプリサンドボックス内の UNIX ソケットに接続する。

### デフォルト設定

| 項目 | デフォルト値 |
|------|-------------|
| 解像度上限 | 2060x1440 |
| FPS | 120 |
| 映像ビットレート | 16 Mbps |
| 音声ビットレート | 128 kbps |
| コーデック | H.265 (HEVC) / AAC |
| コンテナ | MP4 |

## 構成

```
src/
  Tweak.xm          フックのエントリポイント (CAMetalLayer, AudioUnit)
  FrameCapture       Metal フレームキャプチャ (IOSurface → CVPixelBuffer, zero-copy)
  AudioCapture       音声キャプチャ (AudioUnit レンダーコールバックフック, lock-free SPSC ring buffer)
  VideoEncoder       H.265 エンコード (VideoToolbox)
  AudioEncoder       AAC エンコード (AudioToolbox / AudioConverter)
  MP4Muxer           MP4 多重化 (AVAssetWriter, passthrough)
  RecorderCore       全体の制御 (開始/停止、各コンポーネントの接続)
  ControlServer      UNIX ソケットコマンドサーバー

scripts/
  recorder_client.py PC 側コントロールクライアント (SSH フォワーディング経由)
```

## 補足

- アプリがバックグラウンドに遷移すると録画は自動停止される
- 録画ファイルはアプリのサンドボックス tmp に保存後、Documents にコピーされ tmp 側は自動削除される
- `cleanup` コマンドで不要な一時ファイルを一括削除できる
