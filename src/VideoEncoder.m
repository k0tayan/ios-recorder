#import "VideoEncoder.h"
#import "RecorderLog.h"
#import <stdatomic.h>

DEFINE_RECLOG(vreclog, "iosrecorder_video.log")

// 同時エンコードの上限。Metal の drawable プールは ~3 サーフェスなので、
// VT 出力コールバック (drawable 解放時) でセマフォを signal することで、
// 保持中の drawable 数を正確にこの値以下に制限する。
// 値を 2 にすると VT 内部保持分を含め最大 2 drawable → プール枯渇しない。
// VT 出力コールバックに渡すコンテキスト。drawable (surfaceOwner) と
// 入力時の PTS を保持し、VT が書き換えた PTS を元の値に復元するために使う。
typedef struct {
    void *surfaceOwner;  // retained drawable (or NULL)
    CMTime originalPTS;
} FrameRefCon;

#define ENCODER_QUEUE_DEPTH 2

@interface VideoEncoder () {
    @public
    // レンダースレッドからインクリメント、encoderQueue から読み取りのためアトミック
    _Atomic int64_t _encodeCount;
    // VT の内部スレッドからインクリメントされるためアトミック (C 関数からアクセス)
    _Atomic int64_t _outputCount;
    _Atomic int64_t _dropCount;
}
@property (nonatomic) VTCompressionSessionRef session;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) int fps;
@property (nonatomic) int bitrate;
@property (nonatomic, readwrite) BOOL isRunning;
@property (nonatomic) dispatch_queue_t encoderQueue;
@property (nonatomic) dispatch_semaphore_t encoderSemaphore;
@end

static void videoEncoderOutputCallback(void *outputCallbackRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTEncodeInfoFlags infoFlags,
                                        CMSampleBufferRef sampleBuffer) {
    VideoEncoder *encoder = (__bridge VideoEncoder *)outputCallbackRefCon;

    // エンコード完了 — drawable (surfaceOwner) を解放して IOSurface を Metal に返し、
    // セマフォを signal して次のフレーム受付を許可する。
    FrameRefCon *refCon = (FrameRefCon *)sourceFrameRefCon;
    if (refCon) {
        if (refCon->surfaceOwner) {
            CFRelease(refCon->surfaceOwner);
        }
    }
    dispatch_semaphore_signal(encoder.encoderSemaphore);

    if (status != noErr || !sampleBuffer) {
        NSLog(@"[Recorder] Video encode error: %d", (int)status);
        free(refCon);
        return;
    }

    // VT が書き換えた PTS を入力時の値に復元した新しい CMSampleBuffer を作成。
    // CMSampleBufferSetOutputPresentationTimeStamp は VT 出力バッファに対して
    // 効果がないため、CMSampleBufferCreateCopyWithNewTiming で差し替える。
    CMSampleBufferRef outputBuffer = sampleBuffer;
    BOOL didCopy = NO;
    if (refCon) {
        CMSampleTimingInfo timing;
        timing.presentationTimeStamp = refCon->originalPTS;
        timing.duration = CMTimeMake(1, encoder.fps);
        timing.decodeTimeStamp = kCMTimeInvalid;
        CMSampleBufferRef corrected = NULL;
        OSStatus copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            kCFAllocatorDefault, sampleBuffer, 1, &timing, &corrected);
        if (copyStatus == noErr && corrected) {
            outputBuffer = corrected;
            didCopy = YES;
        }
    }

    int64_t count = atomic_fetch_add_explicit(&encoder->_outputCount, 1, memory_order_relaxed) + 1;

    // 100 フレームごとに PTS 追跡用ログ
    if (count % 100 == 1) {
        CMTime vtPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime outPts = CMSampleBufferGetPresentationTimeStamp(outputBuffer);
        vreclog("VT_OUT #%lld pts=%.3f vtPts=%.3f orig=%.3f copy=%d",
                (long long)count, CMTimeGetSeconds(outPts),
                CMTimeGetSeconds(vtPts),
                refCon ? CMTimeGetSeconds(refCon->originalPTS) : -1.0,
                didCopy);
    }

    if (encoder.onEncodedSample) {
        encoder.onEncodedSample(outputBuffer);
    }
    if (didCopy) CFRelease(outputBuffer);
    free(refCon);
}

