#import "VideoEncoder.h"
#include <sys/time.h>

// ─── File-based debug logging (shared log file with AudioCapture) ──
static FILE *sVideoLogFile = NULL;

static void vreclog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void vreclog(const char *fmt, ...) {
    if (!sVideoLogFile) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iosrecorder_video.log"];
        sVideoLogFile = fopen(tmp.UTF8String, "a");
        if (sVideoLogFile) setlinebuf(sVideoLogFile);
    }
    if (!sVideoLogFile) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm t; localtime_r(&tv.tv_sec, &t);
    fprintf(sVideoLogFile, "%02d:%02d:%02d.%03d ", t.tm_hour, t.tm_min, t.tm_sec, (int)(tv.tv_usec/1000));
    va_list ap; va_start(ap, fmt); vfprintf(sVideoLogFile, fmt, ap); va_end(ap);
    fprintf(sVideoLogFile, "\n");
}

// Max frames queued for async encoding.  Metal's drawable pool has ~3
// surfaces; keeping the queue shallow ensures each IOSurface-backed pixel
// buffer is encoded before Metal can reuse it (~25 ms at 120 Hz), while
// almost never blocking the render thread.
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

    // Log every 100th output frame for PTS tracking
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
        NULL,  // encoderSpecification
        NULL,  // sourceImageBufferAttributes
        kCFAllocatorDefault,
        videoEncoderOutputCallback,
        (__bridge void *)self,
        &_session
    );

    if (status != noErr) {
        NSLog(@"[Recorder] Failed to create VTCompressionSession: %d", (int)status);
        return NO;
    }

    // Configure session properties
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);

    int avgBitrate = self.bitrate;
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &avgBitrate);
    VTSessionSetProperty(self.session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // Data rate limits: [bytes per second, duration in seconds]
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

    // Non-blocking queue depth check.  If fewer than ENCODER_QUEUE_DEPTH
    // frames are pending, the semaphore returns immediately.  If the queue
    // is full, we DROP this frame rather than blocking the render thread —
    // this keeps the game running at full 120fps while ensuring IOSurface-
    // backed pixel buffers are encoded before Metal recycles them.
    if (dispatch_semaphore_wait(self.encoderSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;  // queue full — skip frame to keep render thread smooth
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

    // Dispatch stop to the encoder queue so the (at most ENCODER_QUEUE_DEPTH)
    // pending encode blocks finish first, then flush and tear down.
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
