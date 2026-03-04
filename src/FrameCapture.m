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
@property (nonatomic) uint64_t nextCaptureTime;  // 次にキャプチャすべき理想時刻 (mach_absolute_time 単位)
@property (nonatomic) double ticksPerFrame;       // 1フレームあたりの mach ticks
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
        _nextCaptureTime = 0;
        atomic_store_explicit(&sFrameCapturing, false, memory_order_relaxed);
        atomic_store_explicit(&sFrameRecStartTimeSet, false, memory_order_relaxed);

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        _ticksPerSecond = (double)timebase.denom / (double)timebase.numer * 1e9;
        _ticksPerFrame = _ticksPerSecond / _targetFPS;
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
        _ticksPerFrame = _ticksPerSecond / _targetFPS;
        _nextCaptureTime = 0;  // 最初のフレームで初期化される
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

    // フレームレート制御: 固定グリッドにスナップして等間隔キャプチャを保証。
    // nextCaptureTime は「次にキャプチャすべき理想時刻」を表し、
    // 実際のキャプチャ時刻ではなくグリッド上の時刻で更新することで
    // ジッターの蓄積を防止する。
    // PTS もグリッド時刻から算出し、再生時のフレーム間隔を完全に均一にする。
    uint64_t now = mach_absolute_time();
    uint64_t gridTime;  // このフレームの理想的なグリッド時刻
    if (self.nextCaptureTime != 0) {
        if (now < self.nextCaptureTime) {
            return;
        }
        // 大幅に遅延した場合 (2フレーム以上) はグリッドをリセット
        uint64_t ticksPerFrame = (uint64_t)self.ticksPerFrame;
        if (now - self.nextCaptureTime > ticksPerFrame * 2) {
            gridTime = now;
            self.nextCaptureTime = now + ticksPerFrame;
        } else {
            gridTime = self.nextCaptureTime;
            self.nextCaptureTime += ticksPerFrame;
        }
    } else {
        gridTime = now;
        self.nextCaptureTime = now + (uint64_t)self.ticksPerFrame;
    }

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

    // グリッド時刻から PTS を算出。実時刻 (now) ではなくグリッド時刻を使うことで、
    // フレーム間隔が正確に 1/fps になり、再生時のジッター (カクカク) を防止する。
    // グリッドは実時刻に追従するため A/V 同期への影響は最小。
    CMTime currentTime = CMClockMakeHostTimeFromSystemUnits(gridTime);
    CMTime pts = atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire)
               ? CMTimeSubtract(currentTime, sFrameRecStartTime) : kCMTimeZero;

    // drawable を surfaceOwner として渡し、エンコード完了まで IOSurface の再利用を防ぐ
    [self.delegate frameCapture:self
         didCapturePixelBuffer:pixelBuffer
                    timestamp:pts
                 surfaceOwner:drawable];

    // 解放 (デリゲート側で必要なら retain 済み)
    CVPixelBufferRelease(pixelBuffer);
}

@end
