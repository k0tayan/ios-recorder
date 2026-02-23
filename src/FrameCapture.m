#import "FrameCapture.h"
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#import <objc/message.h>

// IOSurfaceRef を返す objc_msgSend の型定義
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
        // フレームレート制御 (120Hz ソースから 60fps 目標で確実に
        // 1フレームおきにキャプチャするため 0.85x 閾値を使用)
        uint64_t now = mach_absolute_time();
        if (self.lastCaptureTime != 0) {
            double elapsed = (double)(now - self.lastCaptureTime) / self.ticksPerSecond;
            if (elapsed < (0.85 / self.targetFPS)) {
                return;
            }
        }
        self.lastCaptureTime = now;

        // テクスチャ取得
        id<MTLTexture> texture = drawable.texture;
        if (!texture) {
            return;
        }

        // objc_msgSend 経由で IOSurface にアクセス (private API、ObjC オブジェクトではなく CFTypeRef を返す)
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

        // キャプチャサイズ更新
        _captureSize = CGSizeMake(texture.width, texture.height);

        // IOSurface から CVPixelBuffer を生成 (ロックなし・ゼロコピー)
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

        // モノトニックホストクロックから PTS を算出 (音声と同じタイムベース)
        CMTime currentTime = CMClockMakeHostTimeFromSystemUnits(now);
        CMTime pts = self.startTimeSet ? CMTimeSubtract(currentTime, self.recordingStartTime) : kCMTimeZero;

        // drawable を surfaceOwner として渡し、エンコード完了まで IOSurface の再利用を防ぐ
        [self.delegate frameCapture:self
             didCapturePixelBuffer:pixelBuffer
                        timestamp:pts
                     surfaceOwner:drawable];

        // 解放 (デリゲート側で必要なら retain 済み)
        CVPixelBufferRelease(pixelBuffer);
    } @catch (NSException *e) {
        NSLog(@"[Recorder] captureDrawable exception: %@ %@", e.name, e.reason);
    }
}

@end
