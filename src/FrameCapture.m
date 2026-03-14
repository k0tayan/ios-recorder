#import "FrameCapture.h"
#import "RecorderDefaults.h"
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>
#include <stdatomic.h>

// ObjC メッセージなしで Metal レンダリングスレッドから読めるフラグ
static atomic_bool  sFrameCapturing;
static CMTime       sFrameRecStartTime;
static atomic_bool  sFrameRecStartTimeSet;

// IOSurface ID → MTLTexture の軽量キャッシュ (CVPixelBufferPool が再利用する数個の IOSurface 用)
#define DEST_TEX_CACHE_SIZE 8
typedef struct {
    uint32_t surfaceID;
    CFTypeRef texture;   // retained id<MTLTexture>
} DestTexCacheEntry;

@interface FrameCapture () {
    DestTexCacheEntry _destTexCache[DEST_TEX_CACHE_SIZE];
    int _destTexCacheCount;
}
@property (nonatomic) id<MTLCommandQueue> blitQueue;
@property (nonatomic) CVPixelBufferPoolRef bufferPool;
@property (nonatomic) int poolWidth;
@property (nonatomic) int poolHeight;
// フレームレート制御
@property (nonatomic) double ticksPerSecond;
@property (nonatomic) uint64_t lastCaptureTime;       // 前回キャプチャ時の mach_absolute_time
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
        _targetFPS = kDefaultFPS;
        _capturing = NO;
        atomic_store_explicit(&sFrameCapturing, false, memory_order_relaxed);
        atomic_store_explicit(&sFrameRecStartTimeSet, false, memory_order_relaxed);

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        _ticksPerSecond = (double)timebase.denom / (double)timebase.numer * 1e9;
    }
    return self;
}

- (CVPixelBufferRef)_dequeuePoolBufferWidth:(int)w height:(int)h {
    if (self.bufferPool && (self.poolWidth != w || self.poolHeight != h)) {
        CVPixelBufferPoolRelease(self.bufferPool);
        self.bufferPool = NULL;
        // 解像度変更 — テクスチャキャッシュを無効化
        for (int i = 0; i < _destTexCacheCount; i++) {
            if (_destTexCache[i].texture) CFRelease(_destTexCache[i].texture);
        }
        _destTexCacheCount = 0;
    }
    if (!self.bufferPool) {
        NSDictionary *attrs = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(w),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(h),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVReturn r = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                             (__bridge CFDictionaryRef)attrs, &_bufferPool);
        if (r != kCVReturnSuccess) return NULL;
        self.poolWidth = w;
        self.poolHeight = h;
    }
    CVPixelBufferRef buf = NULL;
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.bufferPool, &buf);
    return buf;  // caller must release
}

- (void)setRecordingStartTime:(CMTime)startTime {
    // No-op: 録画開始時刻は最初のフレームキャプチャ時に自動設定される。
    (void)startTime;
}

+ (BOOL)isRecordingStartTimeSet {
    return atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire);
}

+ (CMTime)recordingStartTimeValue {
    return sFrameRecStartTime;
}

- (void)setCapturing:(BOOL)capturing {
    _capturing = capturing;
    if (capturing) {
        self.lastCaptureTime = 0;
        atomic_store_explicit(&sFrameCapturing, true, memory_order_release);
    } else {
        // in-flight の blit 完了ハンドラがフレームを配信できるよう
        // GPU コマンドの完了を待ってから sFrameCapturing をリセットする。
        if (self.blitQueue) {
            id<MTLCommandBuffer> barrier = [self.blitQueue commandBuffer];
            [barrier commit];
            [barrier waitUntilCompleted];
        }
        atomic_store_explicit(&sFrameCapturing, false, memory_order_release);
        atomic_store_explicit(&sFrameRecStartTimeSet, false, memory_order_relaxed);
    }
}

/// addPresentedHandler から呼ばれる — drawable は描画・表示済み。
/// 遅延キャプチャ不要で、フレームコンテンツの正確性が保証される。
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

    [self _blitAndDeliverDrawable:drawable];
}

#pragma mark - Metal Blit

