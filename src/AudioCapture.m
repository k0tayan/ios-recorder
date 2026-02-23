#import "AudioCapture.h"
#import "RecorderLog.h"
#import <dlfcn.h>
#import <substrate.h>
#include <stdatomic.h>
#include <mach/mach_time.h>

DEFINE_RECLOG(reclog, "iosrecorder_audio.log")

// ─── ロックフリー SPSC リングバッファ (RT スレッド → drain スレッド) ──
#define RING_SLOT_COUNT   256
#define SLOT_MAX_BYTES    32768          // 2048 frames × 4 ch × sizeof(Float32)
#define SLOT_MAX_BUFS     2

typedef struct {
    uint8_t  data[SLOT_MAX_BYTES];
    UInt32   bufByteSize[SLOT_MAX_BUFS];
    UInt32   bufChannels[SLOT_MAX_BUFS];
    UInt32   numBuffers;
    UInt32   numFrames;
    uint64_t hostTime;
    uint64_t captureTime;            // コールバック呼び出し時の mach_absolute_time()
    UInt32   formatGen;              // フォーマット世代タグ (再構成を検出)
} CaptureSlot;

static CaptureSlot  sSlots[RING_SLOT_COUNT];
static atomic_int   sWriteIdx;           // RT が書き込み、drain が消費
static atomic_int   sReadIdx;            // drain が進め、RT が空き確認

// ObjC メッセージなしで RT スレッドから読めるフラグ
static atomic_bool  sCapturing;
static CMTime       sRecStartTime;
static atomic_bool  sRecStartTimeSet;
static atomic_uint  sFormatGeneration;   // AudioUnit 再構成ごとにインクリメント

// AudioUnit 別の元コールバック保持 (複数フック対応)
#define MAX_HOOKED_UNITS 8

typedef struct {
    AURenderCallback origCallback;
    void            *origRefCon;
    AudioUnit        unit;
} HookedUnitInfo;

static HookedUnitInfo sHookedUnits[MAX_HOOKED_UNITS];
static int              sHookedUnitCount = 0;
static _Atomic(AudioUnit) sCapturedUnit = NULL;   // この unit からのみ音声をキャプチャ
static atomic_uint_fast64_t sCallbackCount;        // レンダーコールバック総呼び出し回数
static atomic_uint_fast64_t sCapturedCount;        // フィルタを通過したコールバック数
static atomic_uint_fast64_t sCapturedFrames;       // キャプチャした音声フレーム総数
static atomic_uint_fast64_t sSkippedNullCbCount;   // origCallback が NULL でスキップした回数
static atomic_uint_fast64_t sRingDropCount;        // リングバッファ満杯でドロップしたコールバック数
static atomic_uint_fast64_t sRingDropFrames;       // リングバッファ溢れで失われた音声フレーム数

// ─── RT セーフなレンダーコールバックラッパー ─────────────────────
//
// 保証: ObjC メッセージ送信なし、malloc/free なし、dispatch なし、
//       ロックなし — memcpy + atomic load/store のみ。

