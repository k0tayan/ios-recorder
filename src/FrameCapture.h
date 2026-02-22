#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

@class FrameCapture;

@protocol FrameCaptureDelegate <NSObject>
- (void)frameCapture:(FrameCapture *)capture
    didCapturePixelBuffer:(CVPixelBufferRef)pixelBuffer
               timestamp:(CMTime)timestamp;
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
