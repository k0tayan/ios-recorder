#import "FrameCapture.h"
#import "UnityTime.h"
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#import <objc/message.h>

// Typedef for objc_msgSend returning IOSurfaceRef
typedef IOSurfaceRef (*IOSurfaceGetter)(id, SEL);

@interface FrameCapture ()
@property (nonatomic) CGSize captureSize;
@property (nonatomic) uint64_t lastCaptureTime;
@property (nonatomic) double ticksPerSecond;
@property (nonatomic) CMTime recordingStartTime;
@property (nonatomic) BOOL startTimeSet;
@property (nonatomic) int64_t frameCount;
@end

@implementation FrameCapture

+ (instancetype)shared {
    static FrameCapture *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FrameCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFPS = 120;
        _capturing = NO;
        _lastCaptureTime = 0;
        _startTimeSet = NO;

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        _ticksPerSecond = (double)timebase.denom / (double)timebase.numer * 1e9;
    }
    return self;
}

- (void)setRecordingStartTime:(CMTime)startTime {
    _recordingStartTime = startTime;
    _startTimeSet = YES;
    _frameCount = 0;
}

- (void)captureDrawable:(id<CAMetalDrawable>)drawable {
    if (!self.capturing || !self.delegate) {
        return;
    }

    @try {
        // Frame rate control (use 0.85x threshold to reliably capture
        // every other frame from 120Hz source for 60fps target)
        uint64_t now = mach_absolute_time();
        if (self.lastCaptureTime != 0) {
            double elapsed = (double)(now - self.lastCaptureTime) / self.ticksPerSecond;
            if (elapsed < (0.85 / self.targetFPS)) {
                return;
            }
        }
        self.lastCaptureTime = now;

        // Get texture
        id<MTLTexture> texture = drawable.texture;
        if (!texture) {
            return;
        }

        // Access IOSurface via objc_msgSend (private API, returns CFTypeRef not ObjC object)
        SEL iosurfaceSel = sel_registerName("iosurface");
        if (![texture respondsToSelector:iosurfaceSel]) {
            NSLog(@"[Recorder] Texture does not respond to iosurface");
            return;
        }
        IOSurfaceGetter getter = (IOSurfaceGetter)objc_msgSend;
        IOSurfaceRef surface = getter(texture, iosurfaceSel);
        if (!surface) {
            return;
        }

        // Update capture size
        _captureSize = CGSizeMake(texture.width, texture.height);

        // Create CVPixelBuffer from IOSurface (without locking - zero copy)
        CVPixelBufferRef pixelBuffer = NULL;
        NSDictionary *attrs = @{
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVReturn result = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            (__bridge CFDictionaryRef)attrs,
            &pixelBuffer
        );

        if (result != kCVReturnSuccess || !pixelBuffer) {
            return;
        }

        // Calculate PTS using Unity timeline (preferred) or wall-clock fallback
        CMTime pts = [UnityTime videoPTS];
        if (CMTIME_IS_INVALID(pts)) {
            CMTime currentTime = CMClockGetTime(CMClockGetHostTimeClock());
            pts = self.startTimeSet ? CMTimeSubtract(currentTime, self.recordingStartTime) : kCMTimeZero;
        }

        // Notify delegate
        [self.delegate frameCapture:self didCapturePixelBuffer:pixelBuffer timestamp:pts];

        // Cleanup
        CVPixelBufferRelease(pixelBuffer);
    } @catch (NSException *e) {
        NSLog(@"[Recorder] captureDrawable exception: %@ %@", e.name, e.reason);
    }
}

@end