static OSStatus renderCallbackWrapper(void *inRefCon,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    HookedUnitInfo *info = (HookedUnitInfo *)inRefCon;

    // 1. この AudioUnit の元のレンダーコールバックを呼ぶ
    OSStatus status = noErr;
    if (info && info->origCallback) {
        status = info->origCallback(info->origRefCon, ioActionFlags, inTimeStamp,
                                     inBusNumber, inNumberFrames, ioData);
    } else {
        // 元コールバックが NULL (FMOD 再構成中)。
        // スピーカー出力用に無音で埋めるが、キャプチャはしない —
        // バッファに不定値が入っており、エンコードすると以降の音声 PTS がずれる。
        if (ioData) {
            for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
        }
        if (atomic_load_explicit(&sCapturing, memory_order_relaxed)) {
            atomic_fetch_add_explicit(&sSkippedNullCbCount, 1, memory_order_relaxed);
        }
        return noErr;
    }

    // 2. 指定 unit からのみキャプチャ (他はスキップ)
    AudioUnit captureUnit = atomic_load_explicit(&sCapturedUnit, memory_order_acquire);
    if (!info || info->unit != captureUnit) return status;

    // 3. キャプチャ中でない or エラーなら早期リターン
    if (!atomic_load_explicit(&sCapturing, memory_order_acquire)) return status;
    if (status != noErr || !ioData) return status;

    // 4. リングバッファの空き確認 (単一プロデューサーなので CAS 不要)
    int wi   = atomic_load_explicit(&sWriteIdx, memory_order_relaxed);
    int next = (wi + 1) % RING_SLOT_COUNT;
    if (next == atomic_load_explicit(&sReadIdx, memory_order_acquire)) {
        // リング満杯 — このコールバックをドロップしてロスを記録
        atomic_fetch_add_explicit(&sRingDropCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&sRingDropFrames, inNumberFrames, memory_order_relaxed);
        return status;
    }

    // 5. 統計 (relaxed — 診断用のみ、ドロップ判定後にカウント)
    atomic_fetch_add_explicit(&sCallbackCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sCapturedCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sCapturedFrames, inNumberFrames, memory_order_relaxed);

    // 6. 各 AudioBuffer をスロットにコピー
    CaptureSlot *slot = &sSlots[wi];
    UInt32 numBufs = ioData->mNumberBuffers;
    if (numBufs > SLOT_MAX_BUFS) numBufs = SLOT_MAX_BUFS;

    UInt32 off = 0;
    for (UInt32 i = 0; i < numBufs; i++) {
        UInt32 sz = ioData->mBuffers[i].mDataByteSize;
        if (off + sz > SLOT_MAX_BYTES) { numBufs = i; break; }
        memcpy(slot->data + off, ioData->mBuffers[i].mData, sz);
        slot->bufByteSize[i] = sz;
        slot->bufChannels[i] = ioData->mBuffers[i].mNumberChannels;
        off += sz;
    }
    slot->numBuffers  = numBufs;
    slot->numFrames   = inNumberFrames;
    slot->hostTime    = inTimeStamp->mHostTime;
    slot->captureTime = mach_absolute_time();
    slot->formatGen   = atomic_load_explicit(&sFormatGeneration, memory_order_relaxed);

    // 7. release-store: インデックス更新前にスロット内容が可視になる
    atomic_store_explicit(&sWriteIdx, next, memory_order_release);

    return status;
}

// ─── AudioUnitSetProperty フック ─────────────────────────────────
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                              AudioUnitScope, AudioUnitElement,
                                              const void *, UInt32);

static OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit,
                                             AudioUnitPropertyID inID,
                                             AudioUnitScope inScope,
                                             AudioUnitElement inElement,
                                             const void *inData,
                                             UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_SetRenderCallback &&
        inScope == kAudioUnitScope_Input) {
        const AURenderCallbackStruct *cs = (const AURenderCallbackStruct *)inData;
        if (cs) {
            // unit ごとの info スロットを検索 or 新規作成
            HookedUnitInfo *info = NULL;
            for (int i = 0; i < sHookedUnitCount; i++) {
                if (sHookedUnits[i].unit == inUnit) {
                    info = &sHookedUnits[i];
                    break;
                }
            }
            if (!info && sHookedUnitCount < MAX_HOOKED_UNITS) {
                info = &sHookedUnits[sHookedUnitCount++];
                info->unit = inUnit;
            }
            if (!info) {
                NSLog(@"[Recorder] Too many AudioUnits hooked, skipping unit=%p", inUnit);
                return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                                  inData, inDataSize);
            }

            info->origCallback = cs->inputProc;
            info->origRefCon   = cs->inputProcRefCon;
            // release: origCallback/origRefCon の書き込みが RT スレッドの acquire 読み取りより前に可視になる
            atomic_store_explicit(&sCapturedUnit, inUnit, memory_order_release);

            // フォーマットを読み取る (ゲームスレッドなので安全、RT ではない)
            AudioStreamBasicDescription asbd = {0};
            UInt32 asbdSize = sizeof(asbd);
            OSStatus fmtSt = AudioUnitGetProperty(inUnit,
                kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                inElement, &asbd, &asbdSize);
            if (fmtSt != noErr) {
                AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output, 0, &asbd, &asbdSize);
            }
            NSLog(@"[Recorder] Intercepted AudioUnit callback (unit=%p elem=%u) fmt=%.0fHz/%uch [%d units hooked]",
                  inUnit, (unsigned)inElement, asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                  sHookedUnitCount);
            bool capturing = atomic_load_explicit(&sCapturing, memory_order_relaxed);
            reclog("HOOK unit=%p elem=%u fmt=%.0fHz/%uch cb=%p hooked=%d captureUnit=%p%s",
                   inUnit, (unsigned)inElement, asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                   cs->inputProc, sHookedUnitCount, (void *)atomic_load_explicit(&sCapturedUnit, memory_order_relaxed),
                   capturing ? " [DURING_CAPTURE]" : "");

            // フォーマット世代をインクリメント — レンダーコールバックが新スロットにタグ付けする
            atomic_fetch_add_explicit(&sFormatGeneration, 1, memory_order_release);

            AURenderCallbackStruct wrapper = {
                .inputProc       = renderCallbackWrapper,
                .inputProcRefCon = info,   // unit ごとの info をラッパーに渡す
            };
            return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                              &wrapper, sizeof(wrapper));
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                      inData, inDataSize);
}