@implementation VideoEncoder

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                          fps:(int)fps
                      bitrate:(int)bitrate {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _fps = fps;
        _bitrate = bitrate;
        _isRunning = NO;
        _encoderQueue = dispatch_queue_create("com.local.iosrecorder.videoencoder", DISPATCH_QUEUE_SERIAL);
        _encoderSemaphore = dispatch_semaphore_create(ENCODER_QUEUE_DEPTH);
    }
    return self;
}

- (BOOL)start {
    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        self.width,
        self.height,
        kCMVideoCodecType_HEVC,
        NULL,
        NULL,
        kCFAllocatorDefault,
        videoEncoderOutputCallback,
        (__bridge void *)self,
        &_session
    );

    if (status != noErr) {
        NSLog(@"[Recorder] Failed to create VTCompressionSession: %d", (int)status);
        return NO;
    }

    // セッションプロパティ設定
    OSStatus propStatus;
    propStatus = VTSessionSetProperty(self.session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    if (propStatus != noErr) {
        NSLog(@"[Recorder] WARNING: Failed to set RealTime property: %d (encoding latency may increase)", (int)propStatus);
    }
    propStatus = VTSessionSetProperty(self.session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);
    if (propStatus != noErr) {
        NSLog(@"[Recorder] WARNING: Failed to set ProfileLevel: %d", (int)propStatus);
    }

    int avgBitrate = self.bitrate;
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &avgBitrate);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // データレート制限: [バイト/秒, 期間(秒)]
    // I フレームは P フレームの数倍のサイズになるため、ハードキャップに
    // 平均の 1.5 倍のヘッドルームを持たせてキーフレーム品質を確保する。
    int bytesPerSecond = (int)(self.bitrate * 1.5) / 8;
    double limitDuration = 1.0;
    CFNumberRef bytesRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bytesPerSecond);
    CFNumberRef durationRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &limitDuration);
    CFMutableArrayRef dataRateLimits = CFArrayCreateMutable(kCFAllocatorDefault, 2, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(dataRateLimits, bytesRef);
    CFArrayAppendValue(dataRateLimits, durationRef);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_DataRateLimits, dataRateLimits);
    CFRelease(bytesRef);
    CFRelease(durationRef);
    CFRelease(dataRateLimits);

    int keyFrameInterval = self.fps * 2;
    CFNumberRef keyFrameRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keyFrameInterval);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyFrameRef);
    CFRelease(keyFrameRef);

    double keyFrameDuration = 2.0;
    CFNumberRef keyFrameDurationRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &keyFrameDuration);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyFrameDurationRef);
    CFRelease(keyFrameDurationRef);

    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    // VT 内部のフレームバッファリングを禁止し、入力順に即時出力させる。
    // これにより出力 PTS のドリフトとエンコード遅延の蓄積を防止する。
    int maxDelay = 0;
    CFNumberRef maxDelayRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxDelay);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_MaxFrameDelayCount, maxDelayRef);
    CFRelease(maxDelayRef);

    int expectedFPS = self.fps;
    CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &expectedFPS);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    status = VTCompressionSessionPrepareToEncodeFrames(self.session);
    if (status != noErr) {
        NSLog(@"[Recorder] Failed to prepare VTCompressionSession: %d", (int)status);
        VTCompressionSessionInvalidate(self.session);
        CFRelease(self.session);
        self.session = NULL;
        return NO;
    }

    self.isRunning = YES;
    atomic_store_explicit(&_encodeCount, 0, memory_order_relaxed);
    atomic_store_explicit(&_outputCount, 0, memory_order_relaxed);
    atomic_store_explicit(&_dropCount, 0, memory_order_relaxed);
    vreclog("START %dx%d @%dfps %dbps", self.width, self.height, self.fps, self.bitrate);
    NSLog(@"[Recorder] VideoEncoder started: %dx%d @ %dfps, %dbps",
          self.width, self.height, self.fps, self.bitrate);
    return YES;
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                timestamp:(CMTime)timestamp
             surfaceOwner:(id)surfaceOwner {
    if (!self.isRunning || !self.session || !pixelBuffer) {
        return;
    }

    // ノンブロッキングのキュー深度チェック。ENCODER_QUEUE_DEPTH 未満のフレームが
    // 保留中ならセマフォは即時リターン。キュー満杯時はレンダースレッドをブロック
    // せずフレームをドロップ。
    if (dispatch_semaphore_wait(self.encoderSemaphore, DISPATCH_TIME_NOW) != 0) {
        int64_t drops = atomic_fetch_add_explicit(&_dropCount, 1, memory_order_relaxed) + 1;
        if (drops == 1 || drops % 30 == 0) {
            vreclog("FRAME_DROP #%lld (queue full)", (long long)drops);
        }
        return;  // キュー満杯 — フレームスキップ (surfaceOwner は ARC で自動解放)
    }

    CVPixelBufferRetain(pixelBuffer);
    // surfaceOwner (drawable) と入力 PTS を FrameRefCon に格納して VT に渡す。
    // 出力コールバックで drawable を解放し、PTS を復元する。
    FrameRefCon *frameRefCon = malloc(sizeof(FrameRefCon));
    frameRefCon->surfaceOwner = surfaceOwner ? (__bridge_retained void *)surfaceOwner : NULL;
    frameRefCon->originalPTS = timestamp;
    CMTime frameDuration = CMTimeMake(1, self.fps);
    int64_t frameNum = atomic_fetch_add_explicit(&_encodeCount, 1, memory_order_relaxed) + 1;

    dispatch_async(self.encoderQueue, ^{
        if (self.session) {
            OSStatus st = VTCompressionSessionEncodeFrame(self.session,
                                             pixelBuffer,
                                             timestamp,
                                             frameDuration,
                                             NULL, frameRefCon, NULL);
            if (st != noErr) {
                // エンコード失敗時は出力コールバックが呼ばれないので手動解放 + signal
                if (frameRefCon->surfaceOwner) CFRelease(frameRefCon->surfaceOwner);
                free(frameRefCon);
                dispatch_semaphore_signal(self.encoderSemaphore);
            }
            if (frameNum % 100 == 1) {
                vreclog("VT_IN  #%lld pts=%.3f", (long long)frameNum, CMTimeGetSeconds(timestamp));
            }
        } else {
            // セッション破棄済み — 手動解放 + signal
            if (frameRefCon->surfaceOwner) CFRelease(frameRefCon->surfaceOwner);
            free(frameRefCon);
            dispatch_semaphore_signal(self.encoderSemaphore);
        }
        CVPixelBufferRelease(pixelBuffer);
        // 注: セマフォは VT 出力コールバック内で signal される (正常パス)。
        // ここでは signal しない — drawable 解放と同時に signal することで保持数を正確に制限。
    });
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!self.isRunning) {
        if (completion) completion();
        return;
    }

    // エンコーダーキューに stop をディスパッチし、保留中の (最大 ENCODER_QUEUE_DEPTH 個の)
    // エンコードブロックを先に完了させてからフラッシュ & 破棄する。
    dispatch_async(self.encoderQueue, ^{
        self.isRunning = NO;
        if (self.session) {
            VTCompressionSessionCompleteFrames(self.session, kCMTimeInvalid);
            VTCompressionSessionInvalidate(self.session);
            CFRelease(self.session);
            self.session = NULL;
        }
        int64_t submitCount = atomic_load_explicit(&self->_encodeCount, memory_order_relaxed);
        int64_t outCount = atomic_load_explicit(&self->_outputCount, memory_order_relaxed);
        int64_t dropCount = atomic_load_explicit(&self->_dropCount, memory_order_relaxed);
        vreclog("STOP submitted=%lld encoded=%lld dropped=%lld", (long long)submitCount, (long long)outCount, (long long)dropCount);
        NSLog(@"[Recorder] VideoEncoder stopped (submitted=%lld encoded=%lld dropped=%lld)",
              (long long)submitCount, (long long)outCount, (long long)dropCount);
        if (completion) completion();
    });
}

- (void)dealloc {
    if (self.session) {
        VTCompressionSessionInvalidate(self.session);
        CFRelease(self.session);
    }
}

@end
