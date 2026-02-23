#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

@interface VideoEncoder : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, copy) void (^onEncodedSample)(CMSampleBufferRef sampleBuffer);

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                          fps:(int)fps
                      bitrate:(int)bitrate;
- (BOOL)start;
/// @param surfaceOwner pixelBuffer のバッキング IOSurface を保持する drawable。
///   VT の sourceFrameRefCon に渡し、出力コールバックで解放することで
///   エンコード完了まで Metal による IOSurface 再利用を防ぐ。nil 許容。
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                timestamp:(CMTime)timestamp
             surfaceOwner:(id)surfaceOwner;
- (void)stopWithCompletion:(void (^)(void))completion;

@end