// ─── AudioCapture 実装 ──────────────────────────────────────────
@interface AudioCapture ()
@property (nonatomic, readwrite) Float64 sampleRate;
@property (nonatomic, readwrite) UInt32  channels;
@property (nonatomic) dispatch_source_t  drainTimer;
@property (nonatomic) dispatch_queue_t   drainQueue;
@property (nonatomic) UInt32 currentFormatGen;  // 最後に処理したフォーマット世代
@property (nonatomic) uint64_t drainSlotCount;   // ドレインしたスロット総数 (定期ログ用)
@property (nonatomic) uint64_t drainFrameCount;  // ドレインしたフレーム総数
@end

@implementation AudioCapture

+ (instancetype)shared {
    static AudioCapture *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sampleRate = 48000.0;
        _channels   = 2;
        _capturing  = NO;
    }
    return self;
}

- (BOOL)installHook {
    NSLog(@"[Recorder] Installing AudioUnit hooks...");
    void *handle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                          RTLD_LAZY);
    if (!handle) {
        NSLog(@"[Recorder] Failed to open AudioToolbox");
        return NO;
    }

    void *sym = dlsym(handle, "AudioUnitSetProperty");
    if (!sym) {
        NSLog(@"[Recorder] Failed to find AudioUnitSetProperty");
        return NO;
    }

    MSHookFunction(sym,
                   (void *)hooked_AudioUnitSetProperty,
                   (void **)&orig_AudioUnitSetProperty);
    NSLog(@"[Recorder] AudioUnitSetProperty hooked successfully");
    return YES;
}

#pragma mark - キャプチャ状態

- (void)setCapturing:(BOOL)capturing {
    if (capturing == _capturing) return;
    _capturing = capturing;

    if (capturing) {
        // キャプチャ有効化前にリングバッファをリセット
        // 注意: sRecStartTimeSet はここではリセットしない — RecorderCore が
        // キャプチャ有効化の前に録画開始時刻をセットすることで、開始時刻が
        // セットされる前にスロットが到着するレースを回避している (PTS=0 になる問題)。
        atomic_store_explicit(&sWriteIdx, 0, memory_order_relaxed);
        atomic_store_explicit(&sReadIdx,  0, memory_order_relaxed);
        atomic_store_explicit(&sCallbackCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sCapturedCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sCapturedFrames, 0, memory_order_relaxed);
        atomic_store_explicit(&sSkippedNullCbCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sRingDropCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sRingDropFrames, 0, memory_order_relaxed);
        self.drainSlotCount = 0;
        self.drainFrameCount = 0;
        // 最初のスロットでフォーマット再検出を強制 (ありえない値にセット)
        self.currentFormatGen = UINT32_MAX;
        reclog("START capturing=YES captureUnit=%p hookedUnits=%d sampleRate=%.0f ch=%u",
               (void *)atomic_load_explicit(&sCapturedUnit, memory_order_relaxed),
               sHookedUnitCount, self.sampleRate, (unsigned)self.channels);
        [self _startDrainTimer];
        atomic_store_explicit(&sCapturing, true, memory_order_release);
    } else {
        atomic_store_explicit(&sCapturing, false, memory_order_release);
        [self _stopDrainTimer];   // 残りのスロットをフラッシュ
        uint64_t dropCount  = atomic_load(&sRingDropCount);
        uint64_t dropFrames = atomic_load(&sRingDropFrames);
        reclog("STOP callbacks=%llu captured=%llu frames=%llu skippedNull=%llu ringDrops=%llu droppedFrames=%llu",
               (unsigned long long)atomic_load(&sCallbackCount),
               (unsigned long long)atomic_load(&sCapturedCount),
               (unsigned long long)atomic_load(&sCapturedFrames),
               (unsigned long long)atomic_load(&sSkippedNullCbCount),
               (unsigned long long)dropCount,
               (unsigned long long)dropFrames);
        if (dropCount > 0) {
            NSLog(@"[Recorder] WARNING: %llu audio callbacks dropped (%llu frames lost) due to ring buffer overflow",
                  (unsigned long long)dropCount, (unsigned long long)dropFrames);
        }
    }
}

