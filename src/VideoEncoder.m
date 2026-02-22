#import "VideoEncoder.h"

@interface VideoEncoder ()
@property (nonatomic) VTCompressionSessionRef session;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) int fps;
@property (nonatomic) int bitrate;
@property (nonatomic, readwrite) BOOL isRunning;
@property (nonatomic) dispatch_queue_t encoderQueue;
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
    }
    return self;
}

- (BOOL)start {
    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        self.width,
        self.height,
        kCMVideoCodecType_H264,
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
                         kVTProfileLevel_H264_Main_AutoLevel);

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
    NSLog(@"[Recorder] VideoEncoder started: %dx%d @ %dfps, %dbps",
          self.width, self.height, self.fps, self.bitrate);
    return YES;
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                timestamp:(CMTime)timestamp {
    if (!self.isRunning || !self.session || !pixelBuffer) {
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    CMTime frameDuration = CMTimeMake(1, self.fps);
    dispatch_async(self.encoderQueue, ^{
        if (self.isRunning && self.session) {
            VTCompressionSessionEncodeFrame(self.session,
                                             pixelBuffer,
                                             timestamp,
                                             frameDuration,
                                             NULL, NULL, NULL);
        }
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!self.isRunning) {
        if (completion) completion();
        return;
    }

    self.isRunning = NO;

    dispatch_async(self.encoderQueue, ^{
        if (self.session) {
            VTCompressionSessionCompleteFrames(self.session, kCMTimeInvalid);
            VTCompressionSessionInvalidate(self.session);
            CFRelease(self.session);
            self.session = NULL;
        }
        NSLog(@"[Recorder] VideoEncoder stopped");
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
