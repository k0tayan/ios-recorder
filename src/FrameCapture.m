#import "FrameCapture.h"
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#include <stdatomic.h>

// IOSurfaceRef を返す objc_msgSend の型定義
typedef IOSurfaceRef (*IOSurfaceGetter)(id, SEL);

// ObjC メッセージなしで Metal レンダリングスレッドから読めるフラグ
static atomic_bool  sFrameCapturing;
static CMTime       sFrameRecStartTime;
static atomic_bool  sFrameRecStartTimeSet;

@interface FrameCapture ()
@property (atomic) CGSize captureSize;
@property (nonatomic) uint64_t lastCaptureTime;
@property (nonatomic) double ticksPerSecond;
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
        atomic_store_explicit(&sFrameCapturing, false, memory_order_relaxed);
        atomic_store_explicit(&sFrameRecStartTimeSet, false, memory_order_relaxed);

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        _ticksPerSecond = (double)timebase.denom / (double)timebase.numer * 1e9;
    }
    return self;
}

- (void)setRecordingStartTime:(CMTime)startTime {
    sFrameRecStartTime = startTime;
    // release: startTime の書き込みが Metal スレッドの acquire 読み取りより前に可視になる
    atomic_store_explicit(&sFrameRecStartTimeSet, true, memory_order_release);
}

- (void)setCapturing:(BOOL)capturing {
    _capturing = capturing;
    if (capturing) {
        atomic_store_explicit(&sFrameCapturing, true, memory_order_release);
    } else {
        atomic_store_explicit(&sFrameCapturing, false, memory_order_release);
        atomic_store_explicit(&sFrameRecStartTimeSet, false, memory_order_relaxed);
    }
}

- (void)captureDrawable:(id<CAMetalDrawable>)drawable {
    // captureSize は録画開始前 (capturing=NO) でも常に更新する。
    // startRecording がキャプチャサイズを読み取って VideoEncoder を初期化するため、
    // ここで更新しないとフォールバックの maxCaptureSize (16:9) が使われ、
    // 4:3 の iPad 画面が横に引き伸ばされる。
    id<MTLTexture> texture = drawable.texture;
    if (texture) {
        CGSize newSize = CGSizeMake(texture.width, texture.height);
        if (!CGSizeEqualToSize(newSize, self.captureSize)) {
            self.captureSize = newSize;
        }
    }

    if (!atomic_load_explicit(&sFrameCapturing, memory_order_acquire) || !self.delegate) {
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

        // モノトニックホストクロックから PTS を算出 (音声と同じタイムベース)。
        // 注意: PTS は nextDrawable フック時点 (GPU レンダリング前) の時刻。
        // IOSurface 暗黙的同期により VT は GPU 完了後の画素を読むが、PTS は
        // レンダリング前の時刻のため 1-2 フレーム分 (8-16ms @120fps) の
        // 系統的オフセットがある。A/V 同期に影響が出る場合は
        // drawable.addPresentedHandler: で presentation 時刻を使うことを検討。
        CMTime currentTime = CMClockMakeHostTimeFromSystemUnits(now);
        CMTime pts = atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire)
                   ? CMTimeSubtract(currentTime, sFrameRecStartTime) : kCMTimeZero;

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