- (void)setRecordingStartTime:(CMTime)startTime {
    sRecStartTime = startTime;
    atomic_store_explicit(&sRecStartTimeSet, true, memory_order_release);
}

- (void)updateAudioFormat {
    AudioUnit unit = atomic_load_explicit(&sCapturedUnit, memory_order_relaxed);
    if (unit) {
        AudioStreamBasicDescription asbd;
        UInt32 size = sizeof(asbd);
        // まず Input スコープ (レンダーコールバックのフォーマット) を読み、失敗なら Output にフォールバック
        OSStatus st = AudioUnitGetProperty(unit,
                                            kAudioUnitProperty_StreamFormat,
                                            kAudioUnitScope_Input,
                                            0, &asbd, &size);
        if (st != noErr) {
            st = AudioUnitGetProperty(unit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output,
                                       0, &asbd, &size);
        }
        if (st == noErr) {
            self.sampleRate = asbd.mSampleRate;
            self.channels   = asbd.mChannelsPerFrame;
            NSLog(@"[Recorder] Audio format: %.0f Hz, %u channels",
                  self.sampleRate, (unsigned int)self.channels);
        }
    }
}

#pragma mark - Drain タイマー

- (void)_startDrainTimer {
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    self.drainQueue = dispatch_queue_create(
        "com.local.iosrecorder.audiodrain", attr);

    self.drainTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.drainQueue);
    dispatch_source_set_timer(self.drainTimer,
                              DISPATCH_TIME_NOW,
                              2 * NSEC_PER_MSEC,   // 2ms 間隔
                              0);                    // leeway なし

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.drainTimer, ^{
        [weakSelf _drainRingBuffer];
    });
    dispatch_resume(self.drainTimer);
}

- (void)_stopDrainTimer {
    if (self.drainTimer) {
        dispatch_source_cancel(self.drainTimer);
        self.drainTimer = nil;
    }
    if (self.drainQueue) {
        // 実行中のハンドラ完了を待ち、残りのスロットをフラッシュ
        dispatch_sync(self.drainQueue, ^{
            [self _drainRingBuffer];
        });
        self.drainQueue = nil;
    }
}

