# コードレビュー: iOS App Recorder

レビュー日: 2026-02-23
レビュアー: iOS 音声/動画エンジニア視点

## 全体評価

アーキテクチャは非常によく設計されている。ゼロコピーの IOSurface キャプチャ、ロックフリー SPSC リングバッファ、RT セーフなオーディオコールバック、プライミング補償付き AAC エンコードなど、音声・動画の専門知識が反映されている。

---

## Critical

### 1. ~~IOSurface の寿命とエンコードのレース~~ ✅ 修正済み

- **ファイル:** `FrameCapture.m`, `FrameCapture.h`, `VideoEncoder.m`, `VideoEncoder.h`, `RecorderCore.m`
- **問題:** `CVPixelBufferCreateWithIOSurface` はゼロコピーなので、CVPixelBuffer は IOSurface のバッキングメモリを共有している。`captureDrawable:` の末尾で `CVPixelBufferRelease` した後、Metal が同じ IOSurface を次フレームの描画に再利用すると、VideoEncoder が非同期でエンコード中のピクセルデータが上書きされる可能性がある。`VideoEncoder.m:160` で `CVPixelBufferRetain` しているが、これは IOSurface のバッキングメモリの排他制御を保証しない。`ENCODER_QUEUE_DEPTH=2` で緩和しているものの、Metal の drawable プールサイズ（通常3）と競合する余地が残る。
- **修正内容:** CAMetalDrawable を `surfaceOwner` としてデリゲート経由で VideoEncoder に渡し、`VTCompressionSessionEncodeFrame` の `sourceFrameRefCon` に `__bridge_retained` で保持させる。VT の出力コールバックで `CFRelease` することで、エンコード完了まで Metal が IOSurface を再利用できないようにした。ゼロコピーを維持したまま、追加 CPU 負荷ほぼゼロで安全性を確保。
- **不採用案:**
  - `CVPixelBufferPool` + memcpy: 1920x1080 BGRA で ~8MB/frame のコピーがレンダースレッドで発生し、ゲーム動作への負荷が大きいため不採用
  - `IOSurfaceLock` / `IOSurfaceUnlock`: CPU レベルのロックであり、GPU (Metal) の書き込みを防げないため不採用

---

## High

### 2. ~~VideoEncoder: outputCount のスレッドセーフティ~~ ✅ 修正済み

- **ファイル:** `VideoEncoder.m`
- **問題:** `videoEncoderOutputCallback` は VideoToolbox の内部スレッドから呼ばれるが、`outputCount` はアトミックではなく、`encoderQueue` 上でもない。
- **修正内容:** `nonatomic` プロパティを `static _Atomic int64_t sOutputCount` に変更し、インクリメント・リセット・読み取りすべてを `stdatomic.h` の `atomic_fetch_add_explicit` / `atomic_store_explicit` / `atomic_load_explicit` で行うようにした。カウンタはログ用途のみなので `memory_order_relaxed` を使用。`encoderQueue` へのディスパッチは出力コールバックの遅延を増やすため不採用。

### 3. ~~AudioEncoder: stopWithCompletion のレース~~ ✅ 修正済み

- **ファイル:** `AudioEncoder.m`
- **問題:** `self.isRunning = NO` がメインスレッドで即座にセットされた後、まだ `encoderQueue` に `dispatch_sync` でエンキューされている `encodePCMBuffer:` が `isRunning` チェックで早期リターンし、最後のデータが失われる可能性がある。
- **修正内容:** `isRunning = NO` を `dispatch_async(encoderQueue, ...)` ブロック内に移動し、保留中の `encodePCMBuffer:` が先にデータを書き込めるようにした。加えて `encodePCMBuffer:` の `dispatch_sync` ブロック内に `isRunning` の再チェックを追加し、stop 後にキューに到達したブロックが破棄済み converter にアクセスするのを防止。

### 4. ~~sHookedUnits のメモリオーダリング不足~~ ✅ 修正済み

- **ファイル:** `AudioCapture.m`
- **問題:** `hooked_AudioUnitSetProperty` はゲームスレッドから呼ばれ、`renderCallbackWrapper` は RT スレッドから `info` を参照する。`sCapturedUnit` への書き込みにメモリオーダリングの保証がない。
- **修正内容:** `sCapturedUnit` を `_Atomic(AudioUnit)` に変更。ゲームスレッドでの書き込みを `atomic_store_explicit(..., memory_order_release)` にし、RT スレッドでの読み取りを `atomic_load_explicit(..., memory_order_acquire)` にした。release/acquire ペアにより `origCallback`/`origRefCon` の書き込みが RT スレッドに可視になることを保証。ログ用途の読み取りは `memory_order_relaxed` を使用。

