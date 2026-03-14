#import "FrameCapture.h"
#import "RecorderDefaults.h"
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/CADisplayLink.h>
#import <mach/mach_time.h>
#import <os/lock.h>
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
    os_unfair_lock _latestBufferLock;
    CVPixelBufferRef _latestPixelBuffer;   // blit 完了後に格納、displayLink が消費
}
@property (atomic) CGSize captureSize;
@property (nonatomic) id<MTLCommandQueue> blitQueue;
@property (nonatomic) CVPixelBufferPoolRef bufferPool;
@property (nonatomic) int poolWidth;
@property (nonatomic) int poolHeight;
@property (nonatomic, strong) id<CAMetalDrawable> pendingDrawable;
@property (nonatomic, strong) CADisplayLink *displayLink;
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
        _latestBufferLock = OS_UNFAIR_LOCK_INIT;
        atomic_store_explicit(&sFrameCapturing, false, memory_order_relaxed);
        atomic_store_explicit(&sFrameRecStartTimeSet, false, memory_order_relaxed);
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
    // No-op: 録画開始時刻は displayLink の最初のフレーム送信時に自動設定される。
    (void)startTime;
}

+ (BOOL)isRecordingStartTimeSet {
    return atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire);
}

+ (CMTime)recordingStartTimeValue {
    return sFrameRecStartTime;
}

- (void)setTargetFPS:(int)targetFPS {
    _targetFPS = targetFPS;
    // CADisplayLink のプロパティ変更はメインスレッドで行う
    if (self.displayLink) {
        if ([NSThread isMainThread]) {
            self.displayLink.preferredFramesPerSecond = targetFPS;
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.displayLink.preferredFramesPerSecond = targetFPS;
            });
        }
    }
}

- (void)setCapturing:(BOOL)capturing {
    _capturing = capturing;
    if (capturing) {
        self.pendingDrawable = nil;
        os_unfair_lock_lock(&_latestBufferLock);
        if (_latestPixelBuffer) {
            CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = NULL;
        }
        os_unfair_lock_unlock(&_latestBufferLock);
        atomic_store_explicit(&sFrameCapturing, true, memory_order_release);
        [self _startDisplayLink];
    } else {
        // sFrameCapturing を先にリセット — in-flight blit の完了ハンドラが
        // latestPixelBuffer に書き込まないようにする
        atomic_store_explicit(&sFrameCapturing, false, memory_order_release);
        [self _stopDisplayLink];
        // 最後の pending フレームを直接 flush
        if (self.pendingDrawable) {
            [self _flushPendingDrawable];
        }
        self.pendingDrawable = nil;
        // 未消費の latest buffer をドレイン
        os_unfair_lock_lock(&_latestBufferLock);
        if (_latestPixelBuffer) {
            CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = NULL;
        }
        os_unfair_lock_unlock(&_latestBufferLock);
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

    if (!atomic_load_explicit(&sFrameCapturing, memory_order_acquire)) {
        return;
    }

    // 遅延キャプチャ: pending drawable を blit (前フレームでレンダリング完了済み)。
    // nextDrawable 時点ではゲームが drawable にまだレンダリングしていないため、
    // 1フレーム遅らせることで GPU レンダリングの完了を保証する。
    // blit 結果は _latestPixelBuffer に格納され、CADisplayLink が消費する。
    if (self.pendingDrawable) {
        [self _blitPendingToLatest];
    }

    self.pendingDrawable = drawable;
}

#pragma mark - CADisplayLink

- (void)_startDisplayLink {
    // CADisplayLink はメインスレッドの RunLoop で動作させる。
    // setCapturing: は recording queue から呼ばれるため dispatch する。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_load_explicit(&sFrameCapturing, memory_order_acquire)) return;
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_displayLinkFired:)];
        self.displayLink.preferredFramesPerSecond = self.targetFPS;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

- (void)_stopDisplayLink {
    // invalidate はメインスレッドで実行する必要がある。
    // dispatch_sync で完了を待ち、後続のクリーンアップと順序を保証する。
    if ([NSThread isMainThread]) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self.displayLink invalidate];
            self.displayLink = nil;
        });
    }
}