- (void)_drainRingBuffer {
    int ri = atomic_load_explicit(&sReadIdx, memory_order_relaxed);
    int wi = atomic_load_explicit(&sWriteIdx, memory_order_acquire);

    while (ri != wi) {
        CaptureSlot *slot = &sSlots[ri];

        // スロットごとのフォーマット世代チェック — 新フォーマットのデータ処理前に再構成
        if (slot->formatGen != self.currentFormatGen) {
            Float64 oldRate = self.sampleRate;
            UInt32  oldCh   = self.channels;
            [self updateAudioFormat];
            reclog("FORMATGEN slot#%llu gen %u→%u fmt %.0fHz/%uch→%.0fHz/%uch",
                   (unsigned long long)self.drainSlotCount,
                   (unsigned)self.currentFormatGen, (unsigned)slot->formatGen,
                   oldRate, (unsigned)oldCh, self.sampleRate, (unsigned)self.channels);
            self.currentFormatGen = slot->formatGen;
            if (self.sampleRate != oldRate || self.channels != oldCh) {
                NSLog(@"[Recorder] Audio format changed at slot: %.0fHz/%uch → %.0fHz/%uch",
                      oldRate, (unsigned)oldCh, self.sampleRate, (unsigned)self.channels);
                reclog("FORMAT_CHANGED! Triggering AudioEncoder reconfigure");
                id<AudioCaptureDelegate> del = self.delegate;
                if ([del respondsToSelector:@selector(audioCaptureFormatDidChange:sampleRate:channels:)]) {
                    [del audioCaptureFormatDidChange:self
                                         sampleRate:self.sampleRate
                                           channels:self.channels];
                }
            }
        }

        // 壁時計時刻 (コールバック時の mach_absolute_time) から PTS を算出。
        // 映像タイムベースに合わせる。slot->hostTime はスピーカー再生時刻で
        // 最大 ~1s 先にあり、音声映像のずれを引き起こす。
        CMTime hostCMTime = CMClockMakeHostTimeFromSystemUnits(slot->captureTime);
        CMTime pts;
        if (atomic_load_explicit(&sRecStartTimeSet, memory_order_acquire)) {
            pts = CMTimeSubtract(hostCMTime, sRecStartTime);
        } else {
            pts = kCMTimeZero;
        }

        // スタック上に AudioBufferList を再構築 (スロットデータを指す)
        struct {
            UInt32      mNumberBuffers;
            AudioBuffer mBuffers[SLOT_MAX_BUFS];
        } stackABL;

        stackABL.mNumberBuffers = slot->numBuffers;
        UInt32 off = 0;
        for (UInt32 i = 0; i < slot->numBuffers; i++) {
            stackABL.mBuffers[i].mNumberChannels = slot->bufChannels[i];
            stackABL.mBuffers[i].mDataByteSize   = slot->bufByteSize[i];
            stackABL.mBuffers[i].mData           = slot->data + off;
            off += slot->bufByteSize[i];
        }

        // 同期配信 — デリゲートは返る前にデータを消費しなければならない
        id<AudioCaptureDelegate> del = self.delegate;
        if (del) {
            [del audioCapture:self
                didCaptureAudioBuffer:(AudioBufferList *)&stackABL
                           numFrames:slot->numFrames
                           timestamp:pts];
        }

        self.drainSlotCount++;
        self.drainFrameCount += slot->numFrames;

        // 診断: 最初の 20 スロットで hostTime と captureTime のオフセットを計測
        if (self.drainSlotCount <= 20) {
            CMTime origHostCMTime = CMClockMakeHostTimeFromSystemUnits(slot->hostTime);
            double hostSec = CMTimeGetSeconds(origHostCMTime);
            double captureSec = CMTimeGetSeconds(hostCMTime);  // hostCMTime は captureTime ベース
            double offsetSec = hostSec - captureSec;  // 正 = hostTime が未来
            reclog("SLOT#%llu hostTime=%.4f captureTime=%.4f offset=%.4fs pts=%.3f frames=%u",
                   (unsigned long long)self.drainSlotCount,
                   hostSec, captureSec, offsetSec,
                   CMTimeGetSeconds(pts), slot->numFrames);
        }
        // ~1秒分の音声ごとにログ (48000/512 ≈ 94 コールバック)
        if (self.drainSlotCount % 100 == 0) {
            CMTime origHostCMTime = CMClockMakeHostTimeFromSystemUnits(slot->hostTime);
            double hostSec = CMTimeGetSeconds(origHostCMTime);
            double captureSec = CMTimeGetSeconds(hostCMTime);
            double hostVsCapture = hostSec - captureSec;  // 正 = hostTime が未来

            reclog("DRAIN slot#%llu totalFrames=%llu pts=%.3f hostVsCapture=%.4f numFrames=%u",
                   (unsigned long long)self.drainSlotCount,
                   (unsigned long long)self.drainFrameCount,
                   CMTimeGetSeconds(pts), hostVsCapture, slot->numFrames);
        }

        // 読み取りインデックスを進める (release-store で RT プロデューサーに空きを通知)
        ri = (ri + 1) % RING_SLOT_COUNT;
        atomic_store_explicit(&sReadIdx, ri, memory_order_release);
    }
}

@end
