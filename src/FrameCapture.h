#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

@class FrameCapture;

@protocol FrameCaptureDelegate <NSObject>
/// @param surfaceOwner pixelBuffer のバッキング IOSurface を保持するオブジェクト (CAMetalDrawable)。
///   エンコード完了まで retain し続けることで Metal による IOSurface の再利用を防ぐ。
- (void)frameCapture:(FrameCapture *)capture
    didCapturePixelBuffer:(CVPixelBufferRef)pixelBuffer
               timestamp:(CMTime)timestamp
            surfaceOwner:(id)surfaceOwner;
@end

@interface FrameCapture : NSObject

@property (nonatomic, weak) id<FrameCaptureDelegate> delegate;
@property (nonatomic, readonly) CGSize captureSize;
@property (nonatomic) int targetFPS;
@property (nonatomic) BOOL capturing;

+ (instancetype)shared;
- (void)captureDrawable:(id<CAMetalDrawable>)drawable;
- (void)setRecordingStartTime:(CMTime)startTime;

@end
