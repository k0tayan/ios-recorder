#import "VideoEncoder.h"
#import "RecorderLog.h"

DEFINE_RECLOG(vreclog, "iosrecorder_video.log")

// 非同期エンコードのキュー深度上限。Metal の drawable プールは ~3 サーフェスなので、
// キューを浅く保つことで IOSurface バックの pixel buffer が Metal に再利用される前に
// エンコードされる (~25ms @120Hz)。レンダースレッドをほぼブロックしない。
#define ENCODER_QUEUE_DEPTH 2

@interface VideoEncoder ()
@property (nonatomic) VTCompressionSessionRef session;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) int fps;
@property (nonatomic) int bitrate;
@property (nonatomic, readwrite) BOOL isRunning;
@property (nonatomic) dispatch_queue_t encoderQueue;
@property (nonatomic) dispatch_semaphore_t encoderSemaphore;
@property (nonatomic) int64_t encodeCount;
@property (nonatomic) int64_t outputCount;
@end

static void videoEncoderOutputCallback(void *outputCallbackRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTEncodeInfoFlags infoFlags,
                                        CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) {
        NSLog(@"[Recorder] Video encode error: %d", (int)status);
        return;
    }

    VideoEncoder *encoder = (__bridge VideoEncoder *)outputCallbackRefCon;
    encoder.outputCount++;

    // 100 フレームごとに PTS 追跡用ログ
    if (encoder.outputCount % 100 == 1) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        vreclog("VT_OUT #%lld pts=%.3f", (long long)encoder.outputCount, CMTimeGetSeconds(pts));
    }

    if (encoder.onEncodedSample) {
        CFRetain(sampleBuffer);
        encoder.onEncodedSample(sampleBuffer);
        CFRelease(sampleBuffer);
    }
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
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);

    int avgBitrate = self.bitrate;
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &avgBitrate);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // データレート制限: [バイト/秒, 期間(秒)]
    int bytesPerSecond = self.bitrate / 8;
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
    self.encodeCount = 0;
    self.outputCount = 0;
    vreclog("START %dx%d @%dfps %dbps", self.width, self.height, self.fps, self.bitrate);
    NSLog(@"[Recorder] VideoEncoder started: %dx%d @ %dfps, %dbps",
          self.width, self.height, self.fps, self.bitrate);
    return YES;
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                timestamp:(CMTime)timestamp {
    if (!self.isRunning || !self.session || !pixelBuffer) {
        return;
    }

    // ノンブロッキングのキュー深度チェック。ENCODER_QUEUE_DEPTH 未満のフレームが
    // 保留中ならセマフォは即時リターン。キュー満杯時はレンダースレッドをブロック
    // せずフレームをドロップ — ゲームは 120fps で動き続け、IOSurface バックの
    // pixel buffer は Metal が再利用する前にエンコードされる。
    if (dispatch_semaphore_wait(self.encoderSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;  // キュー満杯 — レンダースレッドの滑らかさのためフレームをスキップ
    }

    CVPixelBufferRetain(pixelBuffer);
    CMTime frameDuration = CMTimeMake(1, self.fps);
    int64_t frameNum = ++self.encodeCount;

    dispatch_async(self.encoderQueue, ^{
        if (self.session) {
            VTCompressionSessionEncodeFrame(self.session,
                                             pixelBuffer,
                                             timestamp,
                                             frameDuration,
                                             NULL, NULL, NULL);
            if (frameNum % 100 == 1) {
                vreclog("VT_IN  #%lld pts=%.3f", (long long)frameNum, CMTimeGetSeconds(timestamp));
            }
        }
        CVPixelBufferRelease(pixelBuffer);
        dispatch_semaphore_signal(self.encoderSemaphore);
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
        vreclog("STOP submitted=%lld encoded=%lld", (long long)self.encodeCount, (long long)self.outputCount);
        NSLog(@"[Recorder] VideoEncoder stopped (submitted=%lld encoded=%lld)",
              (long long)self.encodeCount, (long long)self.outputCount);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

- (void)dealloc {
    if (self.session) {
        VTCompressionSessionInvalidate(self.session);
        CFRelease(self.session);
    }
}

@end
