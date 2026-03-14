# ios_recorder — Theos Tweak

## プロジェクト概要
- Theos ベースの iOS Tweak（rootless）
- 現状のユースケース: プロセカ（com.sega.pjsekai）のゲーム画面撮影

## ビルド & デプロイ
| コマンド | 説明 |
|---|---|
| `make` | ビルド |
| `make package` | .deb パッケージ作成 |
| `make package install` | ビルド → パッケージ → `THEOS_DEVICE_IP` へインストール |

- デプロイ時に respring は不要、ただしアプリの再起動は必要
- 実行バイナリ名は `ProductName`（プロセス kill 時は `ProductName` で grep）

## デバイス接続
- `ssh ipad` で実機に接続（IP: 192.168.1.145）
- Frida がインストール済み → 動的解析可能

## よく使うコマンド
```bash
# プロセカ起動
ssh ipad "/var/jb/usr/bin/uiopen --bundleid com.sega.pjsekai" 2>&1

# 120fps → 60fps 変換（YouTube向け、VideoToolbox HW エンコード）
ffmpeg -i input.mp4 -vf fps=60 -c:v hevc_videotoolbox -q:v 65 -tag:v hvc1 -c:a aac -b:a 192k output_60fps.mp4
```