/// IOSurface ID から destination MTLTexture をキャッシュ検索/作成する。
/// CVPixelBufferPool は少数の IOSurface を再利用するため、キャッシュヒット率はほぼ 100%。
- (id<MTLTexture>)_destTextureForSurface:(IOSurfaceRef)surface
                                  device:(id<MTLDevice>)device
                             pixelFormat:(MTLPixelFormat)fmt {
    uint32_t sid = IOSurfaceGetID(surface);
    for (int i = 0; i < _destTexCacheCount; i++) {
        if (_destTexCache[i].surfaceID == sid) {
            return (__bridge id<MTLTexture>)_destTexCache[i].texture;
        }
    }
    // キャッシュミス: 新規作成
    NSUInteger w = IOSurfaceGetWidth(surface);
    NSUInteger h = IOSurfaceGetHeight(surface);
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                    width:w
                                                                                   height:h
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc iosurface:surface plane:0];
    if (tex && _destTexCacheCount < DEST_TEX_CACHE_SIZE) {
        _destTexCache[_destTexCacheCount].surfaceID = sid;
        _destTexCache[_destTexCacheCount].texture = CFBridgingRetain(tex);
        _destTexCacheCount++;
    }
    return tex;
}

/// drawable を blit し、完了ハンドラからデリゲートに配信する。
/// PTS は壁時計ベース — AudioCapture と同じタイムベースで A/V 同期を維持。
- (void)_blitAndDeliverDrawable:(id<CAMetalDrawable>)drawable {
    uint64_t now = mach_absolute_time();

    if (self.lastCaptureTime == 0) {
        self.lastCaptureTime = now;
        // 録画開始時刻を AudioCapture と共有
        sFrameRecStartTime = CMClockMakeHostTimeFromSystemUnits(now);
        atomic_store_explicit(&sFrameRecStartTimeSet, true, memory_order_release);
    } else {
        // レート制限: ゲーム FPS > キャプチャ FPS の場合のみ間引く。
        // 最小間隔の 2/3 未満なら早すぎるのでスキップ。
        double minInterval = self.ticksPerSecond / self.targetFPS;
        if ((double)(now - self.lastCaptureTime) < minInterval * 2.0 / 3.0) {
            return;
        }
        self.lastCaptureTime = now;
    }

    // PTS: 壁時計ベース — AudioCapture と同じ mach_absolute_time 由来で A/V 同期を維持。
    CMTime currentTime = CMClockMakeHostTimeFromSystemUnits(now);
    CMTime pts = CMTimeSubtract(currentTime, sFrameRecStartTime);

    id<MTLTexture> texture = drawable.texture;
    if (!texture) return;

    int tw = (int)texture.width;
    int th = (int)texture.height;

    if (!self.blitQueue) {
        self.blitQueue = [texture.device newCommandQueue];
    }

    CVPixelBufferRef poolBuffer = [self _dequeuePoolBufferWidth:tw height:th];
    if (!poolBuffer) return;

    IOSurfaceRef destSurface = CVPixelBufferGetIOSurface(poolBuffer);
    if (!destSurface) {
        CVPixelBufferRelease(poolBuffer);
        return;
    }
    id<MTLTexture> destTexture = [self _destTextureForSurface:destSurface
                                                       device:texture.device
                                                  pixelFormat:texture.pixelFormat];
    if (!destTexture) {
        CVPixelBufferRelease(poolBuffer);
        return;
    }

    id<MTLCommandBuffer> cmdBuf = [self.blitQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
    [blit copyFromTexture:texture
              sourceSlice:0 sourceLevel:0
             sourceOrigin:(MTLOrigin){0, 0, 0}
               sourceSize:(MTLSize){(NSUInteger)tw, (NSUInteger)th, 1}
                toTexture:destTexture
         destinationSlice:0 destinationLevel:0
        destinationOrigin:(MTLOrigin){0, 0, 0}];
    [blit endEncoding];

    __weak typeof(self) weakSelf = self;
    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!atomic_load_explicit(&sFrameCapturing, memory_order_acquire)) {
            CVPixelBufferRelease(poolBuffer);
            return;
        }
        if (strongSelf.delegate) {
            [strongSelf.delegate frameCapture:strongSelf
                       didCapturePixelBuffer:poolBuffer
                                   timestamp:pts
                                surfaceOwner:nil];
        }
        CVPixelBufferRelease(poolBuffer);
    }];
    [cmdBuf commit];
}

- (void)dealloc {
    if (_bufferPool) {
        CVPixelBufferPoolRelease(_bufferPool);
    }
    for (int i = 0; i < _destTexCacheCount; i++) {
        if (_destTexCache[i].texture) {
            CFRelease(_destTexCache[i].texture);
        }
    }
}

@end
