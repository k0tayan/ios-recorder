#import "FrameCapture.h"
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
@property (atomic) CGSize captureSize;
@property (nonatomic) uint64_t nextCaptureTime;
@property (nonatomic) double ticksPerFrame;
@property (nonatomic) double ticksPerSecond;
@property (nonatomic) id<MTLCommandQueue> blitQueue;
@property (nonatomic) CVPixelBufferPoolRef bufferPool;
@property (nonatomic) int poolWidth;
@property (nonatomic) int poolHeight;
@property (nonatomic, strong) id<CAMetalDrawable> pendingDrawable;
@property (nonatomic) uint64_t pendingGridTime;
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
    sFrameRecStartTime = startTime;
    // release: startTime の書き込みが Metal スレッドの acquire 読み取りより前に可視になる
    atomic_store_explicit(&sFrameRecStartTimeSet, true, memory_order_release);
}

- (void)setCapturing:(BOOL)capturing {
    _capturing = capturing;
    if (capturing) {
        _ticksPerFrame = _ticksPerSecond / _targetFPS;
        _nextCaptureTime = 0;  // 最初のフレームで初期化される
        self.pendingDrawable = nil;
        atomic_store_explicit(&sFrameCapturing, true, memory_order_release);
    } else {
        // 最後の pending フレームを flush
        if (self.pendingDrawable) {
            [self _blitPendingDrawable];
        }
        self.pendingDrawable = nil;
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
    uint64_t now = mach_absolute_time();
    uint64_t gridTime;
    if (self.nextCaptureTime != 0) {
        if (now < self.nextCaptureTime) {
            return;
        }
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

    // 遅延キャプチャ: pending drawable をblit (前フレームでレンダリング完了済み)
    // nextDrawable 時点ではゲームが drawable にまだレンダリングしていないため、
    // 1フレーム遅らせることで GPU レンダリングの完了を保証する。
    if (self.pendingDrawable) {
        [self _blitPendingDrawable];
    }

    // 今回の drawable と gridTime を pending に保存
    self.pendingDrawable = drawable;
    self.pendingGridTime = gridTime;
}

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

/// pending drawable を Metal blit でプールバッファにコピーし、デリゲートに通知する。
- (void)_blitPendingDrawable {
    id<CAMetalDrawable> pending = self.pendingDrawable;
    if (!pending) return;

    id<MTLTexture> texture = pending.texture;
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

    CMTime currentTime = CMClockMakeHostTimeFromSystemUnits(self.pendingGridTime);
    CMTime pts = atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire)
               ? CMTimeSubtract(currentTime, sFrameRecStartTime) : kCMTimeZero;

    CMTime capturedPTS = pts;
    __weak typeof(self) weakSelf = self;
    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf.delegate) {
            [strongSelf.delegate frameCapture:strongSelf
                       didCapturePixelBuffer:poolBuffer
                                   timestamp:capturedPTS
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