- (void)_displayLinkFired:(CADisplayLink *)link {
    if (!atomic_load_explicit(&sFrameCapturing, memory_order_acquire) || !self.delegate) return;

    // blit 済みの最新フレームをアトミックに取得
    os_unfair_lock_lock(&_latestBufferLock);
    CVPixelBufferRef buffer = _latestPixelBuffer;
    _latestPixelBuffer = NULL;
    os_unfair_lock_unlock(&_latestBufferLock);

    if (!buffer) return;  // ゲームがまだ新しいフレームを描画していない

    // PTS: displayLink.timestamp (vsync 同期) を使い等間隔を保証する。
    // displayLink.timestamp は CACurrentMediaTime() と同じ mach_absolute_time 由来の
    // 秒値なので、AudioCapture が mach ticks ベースで算出する PTS との差は
    // double→CMTime 変換の精度差のみ（実用上無視可能）。
    CMTime currentTime = CMTimeMakeWithSeconds(link.timestamp, 1000000000);
    CMTime pts;
    if (!atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire)) {
        sFrameRecStartTime = currentTime;
        atomic_store_explicit(&sFrameRecStartTimeSet, true, memory_order_release);
        pts = kCMTimeZero;
    } else {
        pts = CMTimeSubtract(currentTime, sFrameRecStartTime);
    }

    [self.delegate frameCapture:self
           didCapturePixelBuffer:buffer
                       timestamp:pts
                    surfaceOwner:nil];
    CVPixelBufferRelease(buffer);
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

/// 共通の blit 処理: pending drawable をプールバッファにコピーする。
/// @return blit 先の CVPixelBufferRef (caller must release)、失敗時は NULL。
- (CVPixelBufferRef)_blitPendingToBuffer:(id<MTLCommandBuffer> *)outCmdBuf {
    id<CAMetalDrawable> pending = self.pendingDrawable;
    if (!pending) return NULL;

    id<MTLTexture> texture = pending.texture;
    if (!texture) return NULL;

    int tw = (int)texture.width;
    int th = (int)texture.height;

    if (!self.blitQueue) {
        self.blitQueue = [texture.device newCommandQueue];
    }

    CVPixelBufferRef poolBuffer = [self _dequeuePoolBufferWidth:tw height:th];
    if (!poolBuffer) return NULL;

    IOSurfaceRef destSurface = CVPixelBufferGetIOSurface(poolBuffer);
    if (!destSurface) {
        CVPixelBufferRelease(poolBuffer);
        return NULL;
    }
    id<MTLTexture> destTexture = [self _destTextureForSurface:destSurface
                                                       device:texture.device
                                                  pixelFormat:texture.pixelFormat];
    if (!destTexture) {
        CVPixelBufferRelease(poolBuffer);
        return NULL;
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

    if (outCmdBuf) *outCmdBuf = cmdBuf;
    return poolBuffer;
}

/// 通常パス: pending drawable を blit し、完了ハンドラで _latestPixelBuffer に格納。
/// CADisplayLink が次の tick で消費する。
- (void)_blitPendingToLatest {
    id<MTLCommandBuffer> cmdBuf = nil;
    CVPixelBufferRef poolBuffer = [self _blitPendingToBuffer:&cmdBuf];
    if (!poolBuffer) return;

    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        // キャプチャ停止後に完了した in-flight blit はバッファを解放するだけ
        if (!atomic_load_explicit(&sFrameCapturing, memory_order_acquire)) {
            CVPixelBufferRelease(poolBuffer);
            return;
        }
        os_unfair_lock_lock(&self->_latestBufferLock);
        CVPixelBufferRef old = self->_latestPixelBuffer;
        self->_latestPixelBuffer = poolBuffer;  // ownership 移譲
        os_unfair_lock_unlock(&self->_latestBufferLock);
        if (old) CVPixelBufferRelease(old);
    }];
    [cmdBuf commit];
}

/// 停止パス: pending drawable を同期 blit し、直接デリゲートに送信する。
- (void)_flushPendingDrawable {
    id<MTLCommandBuffer> cmdBuf = nil;
    CVPixelBufferRef poolBuffer = [self _blitPendingToBuffer:&cmdBuf];
    if (!poolBuffer) return;

    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    CMTime currentTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTime pts;
    if (atomic_load_explicit(&sFrameRecStartTimeSet, memory_order_acquire)) {
        pts = CMTimeSubtract(currentTime, sFrameRecStartTime);
    } else {
        pts = kCMTimeZero;
    }

    if (self.delegate) {
        [self.delegate frameCapture:self
               didCapturePixelBuffer:poolBuffer
                           timestamp:pts
                        surfaceOwner:nil];
    }
    CVPixelBufferRelease(poolBuffer);
}

- (void)dealloc {
    if (_displayLink) {
        [_displayLink invalidate];
    }
    if (_latestPixelBuffer) {
        CVPixelBufferRelease(_latestPixelBuffer);
    }
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