---

## Medium

### 5. ~~RecorderCore: バックグラウンド通知の retain cycle~~ ✅ 修正済み

- **ファイル:** `RecorderCore.m`
- **問題:** `addObserverForName:usingBlock:` で `self` を強参照でキャプチャしている。シングルトンなので実害はないが、`removeObserver` も呼ばれていない。
- **修正内容:** ブロック内で `__weak`/`__strong` パターンを使用し、observer トークンをプロパティに保持。`dealloc` で `removeObserver:` を呼ぶようにした。

### 6. ~~AudioEncoder: 負の PTS の可能性~~ ✅ 修正済み

- **ファイル:** `AudioEncoder.m`
- **問題:** プライミング補償で最初の 2〜3 フレームの `sampleOffset` が負値になり、`AVAssetWriter` が負の PTS を拒否する可能性がある。
- **修正内容:** PTS 算出後に `CMTimeCompare(pts, kCMTimeZero) < 0` で負値を検出し、0 にクランプするようにした。

### 7. ~~VideoEncoder: 出力コールバック内の冗長な CFRetain/CFRelease~~ ✅ 修正済み

- **ファイル:** `VideoEncoder.m`
- **問題:** `sampleBuffer` を retain→callback→release しているが、callback 側（`MP4Muxer.appendVideoSample:`）でも `CFRetain` しているので冗長。
- **修正内容:** VT 出力コールバック内の `CFRetain`/`CFRelease` を削除。`sampleBuffer` はコールバック中有効であり、`MP4Muxer` 側が自身で `CFRetain` する設計のため不要。

### 8. ~~ControlServer: TCP read が部分的に返る可能性~~ ✅ 修正済み

- **ファイル:** `ControlServer.m`
- **問題:** TCP では `read` が要求バイト数より少なく返ることがある。コマンドが途中で切れる可能性。
- **修正内容:** `_handleClient:` の `read` をデリミタ (`\n`) が到着するか、バッファが満杯になるか、接続が切れるまでループするように変更。

### 9. ~~AudioEncoder: 非インターリーブ変換のパフォーマンス~~ ✅ 修正済み

- **ファイル:** `AudioEncoder.m`
- **問題:** サンプルごとに `_writeToRingBuffer` を呼んでおり、各呼び出しでリングバッファの境界チェックと modulo 演算が発生。`dispatch_sync` 内で実行されるため、drain スレッドを長時間ブロックする。
- **修正内容:** `malloc` で一時バッファを確保し、非インターリーブデータをインターリーブした後、`_writeToRingBuffer` を 1 回だけ呼ぶように変更。サンプルごとの境界チェック・modulo 演算のオーバーヘッドを排除。

---

## Low

### 10. FrameCapture: captureSize の構造体アトミシティ

- **ファイル:** `FrameCapture.m:86`
- **問題:** `CGSize` は 2 つの `CGFloat` で構成される構造体で、理論上は部分読み取りの可能性がある。arm64 専用なので実質問題ないが正式には保護すべき。
- **対策:** `@synchronized` や atomic プロパティで保護する。

### 11. RecorderCore: startRecording の部分的失敗時のクリーンアップ

- **ファイル:** `RecorderCore.m:116-135`
- **問題:** エンコーダの start が失敗した場合、前のインスタンスが中途半端な状態で残る。ARC で基本 OK だが明示的なクリーンアップが望ましい。
- **対策:** 失敗時に各プロパティを nil に戻す。

### 12. ControlServer: PULL コマンドのパストラバーサル

- **ファイル:** `ControlServer.m:233`
- **問題:** クライアントが任意のパスを指定でき、ファイル読み取り+削除が可能。
- **対策:** `NSTemporaryDirectory()` プレフィックスのバリデーションを入れる。

---

## 良い点

- **RT セーフなオーディオキャプチャ:** `renderCallbackWrapper` で ObjC メッセージ送信・malloc・ロック一切なし
- **ロックフリー SPSC リングバッファ:** memory_order の使い分け（acquire/release）が正確
- **プライミング補償:** AAC の 2112 サンプル遅延を PTS で補償し、A/V 同期に直結する重要な処理が正しい
- **ゼロコピー IOSurface:** private API の使い方が適切
- **フォーマット変更の世代管理:** FMOD のような動的にフォーマットを変えるオーディオエンジンへの対応が優秀
- **セマフォベースの非同期エンコーダ:** レンダースレッドをブロックしない設計
- **診断ログ:** ドリフト計測、hostTime vs captureTime の比較など、デバッグに必要な情報が網羅されている
